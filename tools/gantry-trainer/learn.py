"""Uczenie i eksport modelu wykrywania błędów druku dla Gantry.

MobileNetV3-Small wstępnie wytrenowany na ImageNet: sieć jest zamrożona, uczy się tylko jej ostatnia
część (klasyfikator), więc wystarcza kilkadziesiąt zdjęć i kilka minut. Model dostaje cały kadr ściśnięty
do 224x224 px, RGB w zakresie 0..1; normalizacja ImageNet i softmax są wbudowane w wyeksportowany plik,
więc Gantry podaje obraz i dostaje prawdopodobieństwa klas, bez żadnej wiedzy o sieci.
"""
from __future__ import annotations

import json
import random
import shutil
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np
import torch
from PIL import Image
from torch import nn
from torchvision import models, transforms

INPUT_SIZE = 224
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)
MODEL_FORMAT = "gantry-defect-model"
SEED = 7


def device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def load_rgb(path: Path) -> Image.Image:
    with Image.open(path) as image:
        return image.convert("RGB")


# Kadr z kamery ma 16:9, zdjęcie z telefonu 4:3; w Gantry cały kadr jest ściskany do kwadratu, więc przy
# uczeniu wycinek też ma proporcje zbliżone do kadru i też jest ściskany, zamiast przycinany do środka.
TRAIN_TRANSFORM = transforms.Compose([
    transforms.RandomResizedCrop(INPUT_SIZE, scale=(0.55, 1.0), ratio=(1.2, 1.9)),
    transforms.RandomHorizontalFlip(),
    transforms.RandomRotation(8),
    transforms.ColorJitter(brightness=0.35, contrast=0.3, saturation=0.25, hue=0.03),
    transforms.ToTensor(),
])
EVAL_TRANSFORM = transforms.Compose([
    transforms.Resize((INPUT_SIZE, INPUT_SIZE)),
    transforms.ToTensor(),
])


class Deployable(nn.Module):
    """Obraz RGB 0..1 na wejściu, prawdopodobieństwa klas na wyjściu."""

    def __init__(self, net: nn.Module) -> None:
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        return torch.softmax(self.net((image - self.mean) / self.std), dim=1)


def build_network(classes: int) -> nn.Module:
    net = models.mobilenet_v3_small(weights=models.MobileNet_V3_Small_Weights.IMAGENET1K_V1)
    for parameter in net.features.parameters():
        parameter.requires_grad = False
    head = net.classifier[3]
    net.classifier[3] = nn.Linear(head.in_features, classes)
    return net


@dataclass
class Sample:
    path: Path
    label: int
    held_out: bool = False


def split(samples_by_class: list[list[Path]]) -> list[Sample]:
    """Około jednej piątej zdjęć każdej klasy odkładane do sprawdzenia; klasa z mniej niż 5 zdjęciami
    oddaje wszystko do nauki."""
    rng = random.Random(SEED)
    result: list[Sample] = []
    for label, paths in enumerate(samples_by_class):
        shuffled = sorted(paths)
        rng.shuffle(shuffled)
        held = max(1, round(len(shuffled) * 0.2)) if len(shuffled) >= 5 else 0
        result += [Sample(path, label, index < held) for index, path in enumerate(shuffled)]
    return result


@dataclass
class Progress:
    phase: str = "idle"          # idle, preparing, training, exporting, done, failed
    message: str = ""
    epoch: int = 0
    epochs: int = 0
    loss: list[float] = field(default_factory=list)
    accuracy: list[float | None] = field(default_factory=list)
    result: dict | None = None
    error: str | None = None


def train(classes: list[dict], image_root: Path, model_root: Path, epochs: int,
          progress: Progress, notify: Callable[[], None] = lambda: None) -> dict:
    torch.manual_seed(SEED)
    started = time.time()
    progress.phase, progress.message = "preparing", "Wczytuję zdjęcia i sieć bazową"
    notify()
    paths = [sorted(p for p in (image_root / c["id"]).glob("*.jpg")) for c in classes]
    samples = split(paths)
    train_set = [s for s in samples if not s.held_out]
    check_set = [s for s in samples if s.held_out]
    # Obrazy trzymane w pamięci: przy setkach zdjęć to kilkadziesiąt MB, a każda epoka nie czyta dysku.
    images = {s.path: load_rgb(s.path) for s in samples}
    dev = device()
    net = build_network(len(classes)).to(dev)
    counts = np.bincount([s.label for s in train_set], minlength=len(classes)).astype(np.float32)
    # Klasa z mniejszą liczbą zdjęć waży więcej, żeby model nie wygrywał, zgadując zawsze tę liczniejszą.
    weights = torch.tensor(counts.sum() / np.maximum(counts, 1) / len(classes), device=dev)
    criterion = nn.CrossEntropyLoss(weight=weights)
    optimizer = torch.optim.AdamW((p for p in net.parameters() if p.requires_grad), lr=1e-3, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=max(1, epochs))
    batch = 16

    progress.phase, progress.epochs = "training", epochs
    for epoch in range(epochs):
        net.train()
        # Zamrożona część sieci zostaje w trybie oceny, żeby jej statystyki normalizacji się nie rozjechały
        # na kilkudziesięciu zdjęciach.
        net.features.eval()
        order = list(train_set)
        random.Random(SEED + epoch).shuffle(order)
        total, seen = 0.0, 0
        for start in range(0, len(order), batch):
            chunk = order[start:start + batch]
            x = torch.stack([TRAIN_TRANSFORM(images[s.path]) for s in chunk]).to(dev)
            y = torch.tensor([s.label for s in chunk], device=dev)
            x = (x - torch.tensor(MEAN, device=dev).view(1, 3, 1, 1)) / torch.tensor(STD, device=dev).view(1, 3, 1, 1)
            optimizer.zero_grad()
            loss = criterion(net(x), y)
            loss.backward()
            optimizer.step()
            total += loss.item() * len(chunk)
            seen += len(chunk)
        scheduler.step()
        accuracy = None
        if check_set:
            predictions = predict(net, [images[s.path] for s in check_set], dev)
            accuracy = float(np.mean([int(np.argmax(p)) == s.label for p, s in zip(predictions, check_set)]))
        progress.epoch = epoch + 1
        progress.loss.append(total / max(seen, 1))
        progress.accuracy.append(accuracy)
        progress.message = f"Epoka {epoch + 1} z {epochs}"
        notify()

    progress.phase, progress.message = "exporting", "Oceniam wszystkie zdjęcia i zapisuję model"
    notify()
    everything = predict(net, [images[s.path] for s in samples], dev)
    per_image = []
    for sample, probabilities in zip(samples, everything):
        guess = int(np.argmax(probabilities))
        per_image.append({
            "class": classes[sample.label]["id"], "file": sample.path.name, "heldOut": sample.held_out,
            "predicted": classes[guess]["id"], "confidence": float(probabilities[guess]),
            "probabilities": {c["id"]: float(probabilities[i]) for i, c in enumerate(classes)},
        })
    confusion = [[0] * len(classes) for _ in classes]
    for sample, probabilities in zip(samples, everything):
        if sample.held_out:
            confusion[sample.label][int(np.argmax(probabilities))] += 1
    held = [r for r in per_image if r["heldOut"]]
    report = {
        "images": {c["id"]: len(p) for c, p in zip(classes, paths)},
        "heldOut": len(held),
        "accuracy": (sum(r["class"] == r["predicted"] for r in held) / len(held)) if held else None,
        "confusion": confusion,
        "perImage": per_image,
        "seconds": round(time.time() - started, 1),
        "device": dev.type,
    }
    folder = export(net.cpu(), classes, model_root, report, epochs)
    report["model"] = folder.name
    progress.phase, progress.message, progress.result = "done", "Gotowe", report
    notify()
    return report


@torch.no_grad()
def predict(net: nn.Module, images: list[Image.Image], dev: torch.device) -> list[np.ndarray]:
    net.eval()
    mean = torch.tensor(MEAN, device=dev).view(1, 3, 1, 1)
    std = torch.tensor(STD, device=dev).view(1, 3, 1, 1)
    out: list[np.ndarray] = []
    for start in range(0, len(images), 32):
        x = torch.stack([EVAL_TRANSFORM(image) for image in images[start:start + 32]]).to(dev)
        out += list(torch.softmax(net((x - mean) / std), dim=1).cpu().numpy())
    return out


def export(net: nn.Module, classes: list[dict], model_root: Path, report: dict, epochs: int) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    folder = model_root / stamp
    folder.mkdir(parents=True, exist_ok=True)
    deployable = Deployable(net).eval()
    example = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE)
    files: dict[str, str] = {}
    notes: list[str] = []

    torch.onnx.export(deployable, (example,), str(folder / "model.onnx"), input_names=["image"],
                      output_names=["probabilities"], opset_version=17, dynamo=False)
    files["onnx"] = "model.onnx"
    try:
        import onnxruntime
        session = onnxruntime.InferenceSession(str(folder / "model.onnx"), providers=["CPUExecutionProvider"])
        onnx_out = session.run(None, {"image": example.numpy()})[0]
        with torch.no_grad():
            torch_out = deployable(example).numpy()
        report["onnxMaxDifference"] = float(np.abs(onnx_out - torch_out).max())
    except Exception as error:  # noqa: BLE001 - brak sprawdzenia nie blokuje eksportu
        notes.append(f"Nie sprawdzono pliku ONNX: {error}")

    try:
        import coremltools as ct
        traced = torch.jit.trace(deployable, example)
        mlmodel = ct.convert(
            traced,
            inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0,
                                 color_layout=ct.colorlayout.RGB)],
            outputs=[ct.TensorType(name="probabilities")],
            convert_to="mlprogram",
            minimum_deployment_target=ct.target.macOS13,
        )
        mlmodel.short_description = "Gantry: wykrywanie błędów druku"
        mlmodel.save(str(folder / "model.mlpackage"))
        files["coreml"] = "model.mlpackage"
    except Exception as error:  # noqa: BLE001 - Core ML jest dodatkiem dla macOS
        notes.append(f"Pominięto plik Core ML: {error}")

    description = {
        "format": MODEL_FORMAT,
        "version": 1,
        "createdAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "architecture": "mobilenet_v3_small",
        "classes": [{"id": c["id"], "name": c["name"]} for c in classes],
        "okClass": "ok",
        "input": {"name": "image", "width": INPUT_SIZE, "height": INPUT_SIZE, "layout": "NCHW",
                  "color": "RGB", "range": [0, 1], "resize": "stretch-whole-frame"},
        "output": {"name": "probabilities", "softmax": True},
        "threshold": 0.8,
        "files": files,
        "training": {"epochs": epochs, "images": report["images"], "heldOut": report["heldOut"],
                     "accuracy": report["accuracy"]},
        "notes": notes,
    }
    (folder / "model.json").write_text(json.dumps(description, ensure_ascii=False, indent=2), encoding="utf-8")
    (folder / "raport.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    report["notes"] = notes
    package(folder)
    return folder


def package(folder: Path) -> Path:
    """Jeden plik do wczytania w Gantry: model.json, model.onnx i model.mlpackage w jednym zipie."""
    archive = folder / f"gantry-model-{folder.name}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(folder.rglob("*")):
            if path.is_file() and path != archive and path.name != "raport.json":
                bundle.write(path, path.relative_to(folder).as_posix())
    return archive


class Checker:
    """Ocena pojedynczego zdjęcia ostatnim modelem, przez ten sam plik ONNX, który dostanie Gantry."""

    def __init__(self) -> None:
        self._folder: Path | None = None
        self._session = None
        self._classes: list[dict] = []

    def check(self, folder: Path, image: Image.Image) -> dict:
        if folder != self._folder:
            import onnxruntime
            self._session = onnxruntime.InferenceSession(str(folder / "model.onnx"),
                                                         providers=["CPUExecutionProvider"])
            self._classes = json.loads((folder / "model.json").read_text(encoding="utf-8"))["classes"]
            self._folder = folder
        x = EVAL_TRANSFORM(image).unsqueeze(0).numpy()
        probabilities = self._session.run(None, {"image": x})[0][0]
        return {"model": folder.name,
                "probabilities": {c["id"]: float(p) for c, p in zip(self._classes, probabilities)}}


def remove_tree(path: Path) -> None:
    shutil.rmtree(path, ignore_errors=True)

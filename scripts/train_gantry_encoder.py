#!/usr/bin/env python3
"""Trenuje własny enkoder Gantry: obraz na wektor, z którego `DefectPrototypes` robi resztę.

Po co, skoro rozpoznawanie już działa. Bo nie działa dobrze, i wiadomo dlaczego. Dziś wektory liczy
`VNGenerateImageFeaturePrintRequest`, czyli enkoder ogólnego przeznaczenia, który nigdy w życiu nie
widział wydruku 3D. Odległości, które zwraca, opisują „jak bardzo te dwa zdjęcia są do siebie
podobne", a nie „czy na tym stole leży makaron". PrintGuard pokazał, że przy tej samej architekturze
(enkoder plus najbliższy prototyp) wymiana enkodera na douczony do tego zadania to różnica między
54 a 94 procentami. Tutaj więc zmienia się wyłącznie enkoder; bank, wzorce użytkownika, klasy i próg
zostają takie, jakie są.

Uczone jest podobieństwo, nie etykieta. Klasyfikator odpowiadałby „awaria" albo „nie", a to za mało:
Gantry musi umieć porównać klatkę z kamerą, której model nigdy nie widział, bo wzorce „idzie dobrze"
pochodzą z kamery użytkownika i powstają dopiero u niego. Dlatego stratą jest tu odległość między
wektorami tej samej klasy kontra różnych klas, a nie entropia krzyżowa.

Dane muszą pochodzić z kamer w komorze po obu stronach. Klasa „poprawnie" złożona ze zdjęć całych
drukarek na biurku już raz wszystko popsuła: dwie klasy znaczyły wtedy „na zewnątrz" i „wewnątrz",
a każda prawdziwa klatka lądowała po stronie spaghetti (docs/defect-starter-attribution.md).

    python3 scripts/train_gantry_encoder.py --data KATALOG --out KATALOG [--epochs 20]

`--data` ma mieć podkatalogi `spaghetti/` i `ok/`, a w nazwach plików prefiks kamery przed pierwszym
myślnikiem. Prefiks decyduje o podziale: cała kamera idzie do treningu albo do testu i nigdy do obu,
bo inaczej mierzy się to, czy model zapamiętał tło, a nie czy rozpoznaje wadę.
"""

import argparse
import json
import pathlib
import random
import sys

import torch
import torch.nn.functional as F
from torch import nn
from torch.utils.data import DataLoader, Dataset
from torchvision import transforms
from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small
from PIL import Image

SIDE = 224
LABELS = ["ok", "spaghetti"]


def camera_of(path: pathlib.Path) -> str:
    """Kamera, z której jest klatka. Nazwa pliku zaczyna się od jej identyfikatora."""
    stem = path.stem
    return stem.split("-")[0] if "-" in stem else stem[:2]


class Frames(Dataset):
    def __init__(self, items, train: bool):
        self.items = items
        # Bez kadrowania: kamera w komorze stoi nieruchomo, więc losowe wycinki uczyłyby modelu
        # czegoś, czego w pracy nigdy nie zobaczy. Zostaje odbicie i zmiana światła, bo jedno i
        # drugie naprawdę się zdarza.
        if train:
            self.tf = transforms.Compose([
                transforms.Resize((SIDE, SIDE)),
                transforms.RandomHorizontalFlip(),
                transforms.ColorJitter(brightness=0.3, contrast=0.3, saturation=0.1),
                transforms.ToTensor(),
            ])
        else:
            self.tf = transforms.Compose([transforms.Resize((SIDE, SIDE)), transforms.ToTensor()])

    def __len__(self):
        return len(self.items)

    def __getitem__(self, index):
        path, label = self.items[index]
        image = Image.open(path).convert("RGB")
        return self.tf(image), label


class Encoder(nn.Module):
    """MobileNetV3 Small bez głowy klasyfikacyjnej, z wektorem znormalizowanym do długości 1.

    Normalizacja jest po to, żeby odległość znaczyła to samo niezależnie od jasności klatki: bez niej
    ciemniejsze zdjęcie dostaje krótszy wektor i wygrywa porównania, których nie powinno wygrywać.
    """

    def __init__(self, width: int = 128):
        super().__init__()
        base = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.IMAGENET1K_V1)
        self.features = base.features
        self.pool = nn.AdaptiveAvgPool2d(1)
        self.head = nn.Linear(576, width)

    def forward(self, x):
        x = self.pool(self.features(x)).flatten(1)
        return F.normalize(self.head(x), dim=1)


def prototypical_loss(vectors, labels):
    """Strata prototypowa: każdy wektor ma być bliżej środka swojej klasy niż tej drugiej.

    Dokładnie to samo pytanie zadaje potem `DefectPrototypes.classify`, więc model uczy się zadania,
    które naprawdę dostanie, a nie jego przybliżenia.
    """
    centres = []
    present = []
    for label in range(len(LABELS)):
        mask = labels == label
        if mask.sum() == 0:
            continue
        centres.append(F.normalize(vectors[mask].mean(0), dim=0))
        present.append(label)
    if len(centres) < 2:
        return None
    centres = torch.stack(centres)
    # Ujemna odległość jako logit, skala 10: bez niej gradienty przy wektorach jednostkowych są za
    # płaskie, żeby cokolwiek się nauczyło.
    logits = -torch.cdist(vectors, centres) * 10
    target = torch.tensor([present.index(int(l)) for l in labels], device=vectors.device)
    return F.cross_entropy(logits, target)


def gather(root: pathlib.Path):
    items = []
    for label, name in enumerate(LABELS):
        folder = root / name
        for path in sorted(folder.glob("*.jpg")) + sorted(folder.glob("*.png")):
            items.append((path, label))
    return items


def split_by_camera(items, holdout_fraction=0.3, seed=42):
    """Cała kamera po jednej stronie. Podział po zdjęciach mierzyłby pamięć, nie umiejętność."""
    cameras = sorted({camera_of(path) for path, _ in items})
    random.Random(seed).shuffle(cameras)
    cut = max(1, int(len(cameras) * holdout_fraction))
    held = set(cameras[:cut])
    train = [i for i in items if camera_of(i[0]) not in held]
    test = [i for i in items if camera_of(i[0]) in held]
    return train, test, sorted(held)


@torch.no_grad()
def evaluate(model, train_items, test_items, device):
    """Mierzy to, co robi Gantry: prototypy z klatek treningowych, a klatki testowe do nich porównane."""
    model.eval()

    def vectors(items):
        loader = DataLoader(Frames(items, train=False), batch_size=32)
        out, labels = [], []
        for images, label in loader:
            out.append(model(images.to(device)).cpu())
            labels.append(label)
        return torch.cat(out), torch.cat(labels)

    bank, bank_labels = vectors(train_items)
    probe, probe_labels = vectors(test_items)
    centres = torch.stack([F.normalize(bank[bank_labels == l].mean(0), dim=0)
                           for l in range(len(LABELS))])
    guessed = torch.cdist(probe, centres).argmin(1)
    result = {}
    for label, name in enumerate(LABELS):
        truth = probe_labels == label
        said = guessed == label
        hit = int((truth & said).sum())
        result[name] = {
            "support": int(truth.sum()),
            "recall": round(hit / max(1, int(truth.sum())), 4),
            "precision": round(hit / max(1, int(said.sum())), 4),
        }
    result["accuracy"] = round(float((guessed == probe_labels).float().mean()), 4)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--batch", type=int, default=32)
    parser.add_argument("--width", type=int, default=128)
    args = parser.parse_args()

    torch.manual_seed(42)
    random.seed(42)
    device = "mps" if torch.backends.mps.is_available() else "cpu"

    items = gather(pathlib.Path(args.data))
    counts = {name: sum(1 for _, l in items if l == i) for i, name in enumerate(LABELS)}
    if min(counts.values()) < 30:
        print(f"Za mało klatek: {counts}. Obie klasy muszą mieć co najmniej 30.", file=sys.stderr)
        return 1
    train_items, test_items, held = split_by_camera(items)
    print(f"klatek: {counts}; odłożone kamery: {held}")

    model = Encoder(width=args.width).to(device)
    # Sama głowa i trzy ostatnie bloki: przy kilkuset klatkach strojenie całości tylko je zapamięta.
    for parameter in model.features[:-3].parameters():
        parameter.requires_grad = False
    optimiser = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=3e-4)
    loader = DataLoader(Frames(train_items, train=True), batch_size=args.batch, shuffle=True, drop_last=True)

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    best = -1.0
    history = []
    for epoch in range(args.epochs):
        model.train()
        total, batches = 0.0, 0
        for images, labels in loader:
            loss = prototypical_loss(model(images.to(device)), labels.to(device))
            if loss is None:
                continue
            optimiser.zero_grad()
            loss.backward()
            optimiser.step()
            total += float(loss)
            batches += 1
        scores = evaluate(model, train_items, test_items, device)
        history.append({"epoch": epoch, "loss": round(total / max(1, batches), 4), "held_out": scores})
        print(f"epoka {epoch}: strata {total / max(1, batches):.4f}  odłożone {scores['accuracy']}")
        if scores["accuracy"] > best:
            best = scores["accuracy"]
            torch.save(model.state_dict(), out / "encoder.pt")
            (out / "held-out.json").write_text(json.dumps(scores, indent=2))

    (out / "history.json").write_text(json.dumps(history, indent=2))
    (out / "training-config.json").write_text(json.dumps({
        "architecture": "torchvision.mobilenet_v3_small features + linear head, L2 normalised",
        "objective": "prototypical cross-entropy over class centres",
        "embedding_width": args.width,
        "input": f"{SIDE}x{SIDE} RGB, 0-1",
        "labels": LABELS,
        "counts": counts,
        "held_out_cameras": held,
        "split": "whole cameras held out; no frame appears on both sides",
        "epochs": args.epochs,
        "torch": torch.__version__,
    }, indent=2, ensure_ascii=False))
    print(f"najlepsza skuteczność na odłożonych kamerach: {best}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

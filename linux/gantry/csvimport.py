from __future__ import annotations

import csv
import io
from typing import Any


HEADERS = ("kind", "name", "host", "serial", "access_code", "port")


def template_csv() -> str:
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(HEADERS)
    return output.getvalue()


def parse_printer_csv(content: str, maximum: int = 200) -> list[dict[str, Any]]:
    reader = csv.DictReader(io.StringIO(content.lstrip("\ufeff")))
    if not reader.fieldnames:
        raise ValueError("Plik CSV nie ma nagłówka.")
    normalized = {name.strip().lower(): name for name in reader.fieldnames if name}
    missing = [name for name in ("name", "host") if name not in normalized]
    if missing:
        raise ValueError("Brak kolumn: " + ", ".join(missing))
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for line_number, row in enumerate(reader, start=2):
        values = {key: str(row.get(source, "") or "").strip() for key, source in normalized.items()}
        if not any(values.values()):
            continue
        name, host = values.get("name", ""), values.get("host", "")
        kind = values.get("kind", "bambu").lower() or "bambu"
        if kind not in {"bambu", "klipper", "prusa", "snapmaker", "elegoo_cc1", "elegoo_cc2"}:
            raise ValueError(f"Wiersz {line_number}: nieznany typ drukarki {kind}.")
        default_port = {"bambu": 8883, "klipper": 7125, "prusa": 80, "snapmaker": 8080,
                        "elegoo_cc1": 3030, "elegoo_cc2": 1883}[kind]
        serial, code = values.get("serial", ""), values.get("access_code", "")
        try:
            port = int(values.get("port") or str(default_port))
        except ValueError as error:
            raise ValueError(f"Wiersz {line_number}: niepoprawny port.") from error
        if kind not in {"bambu", "elegoo_cc1", "elegoo_cc2"} and not serial:
            serial = f"{kind}-{host}-{port}"
        if not name or not host or not serial or (kind in {"bambu", "prusa", "elegoo_cc2"} and not code):
            raise ValueError(f"Wiersz {line_number}: brakuje wymaganych danych.")
        if not 1 <= port <= 65535 or any(character.isspace() for character in host):
            raise ValueError(f"Wiersz {line_number}: niepoprawny adres lub port.")
        if serial in seen:
            raise ValueError(f"Wiersz {line_number}: powtórzony numer seryjny {serial}.")
        seen.add(serial)
        result.append({"kind": kind, "name": name, "host": host, "serial": serial, "code": code, "port": port})
        if len(result) > maximum:
            raise ValueError(f"Plik zawiera więcej niż {maximum} drukarek.")
    if not result:
        raise ValueError("Plik CSV nie zawiera drukarek.")
    return result

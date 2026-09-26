#!/usr/bin/env python3
"""Odtwarza Resources/defect-starter-v1.bank i -v2.bank z adresów w defect-starter-sources.tsv.

Pobiera zdjęcia na wolnych licencjach (CC BY 4.0 i CC0, lista w tym samym katalogu), a potem oddaje
je skryptowi Swift, który liczy z nich wektory Vision i zapisuje bank. Same zdjęcia zostają w cache
i nie trafiają do repozytorium: do działania Gantry nie są potrzebne, a ich miejsce jest tam, skąd
pochodzą. Kto i na jakiej licencji je udostępnił, opisuje docs/defect-starter-attribution.md.

    python3 scripts/build_defect_starter.py [--cache KATALOG] [--cap 64]
"""

import argparse
import concurrent.futures
import csv
import hashlib
import os
import pathlib
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "scripts" / "defect-starter-sources.tsv"
BUILDER = ROOT / "scripts" / "build_defect_starter.swift"
OUTPUT = ROOT / "Resources"
AGENT = "Gantry starter-bank builder (https://github.com/parametryczny/gantrybar)"


def fetch(job):
    path, url = job
    if path.exists() and path.stat().st_size > 2000:
        return True
    try:
        request = urllib.request.Request(url, headers={"User-Agent": AGENT})
        data = urllib.request.urlopen(request, timeout=45).read()
    except Exception:
        return False
    if len(data) < 2000:
        return False
    path.write_bytes(data)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", default=str(ROOT / ".defect-starter-cache"),
                        help="gdzie trzymać pobrane zdjęcia")
    parser.add_argument("--cap", type=int, default=64, help="ile wzorców na klasę")
    args = parser.parse_args()

    cache = pathlib.Path(args.cache)
    jobs = []
    with SOURCES.open(encoding="utf-8") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            folder = cache / row["label"]
            folder.mkdir(parents=True, exist_ok=True)
            name = hashlib.sha1(row["url"].encode()).hexdigest()[:16]
            jobs.append((folder / (name + ".jpg"), row["url"]))

    with concurrent.futures.ThreadPoolExecutor(12) as pool:
        got = sum(pool.map(fetch, jobs))
    print("pobrano %d z %d zdjęć" % (got, len(jobs)))
    if got < len(jobs) * 0.8:
        print("za mało zdjęć, żeby bank miał sens; sprawdź połączenie", file=sys.stderr)
        return 1

    result = subprocess.run(["swift", str(BUILDER), str(cache), str(OUTPUT), str(args.cap)])
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())

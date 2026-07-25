#!/usr/bin/env python3
"""
Reads items.csv and works out which vehicle each part fits, by reading the
description. Emits fitment.csv for loading into PostgreSQL.

    python3 etl/03_fitment.py data/out

Output: sku, make, model, year_from, year_to, confidence, matched_text

confidence is 'high' when both a model and a year were found, 'model_only'
when the year is missing, and nothing is emitted when no model was recognised.
Everything is a first pass - the point is to get 60-70% of the way there so a
human corrects rather than types from scratch.
"""
import csv
import re
import sys
import unicodedata
from pathlib import Path

# Models seen in this catalogue, mapped to their make. Add to this as you find
# gaps - it is the only part of the parser that needs local knowledge.
MODELS = {
    "Toyota": ["COROLLA", "CORONA", "CARINA", "LEVIN", "HIACE", "CALDINA", "HILUX",
               "SURF", "STARLET", "CARIB", "SPRINTER", "RAV 4", "RAV4", "IPSUM",
               "CAMRY", "SPACIO", "GAIA", "GRANVIA", "CELICA", "PROBOX", "TERCEL",
               "MARK 2", "CRESTA", "VIGO", "REVO", "FJ40", "LAND CRUISSER",
               "LAND CRUISER", "AVENSIS", "YARIS", "PREMIO", "NOAH", "DYNA",
               "TOWNACE", "LITEACE", "COASTER", "FORTUNER", "ETIOS"],
    "Nissan": ["SUNNY", "MARCH", "MICRA", "SKYLINE", "PULSAR", "AVENIR", "PATROL",
               "PRIMERA", "TIIDA", "SENTRA", "NAVARA", "VANNETE", "BLUEBIRD",
               "BLUBIRT", "TERRANO", "X-TRAIL", "URVAN", "B12", "B13", "B14",
               "E25", "D21"],
    "Mitsubishi": ["LANCER", "MONTERO", "PAJERO", "GALANT", "COLT", "ECLIPSE",
                   "MIRAGE", "CHARIOT", "L200", "GRANDIS", "ASX", "OUTLANDER",
                   "CANTER", "JUNIOR"],
    "Honda": ["CIVIC", "ACCORD", "CRV", "CR-V", "PRELUDE", "ODYSSEY", "STREAM"],
    "Suzuki": ["SWIFT", "VITARA", "ALTO", "SAMURAI", "APV", "IGNIS", "JIMNY",
               "XL7", "BALENO", "CELERIO", "ERTIGA"],
    "Subaru": ["IMPREZA", "FORESTER", "LEGACY", "DOMINGO", "OUTBACK", "SAMBAR"],
    "Mazda": ["BONGO", "BT50", "BT-50", "DEMIO", "FAMILIA", "PREMACY"],
    "Hyundai": ["I10", "ACCENT", "TUCSON", "SANTA FE", "ELANTRA", "H1", "GETZ",
                "STAREX"],
    "Ford": ["RANGER", "EXPLORER", "FIESTA", "FOCUS", "ESCAPE", "F150"],
    "Volkswagen": ["GOLF", "POLO", "PASSAT", "AMAROK", "GOL"],
    "Jeep": ["RENEGADE", "CHEROKEE", "COMPASS", "WRANGLER"],
    "Chevrolet": ["COLORADO", "SPARK", "AVEO", "LUV", "DMAX", "D-MAX"],
    "Renault": ["KWID", "KIWID", "LOGAN", "SANDERO", "DUSTER"],
    "Dodge": ["RAM"],
    "Daihatsu": ["TERIOS", "HIJET", "CHARADE"],
    "Kia": ["RIO", "SPORTAGE", "PICANTO", "SORENTO"],
    "Isuzu": ["TROOPER", "RODEO"],
    "Datsun": ["B310", "1200"],
}

# Misspellings of makes that appear in the file.
MAKE_FIXES = {"SUZUQUI": "Suzuki", "TOYORA": "Toyota", "TOYOTASPACIO": "Toyota",
              "NISSAAN": "Nissan", "VOLKSWAGEN": "Volkswagen"}

# Part codes look like 212-1592 or 214-11A7 - strip them before hunting years,
# or 1967 in "215-1967" becomes a model year.
CODE_RE = re.compile(r"\b[0-9A-Z]{2,4}-[0-9A-Z][0-9A-Z\-]*\b", re.I)
YEAR4_RE = re.compile(r"(?<![\w\-])((?:19|20)\d{2})(?![\w\-])")
YEAR2_RE = re.compile(r"(?<![\w.\-/])(\d{2})(?![\w\-])")


def strip_accents(s):
    return "".join(c for c in unicodedata.normalize("NFD", s)
                   if unicodedata.category(c) != "Mn")


def norm(s):
    return re.sub(r"\s+", " ", strip_accents(s).upper()).strip()


def expand_two_digit(y):
    """87 -> 1987, 11 -> 2011. Cars in this catalogue start in the 1970s."""
    y = int(y)
    return 1900 + y if y >= 60 else 2000 + y


def find_years(text):
    """Return (year_from, year_to) or (None, None)."""
    clean = CODE_RE.sub(" ", text)
    years = [int(y) for y in YEAR4_RE.findall(clean)]
    if not years:
        years = [expand_two_digit(y) for y in YEAR2_RE.findall(clean)]
    years = [y for y in years if 1965 <= y <= 2030]
    if not years:
        return None, None
    return min(years), max(years)


def find_vehicle(text):
    """Return (make, model, matched) or (None, None, None)."""
    t = norm(text)
    best = None
    for make, models in MODELS.items():
        for model in models:
            if re.search(rf"(?<![A-Z0-9]){re.escape(model)}(?![A-Z0-9])", t):
                # Prefer the longest match: "RAV 4" beats "RAV".
                if best is None or len(model) > len(best[1]):
                    best = (make, model, model)
    if best:
        return best
    for wrong, make in MAKE_FIXES.items():
        if wrong in t:
            return make, None, wrong
    for make in MODELS:
        if norm(make) in t:
            return make, None, make
    return None, None, None


def main(outdir):
    outdir = Path(outdir)
    items = list(csv.DictReader((outdir / "items.csv").open(encoding="utf-8")))

    rows, stats = [], {"high": 0, "model_only": 0, "make_only": 0, "none": 0}
    for it in items:
        desc = it["description"]
        make, model, matched = find_vehicle(desc)
        if not make:
            stats["none"] += 1
            continue
        y1, y2 = find_years(desc)
        if model and y1:
            conf = "high"
        elif model:
            conf = "model_only"
        else:
            conf = "make_only"
        stats[conf] += 1
        rows.append({"sku": it["sku"], "make": make, "model": model or "",
                     "year_from": y1 or "", "year_to": y2 or "",
                     "confidence": conf, "matched_text": matched})

    path = outdir / "fitment.csv"
    with path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["sku", "make", "model", "year_from",
                                           "year_to", "confidence", "matched_text"])
        w.writeheader()
        w.writerows(rows)

    total = len(items)
    print(f"{path.name}: {len(rows)} of {total} items matched to a vehicle")
    for k, v in stats.items():
        print(f"  {k:12} {v:5d}  ({v * 100 // total}%)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "data/out")

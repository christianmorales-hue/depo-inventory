#!/usr/bin/env python3
"""
Import new supplier catalogs into the item table.

    python3 etl/04_import_catalog.py data/raw/LISTA_EN_STOCK_04-03-2026.csv --currency usd
    python3 etl/04_import_catalog.py data/raw/LISTA_MAU_DEPO_TYG_21-03-26_-_copia.csv --currency bob --fx 6.96

Writes a load-ready CSV to data/out/new_items_<basename>.csv.

Design decisions:
  - No stock movements are created. These are just catalog rows; every branch
    starts at zero for these items. Physical count adds units later.
  - Prices are always stored in USD in the database. If the file is in BOB,
    we divide by the FX rate given on the command line.
  - Items in the file that already exist in the DB (matched by part_code
    after normalisation) are skipped, not overwritten. A separate CSV is
    written listing them, so a human can decide whether to update prices.
"""
import argparse
import csv
import re
import sys
import unicodedata
from pathlib import Path


def norm(s):
    """Uppercase, unaccented, alphanumeric only. Matches the DB norm_text()."""
    s = "".join(c for c in unicodedata.normalize("NFD", s or "")
                if unicodedata.category(c) != "Mn")
    return re.sub(r"[^A-Z0-9]+", " ", s.upper()).strip()


def clean(s):
    return re.sub(r"\s+", " ", (s or "").strip())


def to_number(s):
    s = clean(s).replace(".", "").replace(",", ".")
    return float(s) if re.fullmatch(r"-?\d+(\.\d+)?", s or "") else None


# Very short category hints from the first word of the description.
CATEGORY_HINTS = {
    "AMORT": "Amortiguador", "FAROL": "Farol", "ESPEJO": "Espejo",
    "STOP": "Stop", "MEDIA": "Media luz", "GUIN": "Guiñador",
    "MU": "Muñón", "PARACHOQUE": "Parachoque", "MASCARA": "Máscara",
    "BUCHERA": "Buchera", "CAPO": "Capó", "COLA": "Cola",
    "BOMBA": "Bomba", "JUNTA": "Junta", "RETROVISOR": "Espejo",
    "REFLECTOR": "Reflector", "ALOGENO": "Alógeno", "TAPA": "Tapa",
}


def category_of(desc):
    if not desc:
        return ""
    first = norm(desc).split()[0] if norm(desc) else ""
    for key, cat in CATEGORY_HINTS.items():
        if first.startswith(key):
            return cat
    return ""


def split_side(code):
    m = re.match(r"^(.*?)[-\s]([LR])$", code or "", re.IGNORECASE)
    return (m.group(1), m.group(2).upper()) if m else (code or "", None)


def side_from_description(desc):
    """Some file 1 rows encode side in the description: 'AMORT DEL L' or '(LH)'."""
    if not desc:
        return None
    if re.search(r"\b(LH|IZQUIERD|\(L\)| L\b)", desc, re.I):
        return "L"
    if re.search(r"\b(RH|DERECH|\(R\)| R\b)", desc, re.I):
        return "R"
    return None


def read_file1(path):
    """BIGDAM/YOITOKI: header on line 7 (CODIGO LOCAL, N.PIEZA, DESCRIPCION,
    ORIGEN, MARCA, UNIDAD, CANTIDAD, P.UNIT.). Price is USD."""
    with path.open(encoding="utf-8-sig", newline="") as fh:
        rows = list(csv.reader(fh, delimiter=";"))
    # find header
    header_idx = next(i for i, r in enumerate(rows)
                      if r and r[0].strip() == "CODIGO LOCAL")
    out = []
    for r in rows[header_idx + 1:]:
        if not r or len(r) < 8:
            continue
        code, part_number, desc, origin, brand = (clean(x) for x in r[:5])
        price = to_number(r[7])
        # stop at totals row
        if "TOTAL" in desc.upper() or not code or not desc:
            continue
        out.append({"code": code, "part_number": part_number,
                    "description": desc, "origin": origin, "supplier": brand,
                    "price": price})
    return out


def read_file2(path):
    """TYG format: comma-delimited semicolon file with a big schema. Price in
    PRECIO_1_BS is in Bolivianos."""
    with path.open(encoding="utf-8-sig", newline="") as fh:
        rows = list(csv.reader(fh, delimiter=";"))
    header = [h.strip() for h in rows[0]]
    idx = {name: i for i, name in enumerate(header)}
    need = ("CODIGO_ITEM", "DESCRIPCION", "PRECIO_1_BS", "NOMBRE_MARCA",
            "NOMBRE_ORIGEN")
    missing = [n for n in need if n not in idx]
    if missing:
        sys.exit(f"file 2 is missing columns: {missing}")
    out = []
    for r in rows[1:]:
        if len(r) < len(header) or not any(c.strip() for c in r):
            continue
        code = clean(r[idx["CODIGO_ITEM"]])
        desc = clean(r[idx["DESCRIPCION"]])
        if not code or not desc:
            continue
        out.append({"code": code, "part_number": clean(r[idx.get("NRO_PIEZA", 1)]),
                    "description": desc,
                    "origin": clean(r[idx["NOMBRE_ORIGEN"]]),
                    "supplier": clean(r[idx["NOMBRE_MARCA"]]),
                    "price": to_number(r[idx["PRECIO_1_BS"]])})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("--currency", choices=("usd", "bob"), required=True)
    ap.add_argument("--fx", type=float, default=6.96,
                    help="Bs per USD, only used when --currency=bob (default 6.96)")
    ap.add_argument("--outdir", type=Path, default=Path("data/out"))
    args = ap.parse_args()

    # Sniff the format from the header.
    with args.input.open(encoding="utf-8-sig") as fh:
        first_data = fh.read(500)
    if "CODIGO_ITEM" in first_data:
        raw = read_file2(args.input)
    else:
        raw = read_file1(args.input)

    print(f"read {len(raw)} rows from {args.input.name}")

    # Convert price to USD if the file is in Bs.
    for r in raw:
        if r["price"] is None:
            r["price_usd"] = None
        elif args.currency == "usd":
            r["price_usd"] = round(r["price"], 2)
        else:
            r["price_usd"] = round(r["price"] / args.fx, 2)

    # Deduplicate within this file itself (part_code seen twice -> keep the
    # first one, note the collision).
    dedup, seen = [], {}
    dupes_in_file = 0
    for r in raw:
        key = norm(r["code"])
        if not key:
            continue
        if key in seen:
            dupes_in_file += 1
            continue
        seen[key] = True
        dedup.append(r)
    if dupes_in_file:
        print(f"  {dupes_in_file} duplicates within the file (kept first occurrence)")

    # Prepare load-ready rows.
    args.outdir.mkdir(parents=True, exist_ok=True)
    out_path = args.outdir / f"new_items_{args.input.stem}.csv"
    with out_path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh, delimiter=",")
        w.writerow(["part_code", "base_code", "side", "description",
                    "price_usd", "product_type", "make", "supplier", "origin",
                    "part_number"])
        for r in dedup:
            base, side = split_side(r["code"])
            if not side:
                side = side_from_description(r["description"])
                base = r["code"]
            w.writerow([r["code"], base, side or "", r["description"],
                        r["price_usd"] if r["price_usd"] is not None else "",
                        category_of(r["description"]),
                        "",                                # make: leave for later
                        r["supplier"], r["origin"], r["part_number"]])

    print(f"wrote {out_path} ({len(dedup)} items)")
    print(f"\nNext: load into the database with 13_import_catalog.sql")


if __name__ == "__main__":
    main()

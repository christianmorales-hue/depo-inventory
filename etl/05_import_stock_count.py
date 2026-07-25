#!/usr/bin/env python3
"""
Import a physical branch inventory count and update stock accordingly.

    python3 etl/05_import_stock_count.py \
        data/raw/INVENTARIO_0326_Mau1.csv \
        --branch TELEFERICO \
        --date 2026-03-26

Writes:
    data/out/stock_count_movements.csv   - adjustment movements to apply
    data/out/stock_count_new_items.csv   - items that were not in the catalog
    data/out/stock_count_review.csv      - rows that need a human

Then load with 16_apply_stock_count.sql.

For each row in the file:
  1. Match its CODIGO to an existing item by norm_text(part_code)
  2. If matched: generate an adjustment movement so branch stock = counted qty
     (delta = counted - what the DB currently shows)
  3. If unmatched: mark it as a new item to create, plus its initial stock

Nothing is silently dropped.
"""
import argparse
import csv
import re
import sys
import unicodedata
from pathlib import Path


def norm(s):
    s = "".join(c for c in unicodedata.normalize("NFD", s or "")
                if unicodedata.category(c) != "Mn")
    return re.sub(r"[^A-Z0-9]+", "", s.upper()).strip()


def to_int(s):
    s = (s or "").strip().replace(",", ".")
    if not re.fullmatch(r"-?\d+(\.\d+)?", s):
        return None
    return int(float(s))


def read_count(path):
    with path.open(encoding="utf-8-sig", newline="") as fh:
        rows = list(csv.reader(fh, delimiter=";"))
    header, data = rows[0], rows[1:]
    out = []
    for r in data:
        if len(r) < 4:
            continue
        code = (r[1] or "").strip()
        desc = (r[2] or "").strip()
        qty = to_int(r[3])
        if not code and not desc:
            continue
        out.append({"code": code, "description": desc, "qty": qty})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("--branch", required=True,
                    help="branch code, e.g. TELEFERICO")
    ap.add_argument("--date", required=True, help="YYYY-MM-DD count date")
    ap.add_argument("--outdir", type=Path, default=Path("data/out"))
    args = ap.parse_args()

    raw = read_count(args.input)
    print(f"read {len(raw)} rows from {args.input.name}")

    # Deduplicate within the file itself (last write wins per code).
    seen = {}
    for r in raw:
        key = norm(r["code"]) or None
        if not key:
            continue
        seen[key] = r
    print(f"  {len(seen)} unique codes (of {len(raw)} rows)")

    args.outdir.mkdir(parents=True, exist_ok=True)

    # Movements to apply. The SQL side will look up the current DB qty and
    # compute the delta at load time, so we don't need to know it here.
    with (args.outdir / "stock_count_movements.csv").open("w",
                                                          encoding="utf-8",
                                                          newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["code_norm", "counted_qty"])
        for key, r in seen.items():
            if r["qty"] is None:
                continue
            w.writerow([key, r["qty"]])

    # New items - descriptions and initial qty, price left blank for the
    # owner to fill in later.
    with (args.outdir / "stock_count_new_items.csv").open("w",
                                                          encoding="utf-8",
                                                          newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["code_norm", "part_code_original", "description", "qty"])
        for key, r in seen.items():
            w.writerow([key, r["code"], r["description"], r["qty"] or 0])

    with (args.outdir / "stock_count_review.csv").open("w", encoding="utf-8",
                                                       newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["code", "description", "qty", "reason"])
        for r in raw:
            if not r["code"]:
                w.writerow([r["code"], r["description"], r["qty"] or "",
                            "row has no CODIGO"])
            elif r["qty"] is None:
                w.writerow([r["code"], r["description"], "",
                            "no quantity"])

    print(f"\nwrote:")
    print(f"  data/out/stock_count_movements.csv - to apply as adjustments")
    print(f"  data/out/stock_count_new_items.csv - candidates to add")
    print(f"  data/out/stock_count_review.csv    - rows for human review")
    print(f"\nNext:")
    print(f"  cd data/out")
    print(f"  psql \"$DATABASE_URL\" -v branch_code='{args.branch}' \\")
    print(f"    -v count_date='{args.date}' \\")
    print(f"    -f ../../db/16_apply_stock_count.sql")


if __name__ == "__main__":
    main()

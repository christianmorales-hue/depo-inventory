#!/usr/bin/env python3
"""
Cleans INVENTARIO ENERO 2023.csv and emits load-ready CSVs for PostgreSQL.

    python3 02_transform.py "INVENTARIO ENERO 2023.csv" ./out

Outputs (UTF-8, comma-separated, dot decimals, empty string = NULL):
    categories.csv     name
    items.csv          sku, part_code, base_code, side, category, description,
                       unit_price, legacy_row_id, needs_review
    item_aliases.csv   sku, alias, source
    opening_stock.csv  sku, branch_code, qty, condition, note
    review_needed.csv  every row a human must look at, with the reason

Nothing is silently dropped. Anything ambiguous lands in review_needed.csv.
"""
import csv
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

RAW_COLUMNS = [
    "ID", "CODIGO", "DETALLE", "RECUENTO", "X4", "DEFECTUOSO", "CU",
    "X7", "TOTAL", "X9", "M3MARIAS", "X11", "TELEFERICO", "N2024A", "N2024B",
]

BRANCH_COLUMNS = {"M3MARIAS": "3MARIAS", "TELEFERICO": "TELEFERICO"}

# Spelling variants of the category word seen in the file, mapped to one label.
CATEGORY_FIXES = {
    "GUINADOR": "Guiñador",
    "GUINADORES": "Guiñador",
    "MUNON": "Muñón",
    "ALOGENO": "Alógeno",
    "MASCARA": "Máscara",
    "CAPUCHON": "Capuchón",
}


def strip_accents(s: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", s)
                   if unicodedata.category(c) != "Mn")


def norm(s: str) -> str:
    """Matching key: uppercase, unaccented, single-spaced, alphanumeric only."""
    return re.sub(r"[^A-Z0-9]+", " ", strip_accents(s).upper()).strip()


def clean_cell(s: str) -> str:
    s = (s or "").replace("\u00a0", " ")
    s = re.sub(r"\s+", " ", s).strip()
    return "" if s in {"|", "`", "-", "_"} else s          # known junk cells


def to_number(s: str):
    """'142,5' -> 142.5 ; '' or junk -> None. Spanish decimal comma."""
    s = clean_cell(s).replace(".", "").replace(",", ".")
    if not re.fullmatch(r"-?\d+(\.\d+)?", s or ""):
        return None
    return float(s)


def to_int(s: str):
    n = to_number(s)
    if n is None:
        return None
    return int(n) if float(n).is_integer() else None


def split_side(code: str):
    """'210-0202-002-L' -> ('210-0202-002', 'L')"""
    m = re.match(r"^(.*?)[-\s]([LR])$", code, re.IGNORECASE)
    if m:
        return m.group(1), m.group(2).upper()
    return code, None


def category_of(description: str, counts: Counter) -> str:
    if not description:
        return ""
    word = description.split()[0]
    key = norm(word)
    if key in CATEGORY_FIXES:
        return CATEGORY_FIXES[key]
    # Otherwise use the most common capitalisation seen for that word.
    variants = counts.get(key)
    if variants:
        return variants.most_common(1)[0][0]
    return word.capitalize()


def main(src: Path, outdir: Path) -> None:
    outdir.mkdir(parents=True, exist_ok=True)

    with src.open(encoding="utf-8-sig", newline="") as fh:
        rows = list(csv.reader(fh, delimiter=";"))

    header, body = rows[0], rows[1:]
    if len(header) != len(RAW_COLUMNS):
        print(f"warning: expected {len(RAW_COLUMNS)} columns, found {len(header)}",
              file=sys.stderr)

    records = []
    for line_no, raw in enumerate(body, start=2):
        raw = (raw + [""] * len(RAW_COLUMNS))[:len(RAW_COLUMNS)]
        records.append({"_line": line_no,
                        **{k: clean_cell(v) for k, v in zip(RAW_COLUMNS, raw)}})

    # Pass 1: learn the dominant capitalisation of each category word.
    cat_counts = defaultdict(Counter)
    for r in records:
        if r["DETALLE"]:
            w = r["DETALLE"].split()[0]
            cat_counts[norm(w)][w.capitalize() if w.isupper() else w] += 1

    items, aliases, stock, review = [], [], [], []
    seen_codes = defaultdict(list)
    seq = 0

    for r in records:
        code, detail = r["CODIGO"], r["DETALLE"]

        # Drop structural noise: blank spacers and the embedded grand-total row.
        if not code and not detail:
            if r["TOTAL"] or r["CU"]:
                review.append({**r, "_reason": "summary/total row - not an item"})
            continue

        if not detail:
            review.append({**r, "_reason": "no description"})
        if not code:
            review.append({**r, "_reason": "no CODIGO"})

        # The 10 rows where a second description leaked into the unnamed
        # column 11. Keep the text as a note and as an alias - never discard it.
        leaked = r["X11"] if r["X11"] and not to_number(r["X11"]) else ""
        if leaked:
            review.append({**r, "_reason": f"stray text in unnamed column: {leaked}"})

        seq += 1
        sku = f"DEPO-{seq:05d}"
        base, side = split_side(code) if code else ("", None)
        category = category_of(detail, cat_counts)

        items.append({
            "sku": sku,
            "part_code": code,
            "base_code": base,
            "side": side or "",
            "category": category,
            "description": detail or (code or "SIN DESCRIPCION"),
            "unit_price": to_number(r["CU"]) if to_number(r["CU"]) is not None else "",
            "legacy_row_id": r["ID"],
            "needs_review": "true" if (not code or not detail or leaked) else "false",
        })

        # Seed aliases with everything a human has already typed for this item.
        for alias in filter(None, {detail, code, base, leaked}):
            aliases.append({"sku": sku, "alias": alias, "source": "legacy"})

        if code:
            seen_codes[norm(code)].append(sku)

        # ---- opening stock -------------------------------------------------
        total = to_int(r["RECUENTO"])
        assigned = 0
        for col, branch_code in BRANCH_COLUMNS.items():
            qty = to_int(r[col])
            if not qty:
                continue
            # The branch columns are not consistently quantities - in many rows
            # they hold a money value (qty x unit price). Accept a cell only when
            # it is a plausible count; flag everything else for a physical recount.
            if total is None or qty > total:
                review.append({**r, "_reason":
                               f"{col}={qty} is not a plausible quantity "
                               f"(RECUENTO={r['RECUENTO']}, C/U={r['CU']}) - recount"})
                continue
            stock.append({"sku": sku, "branch_code": branch_code, "qty": qty,
                          "condition": "good", "note": "opening count 2023-01"})
            assigned += qty

        # Known total but no trusted branch breakdown -> park it in the
        # unassigned bucket. Never invent a location.
        if total is not None and total > assigned:
            stock.append({"sku": sku, "branch_code": "SIN_ASIGNAR",
                          "qty": total - assigned, "condition": "good",
                          "note": "location unknown in legacy file"})

        defective = to_int(r["DEFECTUOSO"])
        if defective:
            stock.append({"sku": sku, "branch_code": "SIN_ASIGNAR", "qty": defective,
                          "condition": "defective", "note": "marked Defectuoso"})

    # Duplicate part codes must be merged by a human, not by a script.
    for code_key, skus in seen_codes.items():
        if len(skus) > 1:
            review.append({"CODIGO": code_key, "_reason":
                           f"duplicate CODIGO shared by {', '.join(skus)}"})

    categories = sorted({i["category"] for i in items if i["category"]})

    def write(name, fieldnames, data):
        path = outdir / name
        with path.open("w", encoding="utf-8", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
            w.writeheader()
            w.writerows(data)
        print(f"{path.name:22} {len(data):5d} rows")

    write("categories.csv", ["name"], [{"name": c} for c in categories])
    write("items.csv", ["sku", "part_code", "base_code", "side", "category",
                        "description", "unit_price", "legacy_row_id",
                        "needs_review"], items)
    write("item_aliases.csv", ["sku", "alias", "source"], aliases)
    write("opening_stock.csv", ["sku", "branch_code", "qty", "condition", "note"],
          stock)
    write("review_needed.csv", ["_line", "_reason", "ID", "CODIGO", "DETALLE",
                                "RECUENTO", "CU", "TOTAL"], review)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]))

"""Scan the списание-восстановление (write-off/restoration) Excel archive and
consolidate contract numbers + event dates into one CSV.

ПРОСТЫМ ЯЗЫКОМ: обходит папки R:\\!!!ukr1\\списание-восстановление\\2025 и \\2026,
читает каждый .xlsx (шапка таблицы — 7-я строка листа), берёт только 2-ю
колонку («Контракт») и дату операции — дату ищем сначала в НАЗВАНИИ ЛИСТА,
если там нет — в ИМЕНИ ФАЙЛА (например, "...на 29.04.2026 года!!!.xlsx" ->
2026-04-29). Один загон = одна строка (contract_number, event_date,
source_file, source_sheet) в итоговом CSV — это сырьё для censoring-логики
Фазы C (займы, которые продали/списали/простили, не должны засчитываться как
«безопасно вылечились» только потому что пропали из портфеля).

Usage:
    python scripts/writeoff_restoration_scan.py
    python scripts/writeoff_restoration_scan.py --base-dir "R:\\!!!ukr1\\списание-восстановление" --out censoring_events.csv
    python scripts/writeoff_restoration_scan.py --header-row 6 --contract-col 1   # 0-indexed overrides

Requires: pandas, openpyxl (pip install pandas openpyxl)
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import pandas as pd

DEFAULT_BASE_DIR = Path(r"R:\!!!ukr1\списание-восстановление")
DEFAULT_YEARS = ["2025", "2026"]
DEFAULT_OUT = Path(r"C:\project_mz\surau\DPDRelaxing\raw_data\censoring_events.csv")

# Excel row 7 (1-indexed) is the header row -> pandas header=6 (0-indexed).
DEFAULT_HEADER_ROW = 6
# "Контракт" is the 2nd column -> index 1 (0-indexed).
DEFAULT_CONTRACT_COL = 1

DATE_PATTERN = re.compile(r"(\d{1,2})[.\-_](\d{1,2})[.\-_](\d{4})")


def parse_date_from_text(text: str) -> pd.Timestamp | None:
    """Find a DD.MM.YYYY-style date anywhere in a string (filename or sheet name)."""
    match = DATE_PATTERN.search(text)
    if not match:
        return None
    day, month, year = (int(g) for g in match.groups())
    try:
        return pd.Timestamp(year=year, month=month, day=day)
    except ValueError:
        return None


def find_excel_files(base_dir: Path, years: list[str]) -> list[Path]:
    files: list[Path] = []
    for year in years:
        year_dir = base_dir / year
        if not year_dir.exists():
            print(f"  (skip) {year_dir} not found")
            continue
        found = sorted(year_dir.rglob("*.xlsx"))
        print(f"  {year_dir}: {len(found)} .xlsx file(s)")
        files.extend(found)
    return files


def extract_contracts(path: Path, header_row: int, contract_col: int) -> pd.DataFrame:
    """One row per contract found in every sheet of `path`, dated by sheet name
    (preferred) or filename (fallback)."""
    empty = pd.DataFrame(columns=["contract_number", "event_date", "source_file", "source_sheet"])
    file_date = parse_date_from_text(path.stem)

    try:
        xls = pd.ExcelFile(path)
    except Exception as exc:  # noqa: BLE001 - report and skip, don't kill the whole scan
        print(f"  [ERROR] could not open {path.name}: {exc}")
        return empty

    frames = []
    for sheet_name in xls.sheet_names:
        event_date = parse_date_from_text(sheet_name) or file_date
        if event_date is None:
            print(f"  [WARN] no date in filename or sheet name: {path.name} / '{sheet_name}' -- skipped")
            continue
        try:
            df = xls.parse(sheet_name, header=header_row, dtype=str)
        except Exception as exc:  # noqa: BLE001
            print(f"  [WARN] could not read sheet '{sheet_name}' in {path.name}: {exc}")
            continue
        if df.shape[1] <= contract_col:
            print(
                f"  [WARN] sheet '{sheet_name}' in {path.name} has only {df.shape[1]} "
                f"column(s), expected > {contract_col} -- skipped"
            )
            continue
        contracts = df.iloc[:, contract_col].dropna().astype(str).str.strip()
        contracts = contracts[contracts != ""]
        if contracts.empty:
            continue
        frames.append(
            pd.DataFrame(
                {
                    "contract_number": contracts.values,
                    "event_date": event_date,
                    "source_file": path.name,
                    "source_sheet": sheet_name,
                }
            )
        )

    return pd.concat(frames, ignore_index=True) if frames else empty


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-dir", type=Path, default=DEFAULT_BASE_DIR)
    parser.add_argument("--years", nargs="+", default=DEFAULT_YEARS)
    parser.add_argument("--header-row", type=int, default=DEFAULT_HEADER_ROW)
    parser.add_argument("--contract-col", type=int, default=DEFAULT_CONTRACT_COL)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    print(f"Scanning {args.base_dir} for years {args.years} ...")
    files = find_excel_files(args.base_dir, args.years)
    print(f"\nFound {len(files)} .xlsx file(s) total.\n")

    all_rows = []
    for f in files:
        rel = f.relative_to(args.base_dir)
        extracted = extract_contracts(f, args.header_row, args.contract_col)
        print(f"{rel}  ->  {len(extracted)} contract row(s)")
        all_rows.append(extracted)

    result = (
        pd.concat(all_rows, ignore_index=True)
        if all_rows
        else pd.DataFrame(columns=["contract_number", "event_date", "source_file", "source_sheet"])
    )
    result = result.drop_duplicates()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    result.to_csv(args.out, index=False, encoding="utf-8-sig")

    print(f"\nWrote {len(result)} row(s), {result['contract_number'].nunique()} distinct contract(s) to {args.out}")
    if not result.empty:
        print("\nRows by month:")
        by_month = result.assign(month=result["event_date"].dt.to_period("M")).groupby("month").size()
        print(by_month.to_string())


if __name__ == "__main__":
    main()

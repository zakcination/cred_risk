"""Scan the списание-восстановление (write-off/restoration) Excel archive and
consolidate contract numbers + event dates into one CSV.

ПРОСТЫМ ЯЗЫКОМ: обходит папки R:\\!!!ukr1\\списание-восстановление\\2025 и \\2026,
читает каждый .xlsx (шапка таблицы — 7-я строка листа), берёт только 2-ю
колонку («Контракт») и дату операции. Один загон = одна строка
(contract_number, event_date, ...) в итоговом CSV — это сырьё для
censoring-логики Фазы C (займы, которые продали/списали/простили, не должны
засчитываться как «безопасно вылечились» только потому что пропали из
портфеля).

КАК ОПРЕДЕЛЯЕТСЯ ДАТА. Месяц берём из ПАПКИ (архив разложен как
\\2025\\12.2025\\...), а имя листа/файла может только уточнить ДЕНЬ внутри
этого месяца. Так сделано не из аккуратности: в архиве встречаются файлы,
скопированные с прошлого месяца без переименования листа — например
SERVICING_tag11_20251229.xlsx с листом «SERVICING_tag11_20251030». Приоритет
«сначала лист» проставил бы декабрьскому списанию октябрьскую дату. Папка
такой ошибки не делает, поэтому она главнее, а расхождение логируется.

Распознаются: 29.04.2026 / 29-04-2026, компактный 20251229, и словами
(«30 декабря», «в октябре 2025 года»). Если дня установить не удалось, но
папка известна — ставим 1-е число и помечаем date_precision='month'
(для censoring этого достаточно: сверка идёт с помесячными срезами).

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

OUT_COLUMNS = [
    "contract_number", "event_date", "date_precision", "date_source",
    "source_file", "source_sheet",
]

# 29.04.2026 / 29-04-2026 / 29_04_2026
DATE_DMY = re.compile(r"(?<!\d)(\d{1,2})[.\-_](\d{1,2})[.\-_](\d{4})(?!\d)")
# 20251229 -- the SERVICING_tag11_* family uses this, no separators
DATE_YMD_COMPACT = re.compile(r"(?<!\d)(20\d{2})(\d{2})(\d{2})(?!\d)")
# folder names: 12.2025 or 2025.12
FOLDER_MONTH_DMY = re.compile(r"^(\d{1,2})[.\-_](\d{4})$")
FOLDER_MONTH_YMD = re.compile(r"^(\d{4})[.\-_](\d{1,2})$")

# Stems cover the inflected forms: «декабря», «декабре», «декабрь».
RU_MONTH_STEMS = [
    ("январ", 1), ("феврал", 2), ("март", 3), ("апрел", 4), ("ма[йяе]", 5),
    ("июн", 6), ("июл", 7), ("август", 8), ("сентябр", 9), ("октябр", 10),
    ("ноябр", 11), ("декабр", 12),
]


def _ru_day_month(text: str) -> tuple[int, int] | None:
    """«30 декабря» -> (30, 12). Day-and-month only; the year comes elsewhere."""
    for stem, month in RU_MONTH_STEMS:
        match = re.search(rf"(?<!\d)(\d{{1,2}})\s+{stem}", text, re.IGNORECASE)
        if match:
            return int(match.group(1)), month
    return None


def parse_date_from_text(text: str, year_hint: int | None = None) -> pd.Timestamp | None:
    """Best day-precision date found in a filename or sheet name, or None.

    `year_hint` (normally the folder's year) lets «30 декабря» resolve without a
    4-digit year in the text itself.
    """
    match = DATE_DMY.search(text)
    if match:
        day, month, year = (int(g) for g in match.groups())
        try:
            return pd.Timestamp(year=year, month=month, day=day)
        except ValueError:
            pass

    match = DATE_YMD_COMPACT.search(text)
    if match:
        year, month, day = (int(g) for g in match.groups())
        try:
            return pd.Timestamp(year=year, month=month, day=day)
        except ValueError:
            pass

    ru = _ru_day_month(text)
    if ru:
        day, month = ru
        year_match = re.search(r"(?<!\d)(20\d{2})(?!\d)", text)
        year = int(year_match.group(1)) if year_match else year_hint
        if year:
            try:
                return pd.Timestamp(year=year, month=month, day=day)
            except ValueError:
                pass
    return None


def folder_month(path: Path, base_dir: Path) -> tuple[int, int] | None:
    """(year, month) from the nearest month-named parent folder, e.g. '12.2025'."""
    try:
        parts = path.relative_to(base_dir).parts[:-1]  # directories only
    except ValueError:
        parts = path.parts[:-1]
    for part in reversed(parts):
        match = FOLDER_MONTH_DMY.match(part)
        if match:
            month, year = int(match.group(1)), int(match.group(2))
            if 1 <= month <= 12:
                return year, month
        match = FOLDER_MONTH_YMD.match(part)
        if match:
            year, month = int(match.group(1)), int(match.group(2))
            if 1 <= month <= 12:
                return year, month
    return None


def resolve_event_date(
    sheet_name: str, file_stem: str, fmonth: tuple[int, int] | None, label: str
) -> tuple[pd.Timestamp | None, str, str]:
    """Returns (event_date, precision, source).

    The folder's month is authoritative; a sheet/file date is accepted only when it
    falls inside that month (it then supplies the day). A date pointing at a
    different month is a stale copied name — reported and ignored, not trusted.
    """
    year_hint = fmonth[0] if fmonth else None
    for source, text in (("sheet_name", sheet_name), ("file_name", file_stem)):
        found = parse_date_from_text(text, year_hint=year_hint)
        if found is None:
            continue
        if fmonth and (found.year, found.month) != fmonth:
            print(
                f"  [INFO] {label}: {source} says {found.date()}, folder says "
                f"{fmonth[1]:02d}.{fmonth[0]} — trusting the folder (stale copied name?)"
            )
            continue
        return found, "day", source
    if fmonth:
        return pd.Timestamp(year=fmonth[0], month=fmonth[1], day=1), "month", "folder"
    return None, "", ""


def find_excel_files(base_dir: Path, years: list[str]) -> list[Path]:
    files: list[Path] = []
    for year in years:
        year_dir = base_dir / year
        if not year_dir.exists():
            print(f"  (skip) {year_dir} not found")
            continue
        found = sorted(p for p in year_dir.rglob("*.xlsx") if not p.name.startswith("~$"))
        print(f"  {year_dir}: {len(found)} .xlsx file(s)")
        files.extend(found)
    return files


def extract_contracts(
    path: Path, header_row: int, contract_col: int, base_dir: Path
) -> pd.DataFrame:
    """One row per contract found in every sheet of `path`."""
    empty = pd.DataFrame(columns=OUT_COLUMNS)
    fmonth = folder_month(path, base_dir)

    try:
        xls = pd.ExcelFile(path)
    except Exception as exc:  # noqa: BLE001 - report and skip, don't kill the whole scan
        print(f"  [ERROR] could not open {path.name}: {exc}")
        return empty

    frames = []
    for sheet_name in xls.sheet_names:
        label = f"{path.name} / '{sheet_name}'"
        event_date, precision, date_source = resolve_event_date(
            sheet_name, path.stem, fmonth, label
        )
        if event_date is None:
            print(
                f"  [WARN] {label}: no date in sheet name, file name or folder path "
                "-- skipped (put the file under a MM.YYYY folder to fix)"
            )
            continue
        try:
            df = xls.parse(sheet_name, header=header_row, dtype=str)
        except Exception as exc:  # noqa: BLE001
            print(f"  [WARN] could not read sheet '{sheet_name}' in {path.name}: {exc}")
            continue
        if df.shape[1] <= contract_col:
            print(
                f"  [WARN] {label} has only {df.shape[1]} column(s), expected "
                f"> {contract_col} -- skipped"
            )
            continue
        contracts = df.iloc[:, contract_col].dropna().astype(str).str.strip()
        contracts = contracts[contracts != ""]
        if contracts.empty:
            print(f"  [WARN] {label}: column {contract_col} is empty -- 0 rows")
            continue
        frames.append(
            pd.DataFrame(
                {
                    "contract_number": contracts.values,
                    "event_date": event_date,
                    "date_precision": precision,
                    "date_source": date_source,
                    "source_file": path.name,
                    "source_sheet": sheet_name,
                }
            )
        )

    return pd.concat(frames, ignore_index=True) if frames else empty


def run_scan(
    base_dir: Path = DEFAULT_BASE_DIR,
    years: list[str] = DEFAULT_YEARS,
    header_row: int = DEFAULT_HEADER_ROW,
    contract_col: int = DEFAULT_CONTRACT_COL,
    out: Path | None = DEFAULT_OUT,
) -> pd.DataFrame:
    """Run the scan and (if `out` is given) write the consolidated CSV. Callable
    directly from a notebook cell with plain Python args -- no argparse involved:

        from writeoff_restoration_scan import run_scan
        df = run_scan(years=["2025", "2026"])
    """
    base_dir = Path(base_dir)
    print(f"Scanning {base_dir} for years {years} ...")
    files = find_excel_files(base_dir, years)
    print(f"\nFound {len(files)} .xlsx file(s) total.\n")

    all_rows, barren = [], []
    for f in files:
        rel = f.relative_to(base_dir)
        extracted = extract_contracts(f, header_row, contract_col, base_dir)
        print(f"{rel}  ->  {len(extracted)} contract row(s)")
        if extracted.empty:
            barren.append(str(rel))
        else:
            all_rows.append(extracted)  # never concat the empties: they are object-dtype
                                        # and would drag event_date off datetime64

    result = (
        pd.concat(all_rows, ignore_index=True)
        if all_rows
        else pd.DataFrame(columns=OUT_COLUMNS)
    )
    result = result.drop_duplicates()
    # Belt and braces: guarantee the dtype regardless of how the frames merged.
    result["event_date"] = pd.to_datetime(result["event_date"], errors="coerce")

    if out is not None:
        out = Path(out)
        out.parent.mkdir(parents=True, exist_ok=True)
        result.to_csv(out, index=False, encoding="utf-8-sig")
        print(
            f"\nWrote {len(result)} row(s), "
            f"{result['contract_number'].nunique()} distinct contract(s) to {out}"
        )

    if barren:
        print(f"\n{len(barren)} file(s) produced NO rows -- check these before trusting coverage:")
        for name in barren:
            print("   ", name)

    if not result.empty:
        print("\nRows by month (event_date):")
        by_month = (
            result.assign(month=result["event_date"].dt.to_period("M"))
            .groupby("month")
            .agg(rows=("contract_number", "size"), contracts=("contract_number", "nunique"))
        )
        print(by_month.to_string())

        print("\nHow the dates were resolved:")
        print(
            result.groupby(["date_source", "date_precision"])
            .size()
            .rename("rows")
            .to_string()
        )

    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-dir", type=Path, default=DEFAULT_BASE_DIR)
    parser.add_argument("--years", nargs="+", default=DEFAULT_YEARS)
    parser.add_argument("--header-row", type=int, default=DEFAULT_HEADER_ROW)
    parser.add_argument("--contract-col", type=int, default=DEFAULT_CONTRACT_COL)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    # parse_known_args, not parse_args: running this via `%run` in Jupyter leaks
    # ipykernel's own launch args (e.g. --f=...kernel-....json) into sys.argv --
    # parse_args() would hard-crash on those; unknown args are just ignored here.
    args, unknown = parser.parse_known_args()
    if unknown:
        print(f"(ignoring unrecognized args, likely from the Jupyter kernel launch: {unknown})")

    run_scan(args.base_dir, args.years, args.header_row, args.contract_col, args.out)


if __name__ == "__main__":
    main()

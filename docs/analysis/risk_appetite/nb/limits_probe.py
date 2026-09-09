# -*- coding: utf-8 -*-
"""
Разведочный аудит папки с документами об уровнях риск-аппетита.

Задача одна: узнать, ЧТО лежит в папке и где внутри файлов встречаются уровни,
не решая за автора, какой уровень когда действовал. Никаких выводов о ряде
лимитов скрипт не делает — он даёт список кандидатов для ручной сверки.

§ 2: собранные данные в репозиторий не коммитятся. Скрипт пишет CSV рядом
с собой (или в --out), эти CSV остаются на машине автора.

Запуск:
  python limits_probe.py "C:\\project_mz\\limits"
  python limits_probe.py "C:\\project_mz\\limits" --out "c:\\project_mz\\limits_probe" --snippet 160

Зависимости: openpyxl (xlsx), pypdf (pdf). .docx читается через zipfile,
без python-docx. Чего нет — файл помечается в инвентаре и пропускается.
"""

import argparse
import csv
import os
import re
import sys
import zipfile
from datetime import datetime

TOKENS = [
    ("лимит",        r"лимит"),
    ("уровень_РА",   r"уров\w*\s+риск[-\s]?аппетит|риск[-\s]?аппетит\w*"),
    ("сигнал",       r"сигнальн|индикатор\w*\s+ранн|early\s+warning"),
    ("порог",        r"порог|толерантн|tolerance|trigger"),
    ("топ20",        r"топ[-\s]?20|крупнейш\w+\s+заемщ|концентрац"),
    ("cor",          r"\bcor\b|стоимост\w*\s+риска|cost\s+of\s+risk"),
    ("pd_el",        r"\bpd\b|\bel\b|ожидаем\w*\s+потер|вероятност\w*\s+дефолт"),
    ("npl",          r"\bnpl\b|неработающ|просроч\w*\s+свыше"),
    ("протокол",     r"проток\w*\s*№|решени\w*\s+(правлени|совета|уо\b)|утвержд"),
    ("редакция",     r"редакц|введен\w*\s+в\s+действие|вступа\w*\s+в\s+силу"),
]
TOKENS = [(name, re.compile(rx, re.I)) for name, rx in TOKENS]

PCT_RE = re.compile(r"(?<![\d.,])(\d{1,3}(?:[.,]\d{1,3})?)\s*%")
DATE_RE = re.compile(r"\b(\d{1,2})[.\-/](\d{1,2})[.\-/](20\d{2})\b")
WS_RE = re.compile(r"[\s\u00a0]+")

TEXT_EXT = {".txt", ".md", ".csv", ".json", ".xml", ".htm", ".html"}
XL_EXT = {".xlsx", ".xlsm", ".xltx"}


def norm(s):
    return WS_RE.sub(" ", str(s)).strip()


def snippet(line, m, width):
    a = max(0, m.start() - width // 3)
    return norm(line[a:a + width])


def scan_line(rel, loc, line, hits, width):
    """Одна строка текста -> ноль или больше строк в hits."""
    if not line:
        return
    s = norm(line)
    if len(s) < 3:
        return
    for name, rx in TOKENS:
        m = rx.search(s)
        if not m:
            continue
        pcts = ";".join(PCT_RE.findall(s)[:6])
        dates = ";".join(".".join(g) for g in DATE_RE.findall(s)[:4])
        hits.append({
            "rel": rel, "loc": loc, "token": name,
            "pct": pcts, "dates": dates, "snippet": snippet(s, m, width),
        })
        break  # одна строка — одно попадание, иначе CSV раздувается


# ---------- читатели по типам ----------

def read_xlsx(path, rel, hits, width, max_rows, max_cols):
    from openpyxl import load_workbook
    wb = load_workbook(path, read_only=True, data_only=True)
    sheets = []
    try:
        for ws in wb.worksheets:
            sheets.append(ws.title)
            for r, row in enumerate(ws.iter_rows(max_row=max_rows, max_col=max_cols,
                                                 values_only=True), start=1):
                cells = [norm(v) for v in row if v is not None and norm(v)]
                if not cells:
                    continue
                scan_line(rel, "%s!r%d" % (ws.title, r), " | ".join(cells), hits, width)
    finally:
        wb.close()
    return "sheets=%d" % len(sheets), ";".join(sheets[:12])


def read_docx(path, rel, hits, width):
    """Без python-docx: текст абзацев и ячеек из word/document.xml."""
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist()
                 if n == "word/document.xml" or n.startswith("word/header")
                 or n.startswith("word/footer")]
        paras = 0
        for n in names:
            xml = z.read(n).decode("utf-8", "replace")
            # абзац = <w:p ...> ... </w:p>; текст = содержимое <w:t>
            for p in re.findall(r"<w:p[ >].*?</w:p>", xml, re.S):
                txt = "".join(re.findall(r"<w:t[^>]*>(.*?)</w:t>", p, re.S))
                if not txt:
                    continue
                paras += 1
                txt = (txt.replace("&amp;", "&").replace("&lt;", "<")
                          .replace("&gt;", ">").replace("&quot;", '"'))
                scan_line(rel, "%s p%d" % (n.split("/")[-1], paras), txt, hits, width)
    return "paras=%d" % paras, ""


def read_pdf(path, rel, hits, width, max_pages):
    from pypdf import PdfReader
    rd = PdfReader(path)
    n = len(rd.pages)
    for i, pg in enumerate(rd.pages[:max_pages], start=1):
        try:
            txt = pg.extract_text() or ""
        except Exception:
            continue
        for line in txt.splitlines():
            scan_line(rel, "p%d" % i, line, hits, width)
    return "pages=%d" % n, ""


def read_text(path, rel, hits, width):
    with open(path, "rb") as f:
        raw = f.read(4 * 1024 * 1024)
    for enc in ("utf-8", "cp1251"):
        try:
            txt = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:
        return "decode_failed", ""
    lines = txt.splitlines()
    for i, line in enumerate(lines, start=1):
        scan_line(rel, "l%d" % i, line, hits, width)
    return "lines=%d" % len(lines), ""


# ---------- обход ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--out", default=None, help="куда положить CSV (по умолчанию <root>\\_probe)")
    ap.add_argument("--snippet", type=int, default=140)
    ap.add_argument("--max-mb", type=float, default=40.0)
    ap.add_argument("--max-rows", type=int, default=400)
    ap.add_argument("--max-cols", type=int, default=25)
    ap.add_argument("--max-pages", type=int, default=60)
    a = ap.parse_args()

    root = os.path.abspath(a.root)
    if not os.path.isdir(root):
        sys.exit("нет такой папки: %s" % root)
    out = os.path.abspath(a.out) if a.out else os.path.join(root, "_probe")
    os.makedirs(out, exist_ok=True)

    inv, hits = [], []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "_probe" and not d.startswith("~")]
        for fn in sorted(filenames):
            if fn.startswith("~$") or fn.startswith("."):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            ext = os.path.splitext(fn)[1].lower()
            try:
                st = os.stat(full)
            except OSError as e:
                inv.append({"rel": rel, "ext": ext, "size": "", "mtime": "",
                            "depth": rel.count(os.sep), "status": "stat:%s" % e.__class__.__name__,
                            "detail": "", "extra": ""})
                continue
            row = {
                "rel": rel, "ext": ext, "size": st.st_size,
                "mtime": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d"),
                "depth": rel.count(os.sep), "status": "", "detail": "", "extra": "",
            }
            if st.st_size > a.max_mb * 1024 * 1024:
                row["status"] = "skip:too_big"
                inv.append(row)
                continue
            n_before = len(hits)
            try:
                if ext in XL_EXT:
                    row["detail"], row["extra"] = read_xlsx(full, rel, hits, a.snippet,
                                                            a.max_rows, a.max_cols)
                elif ext == ".docx":
                    row["detail"], row["extra"] = read_docx(full, rel, hits, a.snippet)
                elif ext == ".pdf":
                    row["detail"], row["extra"] = read_pdf(full, rel, hits, a.snippet,
                                                           a.max_pages)
                elif ext in TEXT_EXT:
                    row["detail"], row["extra"] = read_text(full, rel, hits, a.snippet)
                elif ext in (".doc", ".xls", ".ppt", ".rtf", ".msg"):
                    row["status"] = "skip:legacy_binary"
                else:
                    row["status"] = "skip:ext"
            except ImportError as e:
                row["status"] = "no_lib:%s" % e.name
            except Exception as e:
                row["status"] = "err:%s" % e.__class__.__name__
            if not row["status"]:
                row["status"] = "ok"
            row["extra"] = row["extra"] or ""
            row["detail"] = "%s hits=%d" % (row["detail"], len(hits) - n_before)
            inv.append(row)

    inv_p = os.path.join(out, "limits_inventory.csv")
    hit_p = os.path.join(out, "limits_hits.csv")
    with open(inv_p, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=["rel", "ext", "size", "mtime", "depth",
                                          "status", "detail", "extra"], delimiter=";")
        w.writeheader()
        w.writerows(inv)
    with open(hit_p, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=["rel", "loc", "token", "pct", "dates", "snippet"],
                           delimiter=";")
        w.writeheader()
        w.writerows(hits)

    # ---- сводка в консоль ----
    print("корень : %s" % root)
    print("файлов : %d, попаданий: %d" % (len(inv), len(hits)))
    print("вывод  : %s" % out)

    def tally(rows, key):
        d = {}
        for r in rows:
            d[r[key]] = d.get(r[key], 0) + 1
        return sorted(d.items(), key=lambda kv: -kv[1])

    print("\n-- по расширениям --")
    for k, v in tally(inv, "ext"):
        print("  %-8s %4d" % (k or "(нет)", v))

    print("\n-- статусы --")
    for k, v in tally(inv, "status"):
        print("  %-22s %4d" % (k, v))

    print("\n-- папки верхнего уровня --")
    top = {}
    for r in inv:
        seg = r["rel"].split(os.sep)[0] if os.sep in r["rel"] else "(корень)"
        top[seg] = top.get(seg, 0) + 1
    for k, v in sorted(top.items(), key=lambda kv: -kv[1])[:25]:
        print("  %-45s %4d" % (k[:45], v))

    print("\n-- по токенам --")
    for k, v in tally(hits, "token"):
        print("  %-12s %5d" % (k, v))

    print("\n-- 25 файлов с наибольшим числом попаданий --")
    per = {}
    for h in hits:
        per[h["rel"]] = per.get(h["rel"], 0) + 1
    for k, v in sorted(per.items(), key=lambda kv: -kv[1])[:25]:
        print("  %5d  %s" % (v, k[:110]))

    skipped = [r["rel"] for r in inv if r["status"] in ("skip:legacy_binary", "skip:ext")
               or r["status"].startswith(("no_lib", "err", "skip:too_big"))]
    if skipped:
        print("\n-- не прочитано (первые 30): старый бинарный формат, нет библиотеки, ошибка --")
        for r in skipped[:30]:
            print("  %s" % r[:110])
        if len(skipped) > 30:
            print("  ... ещё %d" % (len(skipped) - 30))

    print("\n-- попадания с процентом И датой в одной строке (первые 40) --")
    both = [h for h in hits if h["pct"] and h["dates"]]
    print("  всего таких строк: %d" % len(both))
    for h in both[:40]:
        print("  [%s] %s | %s | %s | %s" % (h["token"], h["rel"][:40], h["loc"][:20],
                                            h["pct"][:20], h["snippet"][:90]))


if __name__ == "__main__":
    main()

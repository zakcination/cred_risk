"""Text extraction from PDF / DOCX / XLSX / TXT documents.

Dependency policy
-----------------
* ``.docx`` and ``.xlsx`` are OpenXML zip archives and are parsed with the
  standard library only (``zipfile`` + ``xml.etree``), so no third-party
  package is required for Office files.
* ``.pdf`` extraction uses PyMuPDF (``pymupdf``/``fitz``) if it is installed;
  otherwise a clear error explains how to install it.

All extractors return plain ``str``.
"""

from __future__ import annotations

import re
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

_W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
_S = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def extract_txt(path: str | Path) -> str:
    return Path(path).read_text(encoding="utf-8", errors="replace")


def extract_docx(path: str | Path) -> str:
    """Extract paragraph text (including tables) from a .docx file."""
    with zipfile.ZipFile(path) as z:
        root = ET.fromstring(z.read("word/document.xml"))
    lines = []
    for para in root.iter(_W + "p"):
        text = "".join(t.text or "" for t in para.iter(_W + "t"))
        lines.append(text)
    return "\n".join(lines)


def _col_to_index(ref: str) -> int:
    m = re.match(r"([A-Z]+)\d+", ref)
    if not m:
        return 0
    col = 0
    for ch in m.group(1):
        col = col * 26 + (ord(ch) - 64)
    return col - 1


def extract_xlsx(path: str | Path) -> str:
    """Extract cell text from every worksheet of a .xlsx file.

    Numeric cells are included as their raw string value so that numbers do not
    interfere with term matching but headers/labels remain searchable.
    """
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        shared: list[str] = []
        if "xl/sharedStrings.xml" in names:
            sst = ET.fromstring(z.read("xl/sharedStrings.xml"))
            for si in sst.iter(_S + "si"):
                shared.append("".join(t.text or "" for t in si.iter(_S + "t")))

        out_lines: list[str] = []
        sheet_files = sorted(
            n for n in names if re.match(r"xl/worksheets/sheet\d+\.xml", n)
        )
        for sf in sheet_files:
            sheet = ET.fromstring(z.read(sf))
            for row in sheet.iter(_S + "row"):
                cells = []
                for c in row.iter(_S + "c"):
                    ctype = c.get("t")
                    v = c.find(_S + "v")
                    is_el = c.find(_S + "is")
                    if ctype == "s" and v is not None:
                        cells.append(shared[int(v.text)])
                    elif is_el is not None:
                        cells.append("".join(x.text or "" for x in is_el.iter(_S + "t")))
                    elif v is not None:
                        cells.append(v.text or "")
                line = " ".join(cells).strip()
                if line:
                    out_lines.append(line)
        return "\n".join(out_lines)


def extract_pdf(path: str | Path) -> str:
    try:
        import fitz  # PyMuPDF
    except ImportError as exc:  # pragma: no cover - environment dependent
        raise RuntimeError(
            "PDF extraction requires PyMuPDF. Install it with: pip install pymupdf"
        ) from exc
    doc = fitz.open(str(path))
    return "\n".join(page.get_text() for page in doc)


_EXTRACTORS = {
    ".txt": extract_txt,
    ".md": extract_txt,
    ".docx": extract_docx,
    ".xlsx": extract_xlsx,
    ".pdf": extract_pdf,
}

SUPPORTED_EXTENSIONS = tuple(_EXTRACTORS)


def extract_text(path: str | Path) -> str:
    """Dispatch to the right extractor based on file extension."""
    path = Path(path)
    ext = path.suffix.lower()
    extractor = _EXTRACTORS.get(ext)
    if extractor is None:
        raise ValueError(
            f"Unsupported file type '{ext}'. Supported: {', '.join(SUPPORTED_EXTENSIONS)}"
        )
    return extractor(path)

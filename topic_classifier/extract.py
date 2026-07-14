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


def extract_msg(path: str | Path) -> str:
    """Extract subject, recipients and body text from an Outlook .msg file.

    A .msg is an OLE2 compound file. We read the well-known MAPI property
    streams (subject, sender, recipients, body) with ``olefile`` — pure Python,
    no build step. The body is stored either as plain text (property 1000) or as
    RTF-compressed HTML (property 1009); we use the plain text when present and
    fall back to a tag-stripped decompressed RTF otherwise. Attachment file
    names are included so that "email forwarding report X" is searchable.
    """
    try:
        import olefile
    except ImportError as exc:  # pragma: no cover - environment dependent
        raise RuntimeError(
            "MSG extraction requires olefile. Install it with: pip install olefile"
        ) from exc

    ole = olefile.OleFileIO(str(path))
    streams = ole.listdir()

    def _read(prefix: str, root: str | None = None) -> str:
        # depth: message-root properties are single-element paths; sub-storage
        # properties (__nameid, __attach, __recip) are nested. Select the right
        # level so we don't read a same-named stream from the wrong storage.
        depth = 2 if root is not None else 1
        for s in streams:
            if len(s) != depth:
                continue
            if root is not None and s[0] != root:
                continue
            name = s[-1]
            if name.startswith("__substg1.0_") and prefix in name:
                data = ole.openstream(s).read()
                if name.endswith(("001F", "001E", "0102")):
                    try:
                        return data.decode("utf-16-le", "replace")
                    except Exception:
                        return data.decode("cp1251", "replace")
                return data.decode("utf-8", "replace")
        return ""

    parts = [
        _read("0037"),  # subject
        _read("0C1A"),  # sender name
        _read("0E04"),  # display to
        _read("3003"),  # recipient email (best effort)
    ]

    # The plain-text body (PR_BODY, 1000) is sometimes empty or a few junk bytes,
    # with the real content only in the compressed RTF/HTML body (1009). Take
    # whichever yields more actual text rather than trusting 1000 blindly.
    plain = _read("1000")
    rtf = _decompress_rtf_body(ole, streams)
    body = plain if len(plain.strip()) >= len(rtf.strip()) else rtf
    parts.append(body)

    # attachment long file names (property 3707)
    for s in streams:
        if s[0].startswith("__attach") and s[-1].startswith("__substg1.0_3707"):
            parts.append(ole.openstream(s).read().decode("utf-16-le", "replace"))

    return "\n".join(p for p in parts if p and p.strip())


def _decompress_rtf_body(ole, streams) -> str:
    """Best-effort plain text from the compressed-RTF body stream (1009)."""
    raw = None
    for s in streams:
        # root-level compressed-RTF body only (not the __nameid_version1.0 copy)
        if len(s) == 1 and s[-1].startswith("__substg1.0_1009"):
            raw = ole.openstream(s).read()
            break
    if raw is None:
        return ""
    try:
        from compressed_rtf import decompress
        rtf = decompress(raw).decode("latin1", "replace")
    except Exception:
        return ""
    # decode \'hh (cp1251) and \uNNNN, drop control words/groups and HTML tags
    rtf = re.sub(r"\\'([0-9a-fA-F]{2})",
                 lambda m: bytes([int(m.group(1), 16)]).decode("cp1251", "replace"), rtf)
    rtf = re.sub(r"\\u(-?\d+)\??", lambda m: chr(int(m.group(1)) % 65536), rtf)
    rtf = re.sub(r"\\par|\\line", "\n", rtf)
    rtf = re.sub(r"\\[a-zA-Z]+-?\d* ?", "", rtf).replace("{", "").replace("}", "")
    # drop encapsulated HTML head/style/script/comments (CSS noise) before tags
    rtf = re.sub(r"(?is)<(style|script|head)[^>]*>.*?</\1>", " ", rtf)
    rtf = re.sub(r"(?s)<!--.*?-->", " ", rtf)
    rtf = re.sub(r"<[^>]+>", " ", rtf)          # strip remaining HTML tags
    rtf = re.sub(r"&nbsp;|&[a-z]+;", " ", rtf)  # HTML entities
    rtf = re.sub(r"[ \t]+", " ", rtf)
    return re.sub(r"\n\s*\n+", "\n", rtf).strip()


_EXTRACTORS = {
    ".txt": extract_txt,
    ".md": extract_txt,
    ".docx": extract_docx,
    ".xlsx": extract_xlsx,
    ".pdf": extract_pdf,
    ".msg": extract_msg,
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

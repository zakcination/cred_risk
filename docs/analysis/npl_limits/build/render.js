// Рендер JSON-блоков -> Word (docx-js). Содержательная часть собирается
// в Python (make_docs.py); здесь только оформление.
// Запуск: node render.js <in.json> <out.docx>
const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  Table, TableRow, TableCell, WidthType, ShadingType, BorderStyle,
  PageBreak, LevelFormat, convertMillimetersToTwip,
} = require('docx');

const IN = path.resolve(process.argv[2]);
const OUT = path.resolve(process.argv[3]);
const BLOCKS = JSON.parse(fs.readFileSync(IN, 'utf8'));

const FONT = 'Times New Roman';
const MONO = 'Courier New';
const INK = '16202B', MUTED = '5B6B7A', ACC = '1C5B57', WARN = 'A8492F';
const RULE = 'C8D2DA', TINT = 'EEF3F5', CODE_BG = 'F5F7F9';

// A4 минус поля по 20 мм
const MARGIN = convertMillimetersToTwip(20);
const USABLE = 11906 - MARGIN * 2;

function runs(text, opts = {}) {
  const out = [];
  const re = /\*\*(.+?)\*\*/g;
  let last = 0, m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) out.push(new TextRun({ text: text.slice(last, m.index), ...opts }));
    out.push(new TextRun({ text: m[1], bold: true, ...opts }));
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(new TextRun({ text: text.slice(last), ...opts }));
  return out.length ? out : [new TextRun({ text: '', ...opts })];
}

const thin = { style: BorderStyle.SINGLE, size: 4, color: RULE };
const cellBorders = { top: thin, bottom: thin, left: thin, right: thin };

function cell(text, { width, header = false, first = false }) {
  return new TableCell({
    width: { size: width, type: WidthType.DXA },
    borders: cellBorders,
    shading: header ? { type: ShadingType.CLEAR, fill: TINT, color: 'auto' } : undefined,
    margins: { top: 70, bottom: 70, left: 110, right: 110 },
    children: [new Paragraph({
      spacing: { before: 0, after: 0 },
      children: runs(text, {
        font: FONT, size: header ? 17 : 19,
        bold: header || first, color: header ? MUTED : INK,
        allCaps: header,
      }),
    })],
  });
}

function widths(n) {
  if (n === 2) { const a = Math.round(USABLE * 0.62); return [a, USABLE - a]; }
  if (n === 3) {
    const a = Math.round(USABLE * 0.22), b = Math.round(USABLE * 0.46);
    return [a, b, USABLE - a - b];
  }
  if (n === 4) {
    const a = Math.round(USABLE * 0.34), c = Math.round(USABLE * 0.14);
    return [a, USABLE - a - c - c, c, c];
  }
  // 5+ колонок: первая узкая, вторая широкая, остальные поровну
  const a = Math.round(USABLE * 0.06), b = Math.round(USABLE * 0.24);
  const rest = Math.floor((USABLE - a - b) / (n - 2));
  const w = [a, b];
  for (let k = 2; k < n; k++) w.push(rest);
  w[n - 1] = USABLE - w.slice(0, -1).reduce((s, x) => s + x, 0);
  return w;
}

function table(b) {
  const w = widths(b.head.length);
  const rows = [new TableRow({
    tableHeader: true,
    children: b.head.map((h, k) => cell(h, { width: w[k], header: true })),
  })];
  for (const r of b.rows) {
    rows.push(new TableRow({
      children: r.map((c, k) => cell(c, { width: w[k], first: k === 0 })),
    }));
  }
  return new Table({ columnWidths: w, width: { size: USABLE, type: WidthType.DXA }, rows });
}

function note(b) {
  const warn = b.kind === 'ПРЕДПОЛОЖЕНО' || b.kind === 'ДЕДЛАЙН';
  const color = warn ? WARN : ACC;
  return new Table({
    columnWidths: [USABLE],
    width: { size: USABLE, type: WidthType.DXA },
    rows: [new TableRow({
      children: [new TableCell({
        width: { size: USABLE, type: WidthType.DXA },
        borders: {
          top: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' },
          bottom: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' },
          right: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' },
          left: { style: BorderStyle.SINGLE, size: 18, color },
        },
        shading: { type: ShadingType.CLEAR, fill: warn ? 'FBF3F0' : 'F2F7F6', color: 'auto' },
        margins: { top: 120, bottom: 120, left: 180, right: 160 },
        children: [
          new Paragraph({
            spacing: { after: 60 },
            children: [new TextRun({ text: b.kind, font: FONT, size: 15,
                                     bold: true, color, characterSpacing: 24 })],
          }),
          new Paragraph({ children: runs(b.text, { font: FONT, size: 19, color: INK }) }),
        ],
      })],
    })],
  });
}

function codeBlock(b) {
  return new Table({
    columnWidths: [USABLE],
    width: { size: USABLE, type: WidthType.DXA },
    rows: [new TableRow({
      children: [new TableCell({
        width: { size: USABLE, type: WidthType.DXA },
        borders: cellBorders,
        shading: { type: ShadingType.CLEAR, fill: CODE_BG, color: 'auto' },
        margins: { top: 100, bottom: 100, left: 160, right: 160 },
        children: b.lines.map((ln) => new Paragraph({
          spacing: { before: 0, after: 30 },
          children: [new TextRun({ text: ln, font: MONO, size: 17, color: INK })],
        })),
      })],
    })],
  });
}

const children = [];
for (const b of BLOCKS) {
  switch (b.t) {
    case 'title':
      children.push(new Paragraph({
        spacing: { before: 1800, after: 120 },
        children: [new TextRun({ text: b.text, font: FONT, size: 40, bold: true, color: INK })],
      }));
      break;
    case 'subtitle':
      children.push(new Paragraph({
        spacing: { after: 80 },
        children: [new TextRun({ text: b.text, font: FONT, size: 25, color: MUTED })],
      }));
      break;
    case 'titlemeta':
      children.push(new Paragraph({
        spacing: { after: 200 },
        children: [new TextRun({ text: b.text, font: FONT, size: 18, color: MUTED })],
      }));
      break;
    case 'h1':
      children.push(new Paragraph({
        heading: HeadingLevel.HEADING_1,
        spacing: { before: 360, after: 160 },
        border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: INK, space: 6 } },
        children: [new TextRun({ text: b.text, font: FONT, size: 28, bold: true, color: INK })],
      }));
      break;
    case 'h2':
      children.push(new Paragraph({
        heading: HeadingLevel.HEADING_2, spacing: { before: 280, after: 110 },
        children: [new TextRun({ text: b.text, font: FONT, size: 23, bold: true, color: INK })],
      }));
      break;
    case 'p':
      children.push(new Paragraph({
        spacing: { after: 140, line: 300 }, alignment: AlignmentType.JUSTIFIED,
        children: runs(b.text, { font: FONT, size: 21, color: INK }),
      }));
      break;
    case 'lead':
      children.push(new Paragraph({
        spacing: { after: 180, line: 300 }, alignment: AlignmentType.JUSTIFIED,
        children: runs(b.text, { font: FONT, size: 22, color: '3C4A56', italics: true }),
      }));
      break;
    case 'bullets':
      for (const it of b.items) {
        children.push(new Paragraph({
          numbering: { reference: 'dot', level: 0 },
          spacing: { after: 110, line: 290 }, alignment: AlignmentType.JUSTIFIED,
          children: runs(it, { font: FONT, size: 21, color: INK }),
        }));
      }
      break;
    case 'table':
      children.push(table(b));
      children.push(new Paragraph({
        spacing: { before: 80, after: 220 },
        children: [new TextRun({ text: b.src, font: FONT, size: 16, italics: true, color: MUTED })],
      }));
      break;
    case 'note':
      children.push(note(b));
      children.push(new Paragraph({ spacing: { after: 180 }, children: [] }));
      break;
    case 'code':
      children.push(codeBlock(b));
      children.push(new Paragraph({ spacing: { after: 160 }, children: [] }));
      break;
    case 'pagebreak':
      children.push(new Paragraph({ children: [new PageBreak()] }));
      break;
  }
}

const doc = new Document({
  numbering: {
    config: [{
      reference: 'dot',
      levels: [{
        level: 0, format: LevelFormat.BULLET, text: '—',
        alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 400, hanging: 220 } } },
      }],
    }],
  },
  sections: [{
    properties: { page: { margin: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN } } },
    children,
  }],
});

Packer.toBuffer(doc).then((buf) => {
  fs.writeFileSync(OUT, buf);
  console.log(`написан ${OUT}  (${(buf.length / 1024).toFixed(0)} КБ)`);
});

const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  Table, TableRow, TableCell, WidthType, ShadingType, BorderStyle,
  PageBreak, Footer, PageNumber, convertMillimetersToTwip,
} = require("docx");

const FONT = "Times New Roman";
const USABLE = 9354;              // A4 при полях 25/20 мм
const GREY = "EDEDED";
const LINE = "BFBFBF";

const P = (text, o = {}) => new Paragraph({
  alignment: o.align || AlignmentType.JUSTIFIED,
  spacing: { after: o.after == null ? 120 : o.after, line: 276 },
  indent: o.indent,
  children: (Array.isArray(text) ? text : [{ t: text }]).map(r =>
    new TextRun({
      text: r.t, bold: r.b, italics: r.i, font: FONT,
      size: o.size || 22, color: r.c,
    })),
});

const H = (text, lvl, o = {}) => new Paragraph({
  heading: lvl,
  spacing: { before: o.before == null ? 280 : o.before, after: 140 },
  children: [new TextRun({ text, bold: true, font: FONT, size: lvl === HeadingLevel.HEADING_1 ? 28 : 24 })],
});

const H1 = (t, o) => H(t, HeadingLevel.HEADING_1, o);
const H2 = (t, o) => H(t, HeadingLevel.HEADING_2, o);

const LI = (text, o = {}) => new Paragraph({
  bullet: { level: o.level || 0 },
  spacing: { after: 80, line: 276 },
  children: (Array.isArray(text) ? text : [{ t: text }]).map(r =>
    new TextRun({ text: r.t, bold: r.b, italics: r.i, font: FONT, size: 22 })),
});

// Заметка врезкой: рамка слева, отступ
const NOTE = (text, o = {}) => new Paragraph({
  spacing: { before: 140, after: 160, line: 276 },
  indent: { left: 280 },
  border: { left: { style: BorderStyle.SINGLE, size: 12, color: "808080", space: 10 } },
  children: (Array.isArray(text) ? text : [{ t: text }]).map(r =>
    new TextRun({ text: r.t, bold: r.b, italics: r.i, font: FONT, size: 21 })),
});

function cell(text, w, o = {}) {
  const runs = (Array.isArray(text) ? text : [{ t: String(text) }])
    .map(r => new TextRun({ text: r.t, bold: r.b || o.bold, font: FONT, size: o.size || 19 }));
  return new TableCell({
    width: { size: w, type: WidthType.DXA },
    shading: o.head ? { type: ShadingType.CLEAR, fill: GREY, color: "auto" } : undefined,
    margins: { top: 60, bottom: 60, left: 90, right: 90 },
    children: [new Paragraph({
      alignment: o.align || AlignmentType.LEFT,
      spacing: { after: 0, line: 240 },
      children: runs,
    })],
  });
}

// headers: [строка]; rows: [[...]]; widths: доли, сумма 1
function TBL(headers, rows, widths, opt = {}) {
  const w = widths.map(x => Math.round(USABLE * x));
  w[w.length - 1] = USABLE - w.slice(0, -1).reduce((a, b) => a + b, 0);
  const aligns = opt.aligns || [];
  const b = { style: BorderStyle.SINGLE, size: 4, color: LINE };
  return new Table({
    columnWidths: w,
    width: { size: USABLE, type: WidthType.DXA },
    borders: { top: b, bottom: b, left: b, right: b, insideHorizontal: b, insideVertical: b },
    rows: [
      new TableRow({
        tableHeader: true,
        children: headers.map((h, i) => cell(h, w[i], { head: true, bold: true, align: aligns[i] })),
      }),
      ...rows.map(r => new TableRow({
        children: r.map((c, i) => cell(c, w[i], { align: aligns[i] })),
      })),
    ],
  });
}

const CAP = t => new Paragraph({
  spacing: { before: 80, after: 220 },
  children: [new TextRun({ text: t, font: FONT, size: 18, italics: true, color: "595959" })],
});

const BREAK = () => new Paragraph({ children: [new PageBreak()] });

function titleBlock(title, sub, meta) {
  return [
    new Paragraph({
      spacing: { before: 600, after: 60 },
      children: [new TextRun({ text: title, bold: true, font: FONT, size: 40 })],
    }),
    new Paragraph({
      spacing: { after: 240 },
      border: { bottom: { style: BorderStyle.SINGLE, size: 8, color: "808080", space: 8 } },
      children: [new TextRun({ text: sub, font: FONT, size: 26, color: "404040" })],
    }),
    ...meta.map(m => new Paragraph({
      spacing: { after: 60 },
      children: [new TextRun({ text: m, font: FONT, size: 20, color: "404040" })],
    })),
    new Paragraph({ spacing: { after: 240 }, children: [] }),
  ];
}

function makeDoc(children) {
  return new Document({
    styles: { default: { document: { run: { font: FONT, size: 22 } } } },
    sections: [{
      properties: {
        page: {
          margin: {
            top: convertMillimetersToTwip(20), bottom: convertMillimetersToTwip(20),
            left: convertMillimetersToTwip(25), right: convertMillimetersToTwip(20),
          },
        },
      },
      footers: {
        default: new Footer({
          children: [new Paragraph({
            alignment: AlignmentType.CENTER,
            children: [new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: 18, color: "808080" })],
          })],
        }),
      },
      children,
    }],
  });
}

module.exports = { P, H1, H2, LI, NOTE, TBL, CAP, BREAK, titleBlock, makeDoc, Packer, AlignmentType };

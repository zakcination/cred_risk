// Готовит deck_ra_data.js из ряда контура. Запускать перед deck_ra_top20.js.
const fs = require("fs"), path = require("path");
const csv = fs.readFileSync(path.join(__dirname, "..", "data",
  "top20_monthly_2023_08_2026_07.csv"), "utf8").trim().split("\n");
const head = csv[0].split(";"), rows = csv.slice(1).map(l => {
  const v = l.split(";"), o = {}; head.forEach((h, i) => o[h] = v[i]); return o; });
const n = x => x === "" || x === undefined ? null : Number(x);
const r2 = x => x === null ? null : Math.round(x * 100) / 100;
const D = {
  labels: rows.map(r => ["01","04","07","10"].includes(r.date.slice(5,7))
    ? r.date.slice(5,7) + "." + r.date.slice(2,4) : ""),
  full:  rows.map(r => r.date.slice(0, 7)),
  old:   rows.map(r => r2(n(r.coef_old) === null ? null : n(r.coef_old) * 100)),
  new:   rows.map(r => r2(n(r.coef_new) * 100)),
  skold: rows.map(r => r2(n(r.sk_old_mln) === null ? null : n(r.sk_old_mln) / 1000)),
  sknew: rows.map(r => r2(n(r.sk_new_mln) / 1000)),
  zaim:  rows.map(r => r2(n(r.zaim_mln) / 1000)),
};

// Квартальные средние, месячные приращения и средние по окнам — для слайдов «простого взгляда».
const mean = a => a.reduce((s, x) => s + x, 0) / a.length;
const qs = {};
D.full.forEach((d, i) => {
  const k = d.slice(0, 4) + "Q" + (Math.floor((Number(d.slice(5, 7)) - 1) / 3) + 1);
  (qs[k] = qs[k] || []).push(D.new[i]);
});
const qk = Object.keys(qs).sort();
D.qlab = qk.map(k => k.slice(2).replace("Q", " кв."));
D.qval = qk.map(k => r2(mean(qs[k])));
D.dval = D.new.slice(1).map((v, i) => r2(v - D.new[i]));
D.dlab = D.labels.slice(1);
D.avgLab = ["36 мес.", "24 мес.", "12 мес.", "6 мес.", "3 мес.", "последняя"];
D.avgVal = [36, 24, 12, 6, 3].map(w => r2(mean(D.new.slice(-w)))).concat([D.new[D.new.length - 1]]);

if (require.main === module) {
  fs.writeFileSync(path.join(__dirname, "deck_ra_data.js"),
    "module.exports = " + JSON.stringify(D) + ";\n");
  console.log("точек:", D.full.length, "| последняя:", D.full[D.full.length - 1], D.new[D.new.length - 1]);
}
module.exports = D;

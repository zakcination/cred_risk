// Сборка презентации по уровню и зонам топ-20 (docs/analysis/risk_appetite).
// Запуск:  node deck_ra_data.js && node deck_ra_top20.js
// Обложка cover_bg.png — декоративная, без единой цифры; в репозиторий не коммитится.
// Все графики нативные: правятся в PowerPoint без пересборки.
const pptxgen = require("pptxgenjs");
// Ряд берётся из data/top20_monthly_2023_08_2026_07.csv — см. заголовок ниже.
const D = require("./deck_ra_data.js");

const NAVY="1E2761", ICE="CADCFC", INK="1F2933", MUTED="5A6478", LINE="D8DEE9", BG="FFFFFF";
const C1="2E6FA8", C2="C97B1E";
const GREEN="2E7D4F", AMBER="D18F00", RED="B3261E";
const HF="Cambria", BF="Calibri";

const p = new pptxgen();
p.layout = "LAYOUT_WIDE";           // 13.3 x 7.5
p.author = "БРМ"; p.company = "АО «Евразийский банк»";

const W = 13.3, H = 7.5, M = 0.6;

function title(s, t, sub){
  s.addText(t, {x:M, y:0.42, w:W-2*M, h:1.12, fontSize:21, bold:true, color:NAVY,
    fontFace:HF, isTextBox:true, margin:0, valign:"top", lineSpacing:25});
  if(sub) s.addText(sub, {x:M, y:1.62, w:W-2*M, h:0.32, fontSize:12.5, color:MUTED,
    fontFace:BF, isTextBox:true, margin:0});
}
function foot(s, txt){
  s.addText(txt, {x:M, y:H-0.52, w:W-2*M, h:0.28, fontSize:9, color:MUTED,
    fontFace:BF, isTextBox:true, margin:0});
}
function card(s, x, y, w, h, fill){
  s.addShape(p.ShapeType.roundRect, {x, y, w, h, rectRadius:0.06, fill:{color:fill||"F4F6FA"},
    line:{color:LINE, width:0.75}, shadow:{type:"outer", angle:90, blur:6, offset:0.03,
    color:"9AA6B8", opacity:0.28}});
}
function num(s, x, y, n){
  s.addShape(p.ShapeType.ellipse, {x, y, w:0.42, h:0.42, fill:{color:NAVY}, line:{color:NAVY}});
  s.addText(String(n), {x, y, w:0.42, h:0.42, fontSize:15, bold:true, color:"FFFFFF",
    align:"center", valign:"middle", fontFace:BF, isTextBox:true, margin:0});
}
const axis = {catAxisLabelColor:MUTED, valAxisLabelColor:MUTED, catAxisLabelFontSize:9,
  valAxisLabelFontSize:9, catAxisLabelFontFace:BF, valAxisLabelFontFace:BF,
  valGridLine:{color:"EAEEF4", size:1}, catGridLine:{style:"none"},
  border:{pt:0, color:"FFFFFF"}, chartArea:{fill:{color:"FFFFFF"}}};

/* ---------- 1. ТИТУЛ ---------- */
let s = p.addSlide(); s.background = {color:NAVY};
s.addImage({path:"cover_bg.png", x:0, y:0, w:W, h:H});
s.addShape(p.ShapeType.rect, {x:0, y:0, w:7.9, h:H, fill:{color:NAVY, transparency:22}, line:{color:NAVY, width:0}});
s.addText("Уровни риск-аппетита\nпо кредитному риску", {x:M, y:1.9, w:8.6, h:1.9,
  fontSize:40, bold:true, color:"FFFFFF", fontFace:HF, isTextBox:true, margin:0, lineSpacing:46});
s.addText("Пересмотр уровня и зонирование: концентрация топ-20 крупных заёмщиков",
  {x:M, y:3.95, w:9.2, h:0.5, fontSize:16, color:ICE, fontFace:BF, isTextBox:true, margin:0});
s.addShape(p.ShapeType.rect, {x:M, y:4.7, w:2.2, h:0.02, fill:{color:ICE}, line:{color:ICE}});
s.addText([
  {text:"Департамент риск-менеджмента  ·  8 сентября 2026", options:{breakLine:true}},
  {text:"Основание: замечание СВА «не обеспечен ежегодный пересмотр уровней риск-аппетита по кредитному риску»", options:{breakLine:true}},
  {text:"Сроки: 30.09.2026 — анализ актуальности  ·  31.12.2026 — предложения на УО"}],
  {x:M, y:5.0, w:9.6, h:1.1, fontSize:12, color:ICE, fontFace:BF, isTextBox:true, margin:0, lineSpacing:19});
s.addText("101,50 %", {x:9.4, y:5.25, w:3.3, h:0.8, fontSize:44, bold:true, color:"FFFFFF",
  fontFace:HF, isTextBox:true, margin:0, align:"right"});
s.addText("факт на 07.2026\nбалансовая база", {x:9.4, y:6.05, w:3.3, h:0.6, fontSize:11,
  color:ICE, fontFace:BF, isTextBox:true, margin:0, align:"right", lineSpacing:15});
s.addNotes("Контур существует по замечанию СВА высокого уровня. Два срока: 30.09 и 31.12.2026.");

/* ---------- 2. РЕЗЮМЕ ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "Метрика сменила определение, уровень — нет. Восстановление уровня\nпод действующую базу даёт 108,63 % — уровень, при котором остаётся квартал");
const sup = [
 ["Проблема","Формально вне уровня\n12 месяцев из 36","При неизменном портфеле. На регуляторной базе — ни разу за 30 месяцев. Причина — смена знаменателя с 01.01.2026, уровень 95 % при этом не пересматривался"],
 ["Решение","Два независимых пути\nдают один уровень","Пересчёт базы: 108,63 %. Требование квартала на реагирование: 108,58 %. Расхождение 0,05 пп — уровень не подобран под факт, его требует цикл решения"],
 ["Результат","Светофор строится:\n11,1 % времени в жёлтом","Три зоны с границами 99,60 и 108,63 %. Цена — 16 отчётов в год вместо 12. Текущая точка попадает в жёлтую, что совпадает с фактическим режимом работы"]];
sup.forEach((c,i)=>{
  const x = M + i*4.08;
  card(s, x, 2.05, 3.82, 3.6);
  s.addText(c[0], {x:x+0.28, y:2.28, w:3.3, h:0.3, fontSize:10.5, bold:true, color:MUTED,
    fontFace:BF, isTextBox:true, margin:0, charSpacing:1});
  s.addText(c[1], {x:x+0.28, y:2.66, w:3.3, h:0.9, fontSize:17, bold:true, color:NAVY,
    fontFace:HF, isTextBox:true, margin:0, lineSpacing:22});
  s.addText(c[2], {x:x+0.28, y:3.68, w:3.3, h:1.8, fontSize:11.5, color:INK,
    fontFace:BF, isTextBox:true, margin:0, lineSpacing:16});
});
card(s, M, 5.85, W-2*M, 0.92, "F1F5EC");
s.addText([{text:"Что это меняет для СВА:  ", options:{bold:true, color:NAVY}},
  {text:"обсуждать надо не «как вернуться в лимит», а два разных вопроса — какая база правильная и почему при её смене не пересматривались ни уровень, ни сигнальное значение, ни ряд."}],
  {x:M+0.28, y:6.06, w:W-2*M-0.56, h:0.55, fontSize:12.5, color:INK, fontFace:BF, isTextBox:true, margin:0, lineSpacing:17});
foot(s, "Источник: лист Monthly Приложения № 3, 36 месяцев (08.2023 — 07.2026); расчёт БРМ");
s.addNotes("Governing thought. Три опоры: проблема, решение, результат.");

/* ---------- 3. ЧТО ПРОИЗОШЛО ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "С 01.01.2026 знаменатель метрики — балансовый капитал вместо регуляторного;\nотношение двух баз сползло с 0,779 до 0,875 и константой не является",
  "Собственный капитал, млрд ₸, помесячно");
s.addChart(p.ChartType.line, [
  {name:"Регуляторный капитал", labels:D.labels, values:D.skold},
  {name:"Балансовый капитал",   labels:D.labels, values:D.sknew}],
  Object.assign({x:M, y:2.18, w:8.0, h:4.12, chartColors:[C1,C2], lineSize:2.5,
    showLegend:true, legendPos:"b", legendFontSize:10, legendFontFace:BF,
    lineDataSymbol:"none", valAxisMinVal:280, valAxisMaxVal:600}, axis));
card(s, 8.9, 2.18, 3.8, 4.12);
s.addText("Почему это важно", {x:9.18, y:2.40, w:3.24, h:0.3, fontSize:10.5, bold:true,
  color:MUTED, fontFace:BF, isTextBox:true, margin:0, charSpacing:1});
s.addText([
 {text:"Разрыв ряда нигде не оговорён", options:{bold:true, breakLine:true, color:NAVY}},
 {text:"Ни в отчёте, ни в заявлении риск-аппетита. Сравнение факта 2026 года с уровнем 2023 года некорректно по построению.\n", options:{breakLine:true}},
 {text:"Единого пересчёта не существует", options:{bold:true, breakLine:true, color:NAVY}},
 {text:"Отношение баз: 0,779 (08.2023) → 0,803 (02.2024) → 0,875 (01.2026). Эквивалент уровня 95 % сползает со 121,9 до 108,6 %.\n", options:{breakLine:true}},
 {text:"Записанный коэффициент отстал", options:{bold:true, breakLine:true, color:NAVY}},
 {text:"k = 0,8034 в реестре отвечает февралю 2024 года, а не дате смены базы: расхождение 9,6 пп по эквивалентному уровню."}],
 {x:9.18, y:2.76, w:3.24, h:3.5, fontSize:10.5, color:INK, fontFace:BF, isTextBox:true, margin:0, lineSpacing:14});
foot(s, "Источник: расчёт БРМ на данных листа Monthly; регуляторный капитал в источнике ведётся по 01.01.2026 включительно");
s.addNotes("Регуляторный ряд обрывается на 01.2026 — за 02-07.2026 значений в источнике нет.");

/* ---------- 4. ЦЕНА БЕЗДЕЙСТВИЯ ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "При неизменном портфеле метрика формально оказывается вне уровня в 12 месяцах из 36 —\nисключительно из-за смены базы расчёта, а не из-за роста концентрации",
  "Число месяцев, в которых коэффициент достигал или превышал 95 %");
s.addChart(p.ChartType.bar, [{name:"Месяцев ≥ 95 %", labels:["Регуляторная база\n(30 месяцев)","Балансовая база\n(36 месяцев)"], values:[0,12]}],
  Object.assign({x:M, y:2.15, w:6.1, h:3.5, barDir:"col", chartColors:[C1,RED],
    varyColors:true, showLegend:false, showValue:true, dataLabelPosition:"outEnd",
    dataLabelFontSize:16, dataLabelFontBold:true, dataLabelColor:INK, dataLabelFontFace:BF,
    valAxisMaxVal:14, barGapWidthPct:110}, axis));
const facts = [
 ["0 из 30","месяцев превышения на регуляторной базе — максимум 84,38 %, уровень не задет ни разу"],
 ["12 из 36","месяцев на балансовой базе, включая три последних подряд с ростом 93,3 → 98,4 → 100,9 → 101,5 %"],
 ["28–46","отчётов в год потребует жёлтая зона при уровне 95 %, не давая при этом ни одного месяца предупреждения"]];
facts.forEach((f,i)=>{
  const y = 2.15 + i*1.22;
  card(s, 7.05, y, 5.65, 1.06);
  s.addText(f[0], {x:7.3, y:y+0.16, w:1.75, h:0.74, fontSize:24, bold:true, color:NAVY,
    fontFace:HF, isTextBox:true, margin:0, valign:"middle"});
  s.addText(f[1], {x:9.05, y:y+0.16, w:3.45, h:0.74, fontSize:11, color:INK,
    fontFace:BF, isTextBox:true, margin:0, valign:"middle", lineSpacing:14});
});
card(s, M, 5.95, W-2*M, 0.82, "FBEEEC");
s.addText([{text:"Формулировка, которую следует избегать:  ", options:{bold:true, color:RED}},
  {text:"«лимит 95 % пробит по балансовому капиталу». Это категориальная ошибка — уровень 95 % устанавливался для другой базы и для балансовой никогда не утверждался."}],
  {x:M+0.28, y:6.13, w:W-2*M-0.56, h:0.5, fontSize:12, color:INK, fontFace:BF, isTextBox:true, margin:0, lineSpacing:16});
foot(s, "Источник: расчёт БРМ; контроль тождества «задолженность топ-20 за вычетом обеспечения / капитал» — 66 совпадений из 66");

/* ---------- 5. ДВА ПУТИ ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "Пересчёт базы и требование квартала на реагирование дают один уровень —\nрасхождение 0,05 процентного пункта",
  "Два независимых расчёта, ни один из которых не использует результат другого");
const paths = [
 ["Путь 1  ·  Пересчёт базы","108,63 %","95 % регуляторной базы × отношение капиталов на дату смены базы 01.01.2026 (0,87452). Смотрит только на определение метрики — на факт не смотрит вовсе."],
 ["Путь 2  ·  Цикл решения","108,58 %","Жёлтая линия на 90-м перцентиле ряда плюс запас z·σ·√3 на квартал реагирования. Смотрит только на процесс и на разброс — на смену базы не смотрит вовсе."]];
paths.forEach((c,i)=>{
  const x = M + i*4.4;
  card(s, x, 2.2, 4.1, 2.75);
  s.addText(c[0], {x:x+0.3, y:2.42, w:3.5, h:0.3, fontSize:10.5, bold:true, color:MUTED,
    fontFace:BF, isTextBox:true, margin:0, charSpacing:1});
  s.addText(c[1], {x:x+0.3, y:2.76, w:3.5, h:0.78, fontSize:38, bold:true, color:NAVY,
    fontFace:HF, isTextBox:true, margin:0});
  s.addText(c[2], {x:x+0.3, y:3.60, w:3.5, h:1.2, fontSize:11, color:INK,
    fontFace:BF, isTextBox:true, margin:0, lineSpacing:15});
});
card(s, M+8.8, 2.2, 3.3, 2.75, "F1F5EC");
s.addText("Расхождение", {x:M+9.1, y:2.42, w:2.7, h:0.3, fontSize:10.5, bold:true, color:MUTED,
  fontFace:BF, isTextBox:true, margin:0, charSpacing:1});
s.addText("0,05 пп", {x:M+9.1, y:2.76, w:2.7, h:0.78, fontSize:38, bold:true, color:GREEN,
  fontFace:HF, isTextBox:true, margin:0});
s.addText("Уровень не подобран под факт. Его независимо требуют и определение метрики, и длина цикла принятия решения.",
  {x:M+9.1, y:3.60, w:2.7, h:1.2, fontSize:11, color:INK, fontFace:BF, isTextBox:true, margin:0, lineSpacing:15});
card(s, M, 5.1, W-2*M, 1.6, "FAFBFD");
s.addText("Проверка от обратного: что даёт сохранение уровня 95 %", {x:M+0.3, y:5.28, w:6, h:0.3,
  fontSize:11.5, bold:true, color:NAVY, fontFace:BF, isTextBox:true, margin:0});
s.addText([
 {text:"Квартал на реагирование потребовал бы жёлтой линии на 85,97 %, выше которой ряд стоит 86,1 % времени — 31 месяц из 36.", options:{bullet:true, breakLine:true}},
 {text:"Светофор с одной постоянно горящей лампой не является светофором. Это и есть полная цена решения «уровень не трогаем»."  , options:{bullet:true}}],
 {x:M+0.3, y:5.62, w:W-2*M-0.6, h:0.95, fontSize:11.5, color:INK, fontFace:BF, isTextBox:true,
  margin:0, lineSpacing:16, paraSpaceAfter:4});
foot(s, "Совпадение подлежит перепроверке при уточнении σ приращений на недельном ряде (521 наблюдение)");
s.addNotes("Это центральный слайд защиты. Ответ на упрёк «подогнали лимит под факт».");

/* ---------- 6. ПОЧЕМУ КВАРТАЛ ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "Квартал — это длина цикла принятия решения, а не статистический выбор;\nсокращение цикла удешевляет зону вчетверо и остаётся в руках Банка",
  "Оценка длительности этапов — экспертная, подлежит фиксации в регламенте");
const steps = [["Расчёт и\nподготовка мер","~3 нед."],["Согласование\nв департаменте","~3 нед."],
  ["Вынос на\nуровень выше","~3 нед."],["Комитет / СД,\nрешение","~2–3 нед."]];
steps.forEach((st,i)=>{
  const x = M + i*2.55;
  card(s, x, 2.2, 2.3, 1.5);
  num(s, x+0.22, 2.4, i+1);
  s.addText(st[0], {x:x+0.22, y:2.9, w:1.9, h:0.55, fontSize:11.5, bold:true, color:NAVY,
    fontFace:BF, isTextBox:true, margin:0, lineSpacing:14});
  s.addText(st[1], {x:x+0.22, y:3.42, w:1.9, h:0.24, fontSize:10.5, color:MUTED,
    fontFace:BF, isTextBox:true, margin:0});
  if(i<3) s.addText("▸", {x:x+2.32, y:2.75, w:0.22, h:0.4, fontSize:16, color:MUTED,
    fontFace:BF, isTextBox:true, margin:0, align:"center"});
});
card(s, 10.75, 2.2, 1.95, 1.5, "F1F5EC");
s.addText("≥ 2 мес.", {x:10.93, y:2.5, w:1.6, h:0.45, fontSize:19, bold:true, color:NAVY,
  fontFace:HF, isTextBox:true, margin:0});
s.addText("минимум; квартал\nберётся как буфер", {x:10.93, y:2.98, w:1.6, h:0.55, fontSize:10.5,
  color:INK, fontFace:BF, isTextBox:true, margin:0, lineSpacing:14});
s.addText("Цикл — параметр калибровки, а не данность", {x:M, y:4.0, w:8, h:0.35, fontSize:14,
  bold:true, color:NAVY, fontFace:HF, isTextBox:true, margin:0});
s.addTable([
 [{text:"Требуемый запас времени",options:{bold:true}},{text:"Запас до уровня",options:{bold:true}},
  {text:"Жёлтая линия",options:{bold:true}},{text:"Доля времени в жёлтой зоне",options:{bold:true}},
  {text:"Отчётов в год",options:{bold:true}}],
 ["1 месяц — меры предсогласованы","5,21 пп","103,42 %","2,8 %","13"],
 ["2 месяца — часть решений на КУР","7,37 пп","101,26 %","5,6 %","14"],
 [{text:"3 месяца — решение через СД",options:{bold:true}},{text:"9,03 пп",options:{bold:true}},
  {text:"99,60 %",options:{bold:true}},{text:"11,1 %",options:{bold:true}},{text:"16",options:{bold:true}}]],
 {x:M, y:4.45, w:W-2*M, colW:[4.2,1.9,1.9,2.5,1.6], rowH:0.42, fontSize:11.5, fontFace:BF,
  color:INK, border:{type:"solid", color:LINE, pt:0.75}, align:"left", valign:"middle",
  fill:{color:"FFFFFF"}, margin:0.08});
foot(s, "Расчёт БРМ: запас = z(0,90)·σ приращений·√T при σ = 4,07 пп/мес; жёлтая линия = 108,63 − запас");
s.addNotes("Ключевая мысль: предсогласованный план мер — не бюрократия, а рычаг, поднимающий жёлтую линию на 3,8 пп.");

/* ---------- 7. СВЕТОФОР ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "Три зоны с границами 99,60 и 108,63 %: текущая точка 101,50 % — жёлтая,\nчто совпадает с фактическим режимом работы Банка",
  "Коэффициент топ-20 к собственному капиталу, балансовая база, % — с границами зон");
const lim = new Array(36).fill(108.63), yel = new Array(36).fill(99.60);
s.addChart(p.ChartType.line, [
  {name:"Коэффициент топ-20", labels:D.labels, values:D.new},
  {name:"Граница жёлтой зоны — 99,60 %", labels:D.labels, values:yel},
  {name:"Уровень риск-аппетита — 108,63 %", labels:D.labels, values:lim}],
  Object.assign({x:M, y:2.2, w:8.15, h:4.1, chartColors:[C1, AMBER, RED],
    lineSize:2.5, lineDataSymbol:"none", lineDash:["solid","dash","dash"],
    showLegend:true, legendPos:"b", legendFontSize:10, legendFontFace:BF,
    valAxisMinVal:75, valAxisMaxVal:115}, axis));
const zones = [
 ["КРАСНАЯ", RED, "≥ 108,63 %", "Еженедельно · эскалация на КУР немедленно · письменное описание устранения со сроком"],
 ["ЖЁЛТАЯ", AMBER, "99,60 — 108,63 %", "Еженедельно · декомпозиция движения на числитель и знаменатель · проект мер на КУР в 20 рабочих дней"],
 ["ЗЕЛЁНАЯ", GREEN, "< 99,60 %", "Ежемесячно в составе Приложения № 3 · запас до жёлтой линии в пп и в σ · действий не требуется"]];
zones.forEach((z,i)=>{
  const y = 2.2 + i*1.42;
  card(s, 9.0, y, 3.7, 1.3);
  s.addShape(p.ShapeType.ellipse, {x:9.24, y:y+0.22, w:0.3, h:0.3, fill:{color:z[1]}, line:{color:z[1]}});
  s.addText(z[0], {x:9.62, y:y+0.2, w:1.5, h:0.32, fontSize:12, bold:true, color:NAVY,
    fontFace:BF, isTextBox:true, margin:0, valign:"middle", charSpacing:0.6});
  s.addText(z[2], {x:11.0, y:y+0.2, w:1.5, h:0.32, fontSize:11, color:MUTED,
    fontFace:BF, isTextBox:true, margin:0, valign:"middle", align:"right"});
  s.addText(z[3], {x:9.24, y:y+0.58, w:3.24, h:0.62, fontSize:10, color:INK,
    fontFace:BF, isTextBox:true, margin:0, lineSpacing:13});
});
foot(s, "Доля времени в жёлтой зоне на истории 36 месяцев — 11,1 %; три переключения режима за три года; де-эскалация после двух наблюдений ниже границы");

/* ---------- 8. ЧЕГО ЗОНА НЕ ВИДИТ ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "Январский скачок был движением капитала, а не концентрации — уровневая\nзона не предупредила бы о нём ни при какой границе",
  "Разложение двух подъёмов коэффициента на вклад числителя и знаменателя, процентные пункты");
s.addChart(p.ChartType.bar, [
  {name:"Вклад числителя (задолженность топ-20)", labels:["12.2025 → 01.2026","03.2026 → 07.2026"], values:[2.11, 11.95]},
  {name:"Вклад капитала (знаменатель)",           labels:["12.2025 → 01.2026","03.2026 → 07.2026"], values:[7.41, 1.45]}],
  Object.assign({x:M, y:2.15, w:6.5, h:3.45, barDir:"col", barGrouping:"stacked",
    chartColors:[C1, C2], showLegend:true, legendPos:"b", legendFontSize:10, legendFontFace:BF,
    showValue:true, dataLabelPosition:"ctr", dataLabelFontSize:11, dataLabelColor:"FFFFFF",
    dataLabelFontBold:true, dataLabelFontFace:BF, barGapWidthPct:90}, axis));
card(s, 7.45, 2.15, 5.25, 1.55, "FBEEEC");
s.addText("Почему уровневая зона бессильна", {x:7.72, y:2.35, w:4.7, h:0.3, fontSize:11.5,
  bold:true, color:NAVY, fontFace:BF, isTextBox:true, margin:0});
s.addText("Капитал упал на 7,92 % за один месяц, коэффициент прошёл 86,15 → 95,85 % за один шаг. Жёлтая линия выше 86,15 % не дала бы ни одного месяца предупреждения — при том, что 86,15 % ниже медианы ряда.",
  {x:7.72, y:2.68, w:4.7, h:0.9, fontSize:11, color:INK, fontFace:BF, isTextBox:true, margin:0, lineSpacing:14});
s.addText("Два триггера на движение — работают в любой зоне", {x:7.45, y:3.95, w:5.25, h:0.3,
  fontSize:13, bold:true, color:NAVY, fontFace:HF, isTextBox:true, margin:0});
const trg = [["Δ капитала ≤ −3 % за месяц","2 срабатывания за 36 месяцев — 04.2025 и 01.2026. Январь пойман"],
             ["Δ задолженности ≥ +5 % за месяц","5 срабатываний; предшествует всем подъёмам коэффициента на 4,5–8,7 пп"]];
trg.forEach((t,i)=>{
  const y = 4.35 + i*1.02;
  card(s, 7.45, y, 5.25, 0.92);
  s.addText(t[0], {x:7.72, y:y+0.13, w:4.7, h:0.28, fontSize:11.5, bold:true, color:NAVY,
    fontFace:BF, isTextBox:true, margin:0});
  s.addText(t[1], {x:7.72, y:y+0.42, w:4.7, h:0.42, fontSize:10.5, color:INK,
    fontFace:BF, isTextBox:true, margin:0, lineSpacing:13});
});
foot(s, "Срабатывание любого триггера переводит метрику в жёлтый режим на два месяца независимо от уровня");

/* ---------- 9. МЕРЫ ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "Проект мер готовится при входе в жёлтую зону, не дожидаясь красной —\nв этом и состоит выигранный квартал",
  "Лестница мер реагирования; опора — OCC 12 CFR 30 App D II.H, BCBS 239 принцип 10, Указание Банка России 3624-У п. 4.14");
s.addTable([
 [{text:"",options:{fill:{color:"FFFFFF"}}},
  {text:"ЗЕЛЁНАЯ  < 99,60 %",options:{bold:true, color:"FFFFFF", fill:{color:GREEN}}},
  {text:"ЖЁЛТАЯ  99,60 — 108,63 %",options:{bold:true, color:"FFFFFF", fill:{color:AMBER}}},
  {text:"КРАСНАЯ  ≥ 108,63 %",options:{bold:true, color:"FFFFFF", fill:{color:RED}}}],
 [{text:"Частота",options:{bold:true}},"Ежемесячно","Еженедельно","Еженедельно + внеочередной расчёт по триггерам"],
 [{text:"Содержание",options:{bold:true}},"Факт и запас до жёлтой линии в пп и в σ","+ декомпозиция движения на вклад числителя и знаменателя","+ помесячная динамика обоих вкладов за 12 месяцев"],
 [{text:"Раскрытие",options:{bold:true}},"—","Топ-5 групп по приросту задолженности; Δ денежного обеспечения; Δ капитала с причиной","+ перечень групп, выход которых возвращает метрику под уровень, с оценкой исполнимости"],
 [{text:"Уведомление",options:{bold:true}},"—","Владелец метрики → руководитель БРМ, 3 рабочих дня","КУР немедленно; Правление на ближайшем заседании"],
 [{text:"Действие",options:{bold:true}},"Не требуется","Проект мер на КУР в течение 20 рабочих дней","Письменное описание устранения со сроком и ответственным; временный акцепт — только решением СД"],
 [{text:"Эскалация к СД",options:{bold:true}},"—","—","При длительности свыше квартала либо повторе в течение года"]],
 {x:M, y:2.15, w:W-2*M, colW:[1.55,2.65,3.9,4.0], rowH:0.5, fontSize:10.5, fontFace:BF,
  color:INK, border:{type:"solid", color:LINE, pt:0.75}, align:"left", valign:"middle",
  fill:{color:"FFFFFF"}, margin:0.07});
card(s, M, 6.05, W-2*M, 0.78, "F1F5EC");
s.addText([{text:"Возможность, а не удавка:  ", options:{bold:true, color:NAVY}},
  {text:"де-эскалация происходит автоматически после двух наблюдений ниже границы; эскалация к Совету директоров наступает не при первом пробое, а при длительности или повторе."}],
  {x:M+0.28, y:6.22, w:W-2*M-0.56, h:0.46, fontSize:11.5, color:INK, fontFace:BF, isTextBox:true, margin:0, lineSpacing:15});
foot(s, "Рамка мер принята как проект решением Р-9; настоящая лестница — её кредитная часть");

/* ---------- 10. МЕТОДЫ ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "Четыре метода из восьми выдерживают защиту; два независимых дают\n99,60 и 99,55 % — остальные отсекаются по проверяемым признакам",
  "Все методы посчитаны на одном ряде при уровне 108,63 % — сравнение возможно только на общем стенде");
s.addTable([
 [{text:"Метод",options:{bold:true}},{text:"Жёлтая линия",options:{bold:true}},
  {text:"Доля времени",options:{bold:true}},{text:"Что защищает метод",options:{bold:true}},
  {text:"Чем его атакуют",options:{bold:true}}],
 [{text:"H · Цикл решения, T = 3 мес.",options:{bold:true, color:GREEN}},{text:"99,60 %",options:{bold:true}},"11,1 %","Единственный, где параметр обоснован внешне — длиной процесса, а не вкусом аналитика","Требует, чтобы длительность цикла была зафиксирована в регламенте, а не бралась со слов"],
 [{text:"C · Квантиль 90 %",options:{bold:true, color:GREEN}},{text:"99,55 %",options:{bold:true}},"11,1 %","Прост, воспроизводим, задаёт долю времени в зоне напрямую","Не содержит понятия времени на реакцию; на 36 точках квантиль держится на двух наблюдениях"],
 [{text:"F · Стресс-имплицированный",options:{bold:true, color:GREEN}},"по сценарию","—","Связывает уровень с НСТ: падение капитала на 6,6 % выводит метрику на уровень","Плавает вместе со сценарием, который пересматривается ежегодно"],
 [{text:"D · Расстояние в σ",options:{bold:true, color:GREEN}},"диагностика","—","Обязательный первый шаг: 1,75 σ до уровня — зонирование осмысленно","Не является методом калибровки и самостоятельного ответа не даёт"],
 [{text:"A · Доля от лимита",options:{color:MUTED}},{text:"92,3 %",options:{color:MUTED}},{text:"36,1 %",options:{color:MUTED}},{text:"Не требует ряда вовсе",options:{color:MUTED}},{text:"Попадает внутрь рабочего диапазона — методика контура прямо запрещает",options:{color:MUTED}}],
 [{text:"B · Максимум режима + 2σ",options:{color:MUTED}},{text:"113,2 %",options:{color:MUTED}},{text:"0 %",options:{color:MUTED}},{text:"Привязан к наблюдаемому режиму",options:{color:MUTED}},{text:"Жёлтая линия оказывается выше красной — метод переворачивается",options:{color:MUTED}}],
 [{text:"G · Развёртка по ложным тревогам",options:{color:MUTED}},{text:"—",options:{color:MUTED}},{text:"—",options:{color:MUTED}},{text:"Прямо оптимизирует пару «предупреждение / ложные тревоги»",options:{color:MUTED}},{text:"Требует эпизодов; при пересчитанном уровне их ноль — неприменим по данным",options:{color:MUTED}}]],
 {x:M, y:2.15, w:W-2*M, colW:[2.75,1.35,1.2,3.4,3.4], rowH:0.5, fontSize:10, fontFace:BF,
  color:INK, border:{type:"solid", color:LINE, pt:0.75}, align:"left", valign:"middle",
  fill:{color:"FFFFFF"}, margin:0.07});
foot(s, "Метод коллеги из смежного отдела встаёт в ту же таблицу: достаточно свести его к одной жёлтой линии и посчитать те же шесть показателей");

/* ---------- 11. РАЗВИЛКИ ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "Три решения остаются за руководством — каждое с посчитанной ценой,\nни одно не безальтернативно",
  "Материалы на УО выносятся с обеими картинами: факт против 95 % регуляторных и факт против 108,63 % балансовых");
const forks = [
 ["Якорная дата пересчёта","Дата смены базы 01.01.2026 → 108,63 %.\nФевраль 2024 (как в реестре) → 118,25 %.\nНачало окна 08.2023 → 121,93 %.",
  "Выбирается правилом до того, как посмотрели на факт. Иначе защита рассыпается на первом вопросе."],
 ["Требуемый запас времени","3 месяца → жёлтая 99,60 %, 11,1 % времени.\n2 месяца → 101,26 %, 5,6 %.\n1 месяц → 103,42 %, 2,8 %.",
  "Сокращается предсогласованием мер: если КУР вправе действовать без нового решения СД, зона дешевеет вчетверо."],
 ["Частота наблюдения","Месячная — задержка обнаружения до 30 дней.\nНедельная — до 7 дней, ряд ведётся с 2016 года.",
  "Операционная стоимость перехода нулевая: 521 наблюдение уже собирается. Требуемый запас при этом не меняется."]];
forks.forEach((f,i)=>{
  const y = 2.15 + i*1.52;
  card(s, M, y, W-2*M, 1.38);
  num(s, M+0.26, y+0.2, i+1);
  s.addText(f[0], {x:M+0.82, y:y+0.18, w:2.9, h:0.44, fontSize:13.5, bold:true, color:NAVY,
    fontFace:HF, isTextBox:true, margin:0, valign:"middle"});
  s.addText(f[1], {x:M+3.85, y:y+0.16, w:3.6, h:1.08, fontSize:10.5, color:INK,
    fontFace:BF, isTextBox:true, margin:0, lineSpacing:14, valign:"middle"});
  s.addText(f[2], {x:M+7.65, y:y+0.16, w:4.35, h:1.08, fontSize:10.5, color:MUTED,
    fontFace:BF, isTextBox:true, margin:0, lineSpacing:14, valign:"middle"});
});
foot(s, "Ни одна из развилок не закрывается расчётом: расчёт даёт цену каждого варианта, выбор принадлежит уполномоченному органу");

/* ---------- 12. ПЛАН ---------- */
s = p.addSlide(); s.background = {color:BG};
title(s, "К 30.09 — записка с уровнем и зонами; к 31.12 — предложения на УО",
  "Сроки установлены планом по замечанию СВА и не сдвигаются");
const plan = [
 ["30.09.2026","Анализ актуальности действующих уровней","Записка: уровень, зоны, меры реагирования, обе картины по базам","БРМ"],
 ["31.12.2026","Предложения по сохранению либо актуализации","Материалы на УО, выписка из протокола","БРМ, УО"],
 ["1 кв. 2027","Два недостающих уровня риск-аппетита","Пункт 38 Плана SREP — срок сокращён Агентством","БРМ"]];
s.addTable([
 [{text:"Срок",options:{bold:true}},{text:"Мероприятие",options:{bold:true}},
  {text:"Артефакт",options:{bold:true}},{text:"Ответственный",options:{bold:true}}],
 ...plan.map(r=>[{text:r[0],options:{bold:true,color:NAVY}},r[1],r[2],r[3]])],
 {x:M, y:2.2, w:W-2*M, colW:[1.6,4.0,4.9,1.6], rowH:0.5, fontSize:11, fontFace:BF,
  color:INK, border:{type:"solid", color:LINE, pt:0.75}, align:"left", valign:"middle",
  fill:{color:"FFFFFF"}, margin:0.07});
s.addText("Что требуется получить, чтобы записка опиралась на документ, а не на пересказ",
  {x:M, y:4.05, w:9, h:0.35, fontSize:14, bold:true, color:NAVY, fontFace:HF, isTextBox:true, margin:0});
const need = [
 ["Акт СВА","Чтобы формулировка замечания цитировалась дословно. По второму замечанию письменного подтверждения нет вовсе","Внутренний аудит"],
 ["Основание смены базы капитала","Реквизиты решения о переходе на балансовый капитал с 01.01.2026. От него зависит якорная дата и оба уровня","Финансовый блок"],
 ["Длительность цикла согласования","Фактические сроки этапов — сегодня оценка экспертная. Без неё метод H защищается слабее","БРМ, секретариат УО"]];
need.forEach((n,i)=>{
  const y = 4.5 + i*0.78;
  card(s, M, y, W-2*M, 0.68);
  s.addText(n[0], {x:M+0.28, y:y+0.1, w:3.3, h:0.48, fontSize:11.5, bold:true, color:NAVY,
    fontFace:BF, isTextBox:true, margin:0, valign:"middle"});
  s.addText(n[1], {x:M+3.7, y:y+0.1, w:6.4, h:0.48, fontSize:10.5, color:INK,
    fontFace:BF, isTextBox:true, margin:0, valign:"middle", lineSpacing:13});
  s.addText(n[2], {x:M+10.25, y:y+0.1, w:1.75, h:0.48, fontSize:10.5, color:MUTED,
    fontFace:BF, isTextBox:true, margin:0, valign:"middle", align:"right"});
});
foot(s, "Все расчёты воспроизводимы: docs/analysis/risk_appetite — calib/top20_zones.py, calib/top20_cadence.py, data/top20_monthly_2023_08_2026_07.csv");

p.writeFile({fileName:"RA_top20_zones.pptx"}).then(f=>console.log("собрано:", f));

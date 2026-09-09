// Презентация по уровню и зонам топ-20 (docs/analysis/risk_appetite), 20 слайдов.
// Порядок изложения — по нарастанию: данные -> средние -> медианы и кварталы ->
// осложнения -> предложение -> меры -> решения. Выводы раньше оснований не идут.
// Запуск:  node deck_ra_data_gen.js && node deck_ra_top20.js
//          python3 pptx_enum_check.py RA_top20_zones.pptx   <- обязательно
//          python3 zapiska_ra_top20.py                      <- записка и транскрипт
// Обложка cover_bg.png декоративная, в репозиторий не коммитится.
const pptxgen = require("pptxgenjs");
const D = require("./deck_ra_data.js");

const NAVY="1E2761", ICE="CADCFC", INK="1F2933", MUTED="5A6478", LINE="D8DEE9", BG="FFFFFF";
const C1="2E6FA8", C2="C97B1E";
const GREEN="2E7D4F", AMBER="D18F00", RED="B3261E";
const HF="Cambria", BF="Calibri";
const p = new pptxgen(); p.layout="LAYOUT_WIDE";
p.author="БРМ"; p.company="АО «Евразийский банк»";
const W=13.3, H=7.5, M=0.6;

function head(s, kicker, t, sub){
  if(kicker) s.addText(kicker, {x:M, y:0.34, w:W-2*M, h:0.28, fontSize:10, bold:true,
    color:MUTED, fontFace:BF, isTextBox:true, margin:0, charSpacing:1.4});
  s.addText(t, {x:M, y:0.66, w:W-2*M, h:1.12, fontSize:21, bold:true, color:NAVY,
    fontFace:HF, isTextBox:true, margin:0, valign:"top", lineSpacing:25});
  if(sub) s.addText(sub, {x:M, y:1.80, w:W-2*M, h:0.32, fontSize:12.5, color:MUTED,
    fontFace:BF, isTextBox:true, margin:0});
}
function foot(s, t){ s.addText(t, {x:M, y:H-0.52, w:W-2*M, h:0.28, fontSize:9, color:MUTED,
  fontFace:BF, isTextBox:true, margin:0}); }
function card(s,x,y,w,h,fill){ s.addShape(p.ShapeType.roundRect, {x,y,w,h, rectRadius:0.06,
  fill:{color:fill||"F4F6FA"}, line:{color:LINE, width:0.75},
  shadow:{type:"outer", angle:90, blur:6, offset:0.03, color:"9AA6B8", opacity:0.28}}); }
function num(s,x,y,n,c){ s.addShape(p.ShapeType.ellipse,{x,y,w:0.42,h:0.42,fill:{color:c||NAVY},line:{color:c||NAVY}});
  s.addText(String(n),{x,y,w:0.42,h:0.42,fontSize:15,bold:true,color:"FFFFFF",align:"center",
    valign:"middle",fontFace:BF,isTextBox:true,margin:0}); }
function takeaway(s, txt, fill, col){
  card(s, M, 6.02, W-2*M, 0.80, fill||"F1F5EC");
  s.addText(txt, {x:M+0.28, y:6.20, w:W-2*M-0.56, h:0.46, fontSize:12.5, color:col||INK,
    fontFace:BF, isTextBox:true, margin:0, lineSpacing:16});
}
const axis={catAxisLabelColor:MUTED, valAxisLabelColor:MUTED, catAxisLabelFontSize:9,
  valAxisLabelFontSize:9, catAxisLabelFontFace:BF, valAxisLabelFontFace:BF,
  valGridLine:{color:"EAEEF4", size:1}, catGridLine:{style:"none"}};

/* 1 ТИТУЛ */
let s=p.addSlide(); s.background={color:NAVY};
s.addImage({path:"cover_bg.png", x:0, y:0, w:W, h:H});
s.addShape(p.ShapeType.rect,{x:0,y:0,w:7.9,h:H,fill:{color:NAVY,transparency:22},line:{color:NAVY,width:0}});
s.addText("Концентрация топ-20:\nуровень и зоны", {x:M, y:2.0, w:8.6, h:1.9, fontSize:40, bold:true,
  color:"FFFFFF", fontFace:HF, isTextBox:true, margin:0, lineSpacing:46});
s.addText("Что показывают данные и что предлагается решить", {x:M, y:4.05, w:9.2, h:0.5,
  fontSize:16, color:ICE, fontFace:BF, isTextBox:true, margin:0});
s.addShape(p.ShapeType.rect,{x:M,y:4.8,w:2.2,h:0.02,fill:{color:ICE},line:{color:ICE}});
s.addText([{text:"Департамент риск-менеджмента  ·  8 сентября 2026",options:{breakLine:true}},
  {text:"Основание: замечание СВА о ежегодном пересмотре уровней риск-аппетита",options:{breakLine:true}},
  {text:"Сроки: 30.09.2026 и 31.12.2026"}],
  {x:M, y:5.1, w:9.6, h:1.0, fontSize:12, color:ICE, fontFace:BF, isTextBox:true, margin:0, lineSpacing:19});
s.addNotes("Разговор о показателе концентрации топ-20 крупных заёмщиков. Идём по порядку: сначала какие данные собраны, потом самый простой взгляд на них, потом что этот простой взгляд упускает, и только в конце — предложение. Ничего из предложения раньше времени не понадобится.");

/* 2 О ЧЁМ РАЗГОВОР */
s=p.addSlide(); s.background={color:BG};
head(s,"О ЧЁМ РАЗГОВОР","Три вещи, которые нужно унести с этой встречи");
const three=[["Показатель вырос","За последние полгода концентрация топ-20 к капиталу поднялась до максимума за три года. Это видно по средним, без всякой статистики."],
 ["Сравнивать не с чем","С начала 2026 года показатель считается от другого капитала, а уровень остался прежним. Старый уровень к новому счёту не подходит."],
 ["Нужно решение","Восстановить уровень под действующий счёт и разбить его на зелёную, жёлтую и красную зоны — чтобы был запас времени на реакцию."]];
three.forEach((c,i)=>{ const y=2.35+i*1.32; card(s,M,y,W-2*M,1.18); num(s,M+0.28,y+0.2,i+1);
  s.addText(c[0],{x:M+0.9,y:y+0.16,w:3.1,h:0.4,fontSize:15,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0,valign:"middle"});
  s.addText(c[1],{x:M+4.1,y:y+0.14,w:7.7,h:0.9,fontSize:12.5,color:INK,fontFace:BF,isTextBox:true,margin:0,valign:"middle",lineSpacing:16}); });
foot(s,"Дальше — по порядку: данные, простой счёт, что он упускает, предложение, меры, решения");
s.addNotes("Одна минута. Три мысли. Показатель вырос — это факт из данных. Сравнивать его не с чем — это факт из документов. Нужно решение — это то, ради чего собрались. Всё остальное на следующих слайдах будет только подтверждением этих трёх.");

/* 3 ЧТО СОБРАЛИ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 1 · ДАННЫЕ","Что собрано и откуда — прежде чем что-либо считать",
  "Сбор выполнен совместно с подразделениями; все цифры проверены на согласованность");
const dat=[["36 месяцев","август 2023 — июль 2026","помесячно: задолженность топ-20, капитал, коэффициент"],
 ["521 наблюдение","май 2016 — август 2026","еженедельно, из оперативных файлов подразделения"],
 ["2 базы капитала","регуляторная и балансовая","обе ведутся параллельно, без сшивки рядов"],
 ["66 из 66","контроль сходимости","коэффициент = задолженность ÷ капитал сходится на всех точках"]];
dat.forEach((c,i)=>{ const x=M+(i%2)*6.15, y=2.35+Math.floor(i/2)*1.6; card(s,x,y,5.9,1.42);
  s.addText(c[0],{x:x+0.3,y:y+0.16,w:2.5,h:0.5,fontSize:22,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0});
  s.addText(c[1],{x:x+0.3,y:y+0.68,w:5.3,h:0.28,fontSize:11.5,bold:true,color:INK,fontFace:BF,isTextBox:true,margin:0});
  s.addText(c[2],{x:x+0.3,y:y+0.96,w:5.3,h:0.36,fontSize:11,color:MUTED,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14}); });
takeaway(s,"Ничего из дальнейшего не считается «на глазок»: под каждым числом лежит ряд, который можно открыть и пересчитать.","FAFBFD");
foot(s,"Ряд и расчёты хранятся в рабочем пространстве контура; каждая цифра воспроизводится одной командой");
s.addNotes("Это самый скучный слайд и самый важный. Мы не берём цифры из отчёта — мы собрали ряд заново и проверили его. Контроль сходимости: коэффициент должен равняться задолженности, делённой на капитал. Сошлось на всех 66 точках, где обе величины есть. Значит дальше спорить можно о выводах, но не о данных.");

/* 4 КАК СЧИТАЕТСЯ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 1 · ПОКАЗАТЕЛЬ","Показатель — простая дробь: сколько должны двадцать крупнейших на каждый тенге капитала");
card(s,M,2.4,5.5,1.5,"F1F5EC");
s.addText("Задолженность топ-20\nминус денежное обеспечение",{x:M+0.3,y:2.55,w:4.9,h:0.62,fontSize:13,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0,align:"center",lineSpacing:17});
s.addShape(p.ShapeType.rect,{x:M+0.6,y:3.22,w:4.3,h:0.025,fill:{color:NAVY},line:{color:NAVY}});
s.addText("Собственный капитал Банка",{x:M+0.3,y:3.35,w:4.9,h:0.4,fontSize:13,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0,align:"center"});
s.addText("=  101,50 %",{x:M+5.9,y:2.85,w:2.4,h:0.6,fontSize:26,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0,valign:"middle"});
s.addText("на 01.07.2026",{x:M+5.9,y:3.42,w:2.4,h:0.3,fontSize:11,color:MUTED,fontFace:BF,isTextBox:true,margin:0});
const parts=[["Числитель","Растёт, когда крупные заёмщики берут больше или когда снижается денежное обеспечение"],
 ["Знаменатель","Растёт вместе с прибылью и капиталом; падает при убытке, выплате дивидендов или смене правила расчёта"],
 ["Смысл","Чем выше дробь, тем сильнее Банк зависит от двадцати имён. Уровень риск-аппетита ограничивает эту зависимость"]];
parts.forEach((c,i)=>{ const y=2.4+i*1.32; card(s,9.0,y,3.7,1.18);
  s.addText(c[0],{x:9.26,y:y+0.13,w:3.2,h:0.28,fontSize:12,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0});
  s.addText(c[1],{x:9.26,y:y+0.42,w:3.2,h:0.68,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:13}); });
takeaway(s,"Показатель может вырасти по двум совершенно разным причинам — из-за портфеля и из-за капитала. Дальше это различие окажется главным.","FAFBFD");
s.addNotes("Формула простая, но у неё две части. Числитель — про портфель. Знаменатель — про капитал. Одна и та же цифра может вырасти и оттого, что выдали больше крупным клиентам, и оттого, что упал капитал. Это различие понадобится на слайде про январь.");

/* 5 СРЕДНИЕ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 2 · САМОЕ ПРОСТОЕ","Простое среднее уже показывает разворот: чем короче окно, тем выше уровень",
  "Средний коэффициент за разные периоды, %");
s.addChart(p.ChartType.bar,[{name:"Среднее, %", labels:D.avgLab, values:D.avgVal}],
  Object.assign({x:M,y:2.35,w:7.6,h:3.5,barDir:"col",chartColors:[C1,C1,C1,C2,C2,RED],
   varyColors:true,showLegend:false,showValue:true,dataLabelPosition:"outEnd",
   dataLabelFontSize:13,dataLabelFontBold:true,dataLabelColor:INK,dataLabelFontFace:BF,
   valAxisMinVal:70,valAxisMaxVal:112,barGapWidthPct:60},axis));
card(s,8.5,2.35,4.2,3.5);
s.addText("Как это читать",{x:8.78,y:2.56,w:3.7,h:0.3,fontSize:10.5,bold:true,color:MUTED,fontFace:BF,isTextBox:true,margin:0,charSpacing:1});
s.addText([{text:"За три года — 91,6 %.",options:{bold:true,breakLine:true,color:NAVY}},
 {text:"Спокойный уровень, далеко от любых границ.\n",options:{breakLine:true}},
 {text:"За последние полгода — 95,2 %.",options:{bold:true,breakLine:true,color:NAVY}},
 {text:"Уже выше трёхлетнего среднего почти на 4 пункта.\n",options:{breakLine:true}},
 {text:"За последние три месяца — 100,3 %.",options:{bold:true,breakLine:true,color:NAVY}},
 {text:"И последняя точка 101,5 % — максимум с января 2024 года.\n",options:{breakLine:true}},
 {text:"Никакой статистики здесь не применялось: это арифметическое среднее.",options:{italic:true}}],
 {x:8.78,y:2.92,w:3.7,h:2.8,fontSize:11,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14.5});
takeaway(s,"Вывод, для которого достаточно калькулятора: показатель не колеблется вокруг нормы, а последовательно растёт.","FAFBFD");
s.addNotes("Самый простой возможный расчёт. Берём среднее за три года, за два, за год, за полгода, за квартал. Если бы показатель просто колебался, все средние были бы примерно одинаковы. Они не одинаковы — они выстраиваются лесенкой вверх. Это уже вывод, и он не требует ни одной формулы сложнее деления.");

/* 6 РЯД */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 2 · РЯД ЦЕЛИКОМ","Тот же вывод виден на самом ряде: провал весной 2025 года и подъём с начала 2026",
  "Коэффициент топ-20 к собственному капиталу помесячно, %");
s.addChart(p.ChartType.line,[{name:"Коэффициент, %", labels:D.labels, values:D.new}],
  Object.assign({x:M,y:2.35,w:8.3,h:3.5,chartColors:[C1],lineSize:2.75,lineDataSymbol:"none",
   showLegend:false,valAxisMinVal:75,valAxisMaxVal:110},axis));
const pts=[["78,6 %","минимум ряда — март 2025"],["105,9 %","максимум ряда — январь 2024"],
  ["101,5 %","последняя точка — июль 2026"],["+13,6 пп","рост за четыре месяца, март → июль 2026"]];
pts.forEach((c,i)=>{ const y=2.35+i*0.9; card(s,9.1,y,3.6,0.78);
  s.addText(c[0],{x:9.34,y:y+0.1,w:1.5,h:0.58,fontSize:17,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0,valign:"middle"});
  s.addText(c[1],{x:10.85,y:y+0.1,w:1.65,h:0.58,fontSize:10,color:INK,fontFace:BF,isTextBox:true,margin:0,valign:"middle",lineSpacing:12.5}); });
takeaway(s,"Ряд не ровный: у него есть и глубокий провал, и быстрый подъём. Значит вопрос не «какой уровень нормальный», а «что считать нормальным режимом».","FAFBFD");
s.addNotes("Это тот же ряд, из которого получены средние. Обратите внимание на две вещи. Первая: весной 2025 года показатель опускался до 78,6 — это ниже, чем когда-либо. Вторая: с марта 2026 года он вырос на 13,6 пункта за четыре месяца. Такой ряд нельзя описать одним числом.");

/* 7 МЕДИАНА И КВАРТИЛИ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 3 · ЧУТЬ ТОЧНЕЕ","Половину времени показатель проводит между 87,8 и 96,8 % — этот коридор и есть рабочий режим",
  "Распределение 36 месячных значений: минимум, квартили, медиана, максимум");
const x0=M+0.3, wPx=11.5, lo=75, hi=110, sc=v=>x0+(v-lo)/(hi-lo)*wPx;
s.addShape(p.ShapeType.rect,{x:sc(78.60),y:3.35,w:sc(105.90)-sc(78.60),h:0.06,fill:{color:LINE},line:{color:LINE}});
s.addShape(p.ShapeType.roundRect,{x:sc(87.80),y:2.95,w:sc(96.80)-sc(87.80),h:0.86,rectRadius:0.05,
  fill:{color:"DCE6F2"},line:{color:C1,width:1.25}});
s.addShape(p.ShapeType.rect,{x:sc(90.20)-0.015,y:2.95,w:0.03,h:0.86,fill:{color:NAVY},line:{color:NAVY}});
[[78.60,"минимум","78,6"],[87.80,"нижняя четверть","87,8"],[90.20,"медиана","90,2"],
 [96.80,"верхняя четверть","96,8"],[105.90,"максимум","105,9"]].forEach(([v,t,n],i)=>{
  const yy = (i%2===0)?4.0:2.35;
  s.addText(n,{x:sc(v)-0.55,y:yy,w:1.1,h:0.3,fontSize:13,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0,align:"center"});
  s.addText(t,{x:sc(v)-0.95,y:yy+(i%2===0?0.3:-0.28),w:1.9,h:0.28,fontSize:9.5,color:MUTED,fontFace:BF,isTextBox:true,margin:0,align:"center"});
});
const qq=[["9,0 пп","ширина рабочего коридора — от нижней четверти до верхней"],
 ["27,3 пп","весь размах ряда: от 78,6 до 105,9 %"],
 ["101,5 %","где мы сейчас — выше верхней четверти, в верхних 25 % своей истории"]];
qq.forEach((c,i)=>{ const x=M+i*4.08; card(s,x,4.75,3.82,1.15);
  s.addText(c[0],{x:x+0.28,y:4.9,w:3.3,h:0.42,fontSize:20,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0});
  s.addText(c[1],{x:x+0.28,y:5.32,w:3.3,h:0.5,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:13}); });
takeaway(s,"Сегодняшнее значение попадает в верхнюю четверть собственной истории показателя. Это ещё не нарушение, но уже не рядовое положение.","FAFBFD");
s.addNotes("Медиана — значение, выше и ниже которого показатель бывал одинаково часто. Она равна 90,2. Половину времени показатель находился в коридоре от 87,8 до 96,8 — это девять пунктов шириной. Сегодня мы на 101,5, то есть выше этого коридора целиком.");

/* 8 КВАРТАЛЫ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 3 · ПО КВАРТАЛАМ","Пять кварталов подряд показатель растёт: 87,4 → 91,1 → 97,5 → 101,5 %",
  "Среднее значение коэффициента за каждый квартал, %");
s.addChart(p.ChartType.bar,[{name:"Среднее за квартал, %", labels:D.qlab, values:D.qval}],
  Object.assign({x:M,y:2.35,w:8.3,h:3.5,barDir:"col",chartColors:[C1],showLegend:false,
   showValue:true,dataLabelPosition:"outEnd",dataLabelFontSize:9.5,dataLabelColor:INK,
   dataLabelFontFace:BF,valAxisMinVal:70,valAxisMaxVal:110,barGapWidthPct:45},axis));
card(s,9.1,2.35,3.6,3.5);
s.addText("Что видно по кварталам",{x:9.34,y:2.56,w:3.1,h:0.3,fontSize:10.5,bold:true,color:MUTED,fontFace:BF,isTextBox:true,margin:0,charSpacing:1});
s.addText([{text:"Дно — 1 кв. 2025 года: 80,2 %.",options:{bold:true,breakLine:true,color:NAVY}},
 {text:"Ниже показатель не опускался ни разу.\n",options:{breakLine:true}},
 {text:"С 4 кв. 2025 — рост без перерыва.",options:{bold:true,breakLine:true,color:NAVY}},
 {text:"87,4 → 91,1 → 97,5 → 101,5 %. Четыре квартала подряд вверх, суммарно +21,3 пункта от дна.\n",options:{breakLine:true}},
 {text:"Задолженность топ-20 за тот же срок выросла с 372 до 449 млрд ₸.",options:{breakLine:true}},
 {text:"\nЭто не колебание. Это направление.",options:{bold:true,italic:true}}],
 {x:9.34,y:2.92,w:3.1,h:2.8,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14});
takeaway(s,"Квартальный взгляд убирает месячный шум и оставляет одно: устойчивый рост пятый квартал подряд.","FAFBFD");
s.addNotes("Квартальное усреднение гасит случайные месячные колебания. После него остаётся чистая картина: дно в первом квартале 2025 года, затем непрерывный подъём. Четыре квартала подряд вверх — это уже не шум.");

/* 9 ДВЕ БАЗЫ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 4 · ПЕРВОЕ ОСЛОЖНЕНИЕ","Один и тот же портфель даёт два разных ответа: всё зависит от того, какой капитал в знаменателе",
  "Коэффициент по регуляторному и по балансовому капиталу, %");
s.addChart(p.ChartType.line,[
 {name:"По регуляторному капиталу (до 2026 года)", labels:D.labels, values:D.old},
 {name:"По балансовому капиталу (с 2026 года)",    labels:D.labels, values:D.new}],
 Object.assign({x:M,y:2.4,w:7.9,h:3.5,chartColors:[C2,C1],lineSize:2.5,lineDataSymbol:"none",
  showLegend:true,legendPos:"b",legendFontSize:10,legendFontFace:BF,
  valAxisMinVal:60,valAxisMaxVal:110},axis));
card(s,8.75,2.4,3.95,3.5,"FBEEEC");
s.addText("В чём подвох",{x:9.0,y:2.62,w:3.45,h:0.3,fontSize:10.5,bold:true,color:MUTED,fontFace:BF,isTextBox:true,margin:0,charSpacing:1});
s.addText([{text:"Разрыв между линиями — не риск.",options:{bold:true,breakLine:true,color:NAVY}},
 {text:"Это разница в правиле счёта. Портфель один и тот же.\n",options:{breakLine:true}},
 {text:"Уровень 95 % устанавливался для верхней линии.",options:{bold:true,breakLine:true,color:NAVY}},
 {text:"По ней он не был задет ни разу за 30 месяцев: максимум 84,4 %.\n",options:{breakLine:true}},
 {text:"К нижней линии его никто не пересчитывал.",options:{bold:true,breakLine:true,color:NAVY}},
 {text:"Отсюда 12 месяцев формального превышения при неизменном портфеле."}],
 {x:9.0,y:2.98,w:3.45,h:2.7,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14});
takeaway(s,"Говорить «лимит 95 % пробит» некорректно: этот уровень для нынешнего способа счёта никогда не утверждался. Пересчитать его — обязанность, а не послабление.","FBEEEC",INK);
s.addNotes("Вот здесь начинается сложное, и его надо проговорить медленно. Верхняя линия — как считали до 2026 года. Нижняя — как считаем сейчас. Портфель один. Разница между линиями — исключительно правило расчёта капитала. Уровень 95 процентов ставился к верхней линии, и она его никогда не достигала. К нижней линии этот уровень никто не пересчитывал — поэтому формально получилось превышение, которого в портфеле нет.");

/* 10 СКОРОСТЬ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 4 · ВТОРОЕ ОСЛОЖНЕНИЕ","Показатель проходит расстояние до уровня за один месяц — предупреждать поздно",
  "Изменение коэффициента месяц к месяцу, процентные пункты");
s.addChart(p.ChartType.bar,[{name:"Изменение за месяц, пп", labels:D.dlab, values:D.dval}],
 Object.assign({x:M,y:2.4,w:7.9,h:3.4,barDir:"col",chartColors:[C1],showLegend:false,
  barGapWidthPct:40},axis));
const spd=[["9,7 пп","самый большой скачок за месяц — январь 2026"],
 ["4,1 пп","типичный размах месячного изменения"],
 ["4,8 пп","всё расстояние от обычного уровня до границы 95 %"]];
spd.forEach((c,i)=>{ const y=2.4+i*1.2; card(s,8.75,y,3.95,1.05);
  s.addText(c[0],{x:9.0,y:y+0.14,w:1.5,h:0.72,fontSize:20,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0,valign:"middle"});
  s.addText(c[1],{x:10.5,y:y+0.14,w:2.0,h:0.72,fontSize:10,color:INK,fontFace:BF,isTextBox:true,margin:0,valign:"middle",lineSpacing:12.5}); });
takeaway(s,"Одно обычное месячное движение перекрывает почти всё расстояние до уровня. Поэтому жёлтая зона, поставленная близко к уровню, предупредит одновременно с пробоем — а не заранее.","FAFBFD");
s.addNotes("Второе осложнение — скорость. Обычное месячное изменение показателя около четырёх пунктов. А от привычного положения до уровня 95 процентов — меньше пяти пунктов. То есть одного обычного месяца достаточно, чтобы пройти всё расстояние. Из этого следует главный вывод по зонам: жёлтую границу нельзя ставить близко к уровню, иначе она бесполезна.");

/* 11 УРОВЕНЬ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 5 · ПРЕДЛОЖЕНИЕ","Уровень 108,6 % получается двумя независимыми расчётами — вот они полностью",
  "Ни один расчёт не использует результат другого");
card(s,M,2.35,6.0,2.5);
s.addText("Путь 1 · Перевод уровня на нынешний счёт",{x:M+0.28,y:2.5,w:5.4,h:0.3,fontSize:11.5,bold:true,color:MUTED,fontFace:BF,isTextBox:true,margin:0,charSpacing:0.8});
s.addText([{text:"Уровень",options:{color:NAVY,bold:true}},{text:" = 95 % × ( "},
 {text:"СК регуляторный ÷ СК балансовый",options:{color:C1,bold:true}},{text:" )",breakLine:true},
 {text:"на дату смены правила расчёта, 01.01.2026\n",options:{color:MUTED,breakLine:true}},
 {text:"= 95 % × ( 503 086 ÷ 439 961 ) = 95 % × 1,1435",options:{breakLine:true}},
 {text:"= 108,63 %",options:{bold:true,color:NAVY}}],
 {x:M+0.28,y:2.9,w:5.4,h:1.8,fontSize:13,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:20});
card(s,M+6.3,2.35,6.0,2.5);
s.addText("Путь 2 · Запас времени на реакцию",{x:M+6.58,y:2.5,w:5.4,h:0.3,fontSize:11.5,bold:true,color:MUTED,fontFace:BF,isTextBox:true,margin:0,charSpacing:0.8});
s.addText([{text:"Запас",options:{color:NAVY,bold:true}},{text:" = z × σ × √T = 1,2816 × 4,07 × √3 = ",},
 {text:"9,03 пп",options:{bold:true}},{text:"",breakLine:true},
 {text:"Жёлтая граница = 90-й перцентиль ряда = 99,55 %",options:{breakLine:true}},
 {text:"Уровень = 99,55 + 9,03\n",options:{breakLine:true}},
 {text:"= 108,58 %",options:{bold:true,color:NAVY}}],
 {x:M+6.58,y:2.9,w:5.4,h:1.8,fontSize:13,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:20});
s.addText([{text:"z = 1,2816",options:{bold:true}},{text:" — вероятность пробоя за три месяца не выше 10 %.   "},
 {text:"σ = 4,07 пп",options:{bold:true}},{text:" — типичное изменение показателя за месяц.   "},
 {text:"T = 3",options:{bold:true}},{text:" — квартал на подготовку и согласование мер."}],
 {x:M,y:5.0,w:W-2*M,h:0.46,fontSize:11,color:MUTED,fontFace:BF,isTextBox:true,margin:0});
card(s,M,5.52,W-2*M,0.85,"F1F5EC");
s.addText([{text:"Расхождение 0,05 пп.  ",options:{bold:true,color:GREEN}},
 {text:"Первый расчёт смотрит только на правило счёта и не знает про наши сроки. Второй смотрит только на сроки и скорость показателя и не знает про смену правила. Уровень не подобран под факт."}],
 {x:M+0.28,y:5.69,w:W-2*M-0.56,h:0.55,fontSize:12.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:16});
foot(s,"Проверка от обратного: при уровне 95 % квартал на реакцию требует жёлтой границы на 86 %, выше которой показатель находится 31 месяц из 36");
s.addNotes("Два расчёта полностью на слайде. Первый: берём утверждённые 95 процентов и переводим по соотношению двух капиталов на дату смены правила. Второй: берём 90-й перцентиль как жёлтую границу и добавляем запас на квартал. Первый ничего не знает про наши сроки, второй — про смену правила. Расходятся на пять сотых пункта.");

/* 12 ОТКУДА ГРАНИЦЫ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 5 · ЛОГИКА ЗОН","Границы не подбирались: красная — это уровень, жёлтая — уровень минус квартал хода",
  "Всего два числа, и второе получается из первого вычитанием");
const steps3=[["Красная граница","108,63 %","Это сам уровень риск-аппетита, переведённый на нынешний счёт. Выше него — превышение.",RED],
 ["Ширина жёлтой зоны","9,03 пп","Расстояние, которое показатель проходит за квартал: z × σ × √3. Это и есть запас времени на реакцию.",AMBER],
 ["Жёлтая граница","99,60 %","108,63 − 9,03. Никакого отдельного подбора: разность двух чисел выше.",AMBER],
 ["Зелёная зона","ниже 99,60 %","Обычный режим наблюдения.",GREEN]];
steps3.forEach((c,i)=>{ const x=M+i*3.08; card(s,x,2.4,2.85,2.35);
  s.addShape(p.ShapeType.ellipse,{x:x+0.24,y:2.6,w:0.3,h:0.3,fill:{color:c[3]},line:{color:c[3]}});
  s.addText(c[0],{x:x+0.62,y:2.58,w:2.1,h:0.34,fontSize:11,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0,valign:"middle"});
  s.addText(c[1],{x:x+0.24,y:3.02,w:2.4,h:0.55,fontSize:22,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0});
  s.addText(c[2],{x:x+0.24,y:3.62,w:2.4,h:1.0,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:13.5});
  if(i<3) s.addText(i===1?"−":"=",{x:x+2.87,y:3.05,w:0.2,h:0.4,fontSize:18,bold:true,color:MUTED,fontFace:BF,isTextBox:true,margin:0,align:"center"});
});
card(s,M,4.95,5.9,1.0,"F1F5EC");
s.addText([{text:"Независимая проверка. ",options:{bold:true,color:NAVY}},
 {text:"90-й перцентиль ряда равен 99,55 % — то есть граница, полученная вычитанием, совпала с границей, полученной из распределения. Расхождение 0,05 пп."}],
 {x:M+0.26,y:5.1,w:5.4,h:0.75,fontSize:11,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14});
card(s,M+6.2,4.95,5.9,1.0,"FAFBFD");
s.addText([{text:"Что это стоит. ",options:{bold:true,color:NAVY}},
 {text:"В жёлтой зоне показатель провёл бы 11,1 % времени — четыре месяца из тридцати шести. В зелёной 88,9 %. Три переключения режима за три года."}],
 {x:M+6.46,y:5.1,w:5.4,h:0.75,fontSize:11,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14});
foot(s,"Если руководство выберет другой запас времени, обе границы пересчитываются той же формулой — подбирать заново ничего не нужно");
s.addNotes("Частый вопрос: откуда взялись именно эти два числа. Ответ: число одно, второе — разность. Красная граница это уровень. Ширина жёлтой зоны это расстояние, проходимое за квартал. Жёлтая граница это их разность. Проверка: то же самое число получается из распределения ряда, и расхождение пять сотых пункта.");

/* 13 СВЕТОФОР */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 5 · СВЕТОФОР","Сегодняшние 101,5 % — жёлтая зона: схема подтверждает режим, в котором Банк уже работает",
  "Коэффициент помесячно, %; справа — шкала зон в том же масштабе");
const lim=new Array(36).fill(108.63), yel=new Array(36).fill(99.60);
s.addChart(p.ChartType.line,[
 {name:"Коэффициент", labels:D.labels, values:D.new},
 {name:"Жёлтая граница — 99,6 %", labels:D.labels, values:yel},
 {name:"Уровень — 108,6 %", labels:D.labels, values:lim}],
 Object.assign({x:M,y:2.4,w:7.55,h:3.55,chartColors:[C1,AMBER,RED],lineSize:2.5,
  lineDataSymbol:"none",showLegend:true,legendPos:"b",legendFontSize:10,legendFontFace:BF,
  valAxisMinVal:75,valAxisMaxVal:115},axis));
// шкала зон: 75..115 по высоте 3.15 дюйма
const LY=2.5, LH=3.15, vmin=75, vmax=115, LX=8.35, LW=0.5;
const yOf=v=>LY+(vmax-v)/(vmax-vmin)*LH;
[[108.63,115,RED],[99.60,108.63,AMBER],[75,99.60,GREEN]].forEach(([a,b,c])=>{
  s.addShape(p.ShapeType.rect,{x:LX,y:yOf(b),w:LW,h:yOf(a)-yOf(b),fill:{color:c},line:{color:"FFFFFF",width:1}});
});
s.addText("108,6",{x:LX-0.02,y:yOf(108.63)-0.14,w:LW+0.04,h:0.28,fontSize:8.5,bold:true,color:"FFFFFF",fontFace:BF,isTextBox:true,margin:0,align:"center",valign:"middle"});
s.addText("99,6",{x:LX-0.02,y:yOf(99.60)-0.14,w:LW+0.04,h:0.28,fontSize:8.5,bold:true,color:"FFFFFF",fontFace:BF,isTextBox:true,margin:0,align:"center",valign:"middle"});
s.addShape(p.ShapeType.rect,{x:LX-0.12,y:yOf(101.50)-0.012,w:LW+0.24,h:0.024,fill:{color:NAVY},line:{color:NAVY}});
s.addText("сейчас 101,5 %",{x:LX-1.35,y:yOf(101.50)-0.14,w:1.2,h:0.28,fontSize:9,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0,align:"right",valign:"middle"});
const zn=[["КРАСНАЯ",RED,"FBEEEC","≥ 108,6 %","еженедельно · эскалация · письменный план устранения"],
 ["ЖЁЛТАЯ",AMBER,"FDF4E3","99,6 — 108,6 %","еженедельно · разбор причины · подготовка мер заранее"],
 ["ЗЕЛЁНАЯ",GREEN,"EFF5EF","< 99,6 %","ежемесячно · действий не требуется"]];
zn.forEach((z,i)=>{ const y=2.4+i*1.22; card(s,9.05,y,3.65,1.08,z[2]);
  s.addShape(p.ShapeType.rect,{x:9.28,y:y+0.2,w:0.26,h:0.26,fill:{color:z[1]},line:{color:z[1]}});
  s.addText(z[0],{x:9.66,y:y+0.17,w:1.4,h:0.32,fontSize:11.5,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0,valign:"middle",charSpacing:0.6});
  s.addText(z[3],{x:11.0,y:y+0.17,w:1.5,h:0.32,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,valign:"middle",align:"right"});
  s.addText(z[4],{x:9.28,y:y+0.54,w:3.2,h:0.45,fontSize:10,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:12.5}); });
foot(s,"Цена: 16 отчётов в год вместо 12, три переключения режима за три года, 11,1 % времени в жёлтой зоне");
s.addNotes("Слева ряд, справа шкала зон в том же масштабе — видно, где мы находимся. Сегодняшняя точка отмечена на шкале. Обратите внимание: схема не вводит новый режим, а описывает правилом тот, в котором Банк работает уже сейчас.");

/* 13 СЛЕПОЕ ПЯТНО */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 5 · ЧЕГО ЗОНЫ НЕ ВИДЯТ","Январский скачок сделал капитал, а не портфель — зона по уровню такое не предупреждает",
  "Из чего сложился рост коэффициента, процентные пункты");
s.addChart(p.ChartType.bar,[
 {name:"Вклад портфеля (задолженность топ-20)", labels:["декабрь 2025 → январь 2026","март → июль 2026"], values:[2.11,11.95]},
 {name:"Вклад капитала",                        labels:["декабрь 2025 → январь 2026","март → июль 2026"], values:[7.41,1.45]}],
 Object.assign({x:M,y:2.4,w:6.5,h:3.4,barDir:"col",barGrouping:"stacked",chartColors:[C1,C2],
  showLegend:true,legendPos:"b",legendFontSize:10,legendFontFace:BF,showValue:true,
  dataLabelPosition:"ctr",dataLabelFontSize:11,dataLabelColor:"FFFFFF",dataLabelFontBold:true,
  dataLabelFontFace:BF,barGapWidthPct:90},axis));
card(s,7.45,2.4,5.25,1.4,"FBEEEC");
s.addText("Почему это важно",{x:7.72,y:2.58,w:4.7,h:0.28,fontSize:11.5,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0});
s.addText("В январе капитал упал на 7,9 % за месяц, и показатель прошёл от 86 до 96 % одним шагом. Никакая жёлтая граница выше 86 % не дала бы предупреждения — а 86 % ниже обычного положения показателя.",
 {x:7.72,y:2.9,w:4.7,h:0.82,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:13.5});
s.addText("Поэтому — два дополнительных сигнала",{x:7.45,y:4.0,w:5.25,h:0.3,fontSize:13,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0});
[["Капитал упал более чем на 3 % за месяц","сработал бы 2 раза за 36 месяцев, январь пойман"],
 ["Задолженность топ-20 выросла более чем на 5 % за месяц","сработал бы 5 раз, каждый раз перед подъёмом показателя"]]
 .forEach((t,i)=>{ const y=4.4+i*1.0; card(s,7.45,y,5.25,0.9);
  s.addText(t[0],{x:7.72,y:y+0.12,w:4.7,h:0.3,fontSize:11,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0});
  s.addText(t[1],{x:7.72,y:y+0.44,w:4.7,h:0.36,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:13}); });
foot(s,"Срабатывание любого из двух сигналов переводит показатель в жёлтый режим на два месяца независимо от его уровня");
s.addNotes("Важное ограничение, которое лучше назвать самим, чем услышать в вопросе. Зона по уровню видит только сам уровень. Январь она бы пропустила, потому что там двигался знаменатель. Поэтому предлагаем два простых сигнала на резкое движение — по капиталу и по задолженности. Оба проверены на трёхлетнем ряде.");

/* 15 МЕРЫ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 6 · МЕРЫ","Смысл жёлтой зоны — начать готовить меры заранее, а не после пробоя",
  "Условия входа и выхода, что делаем в каждой зоне");
s.addTable([
 [{text:"",options:{fill:{color:"FFFFFF"}}},
  {text:"ЗЕЛЁНАЯ",options:{bold:true,color:"FFFFFF",fill:{color:GREEN}}},
  {text:"ЖЁЛТАЯ",options:{bold:true,color:"FFFFFF",fill:{color:AMBER}}},
  {text:"КРАСНАЯ",options:{bold:true,color:"FFFFFF",fill:{color:RED}}}],
 [{text:"Условие входа",options:{bold:true}},"ниже 99,6 % два месяца подряд",
  "99,6 % и выше — либо срабатывание любого из двух сигналов ниже","108,6 % и выше"],
 [{text:"Условие выхода",options:{bold:true}},"—",
  "два месяца подряд ниже 99,6 % (или два месяца после сигнала)","два месяца подряд ниже 108,6 %"],
 [{text:"Как часто смотрим",options:{bold:true}},"раз в месяц","раз в неделю","раз в неделю и вне очереди при сигнале"],
 [{text:"Что показываем",options:{bold:true}},"значение и запас до жёлтой границы",
  "+ из чего сложилось движение: портфель или капитал","+ динамика обеих составляющих за год"],
 [{text:"Что раскрываем",options:{bold:true}},"—",
  "пять групп с наибольшим приростом; изменение обеспечения и капитала",
  "+ какие группы нужно вывести, чтобы вернуться под уровень, и насколько это исполнимо"],
 [{text:"Кого извещаем",options:{bold:true}},"—","руководителя БРМ, три рабочих дня",
  "КУР немедленно, Правление на ближайшем заседании"],
 [{text:"Что делаем",options:{bold:true}},"ничего","готовим проект мер, выносим на КУР в 20 рабочих дней",
  "письменный план устранения со сроком и ответственным"],
 [{text:"Когда идём на СД",options:{bold:true}},"—","—","дольше квартала или повтор в течение года"]],
 {x:M,y:2.35,w:W-2*M,colW:[1.85,2.55,3.85,3.85],rowH:0.4,fontSize:10,fontFace:BF,color:INK,
  border:{type:"solid",color:LINE,pt:0.75},align:"left",valign:"middle",fill:{color:"FFFFFF"},margin:0.06});
card(s,M,5.72,W-2*M,1.1,"FDF4E3");
s.addText("Два сигнала на резкое движение — действуют в любой зоне, в том числе в зелёной",
 {x:M+0.26,y:5.85,w:11.5,h:0.28,fontSize:11.5,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0});
s.addText([{text:"Капитал упал более чем на 3 % за месяц",options:{bold:true}},
 {text:" — сработал бы 2 раза за три года, январь пойман.    "},
 {text:"Задолженность топ-20 выросла более чем на 5 % за месяц",options:{bold:true}},
 {text:" — сработал бы 5 раз, каждый раз перед подъёмом показателя.    Срабатывание переводит в жёлтый режим на два месяца независимо от уровня."}],
 {x:M+0.26,y:6.16,w:11.5,h:0.55,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14});
s.addNotes("Таблица читается сверху вниз: сначала при каком условии попадаем в зону, потом при каком выходим, потом что делаем. Выход требует двух месяцев подряд — чтобы режим не дребезжал на одном колебании. Внизу два сигнала: они работают всегда, даже когда показатель в зелёной зоне, потому что зона по уровню не видит резких движений знаменателя.");

/* 16 ПЕРЕЧЕНЬ ПРЕДЛОЖЕНИЙ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 6 · ЧТО ИМЕННО ПРЕДЛАГАЕТСЯ","Восемь предложений и три условия, при которых они выносятся",
  "Формулировки готовы для протокола: каждая — отдельный пункт решения");
s.addTable([
 [{text:"№",options:{bold:true}},{text:"Предложение",options:{bold:true}},{text:"Статус",options:{bold:true}}],
 ["П1","Перевести уровень концентрации топ-20 на действующую базу расчёта капитала","на решение — число зависит от даты перевода"],
 ["П2","Установить сигнальный уровень (жёлтую границу) как уровень минус запас времени на реакцию","на решение — зависит от выбранного запаса"],
 ["П3","Ввести три зоны с закреплённой частотой наблюдения в каждой","предлагается"],
 ["П4","Ввести два сигнала на резкое движение: капитал −3 %, задолженность +5 % за месяц","предлагается"],
 ["П5","Ввести условие выхода из зоны: два наблюдения подряд ниже границы","предлагается"],
 ["П6","Закрепить лестницу мер, включая подготовку проекта мер уже в жёлтой зоне","предлагается"],
 ["П7","Вести уровень как ряд с датой начала действия, а не как одно число","предлагается"],
 ["П8","Базовую частоту наблюдения устанавливать по метрике; зона повышает её на одну ступень","на решение — см. вопрос о частоте"]],
 {x:M,y:2.3,w:W-2*M,colW:[0.7,7.4,4.0],rowH:0.42,fontSize:10.5,fontFace:BF,color:INK,
  border:{type:"solid",color:LINE,pt:0.75},align:"left",valign:"middle",fill:{color:"FFFFFF"},margin:0.06});
s.addText("Условия, без которых предложение выносить нельзя",{x:M,y:6.06,w:9,h:0.3,fontSize:13,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0});
s.addText([{text:"У1 ",options:{bold:true,color:NAVY}},{text:"На уполномоченный орган выносятся обе картины: факт против прежнего уровня и против переведённого.    "},
 {text:"У2 ",options:{bold:true,color:NAVY}},{text:"Дата перевода фиксируется правилом до того, как посмотрели на факт.    "},
 {text:"У3 ",options:{bold:true,color:NAVY}},{text:"Длительность цикла согласования подтверждается документально, а не оценкой."}],
 {x:M,y:6.4,w:W-2*M,h:0.5,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14});
s.addNotes("Это тот слайд, который можно переложить в протокол дословно. Восемь пунктов: три из них требуют решения, потому что зависят от развилок, пять предлагаются как есть. Внизу три условия — они не про содержание, а про порядок вынесения. Без первого условия предложение читается как попытка ослабить лимит.");

/* 17 ДАТА ПЕРЕВОДА */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 7 · РЕШЕНИЕ ПЕРВОЕ","На какую дату переводить уровень — это как выбрать курс дня для перевода суммы в другую валюту",
  "Одна и та же величина 95 % в новой системе счёта выражается разным числом");
card(s,M,2.3,W-2*M,0.92,"FAFBFD");
s.addText([{text:"В чём вопрос. ",options:{bold:true,color:NAVY}},
 {text:"Уровень 95 % утверждён для регуляторного капитала. Чтобы выразить ту же величину для балансового, её умножают на соотношение двух капиталов. Но это соотношение не постоянно: за три года оно менялось с 1,2835 до 1,1435. Значит результат перевода зависит от того, на какую дату берётся соотношение — ровно как сумма в валюте зависит от курса дня."}],
 {x:M+0.28,y:2.46,w:W-2*M-0.56,h:0.65,fontSize:12,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:15.5});
s.addTable([
 [{text:"Дата, на которую берём соотношение",options:{bold:true}},
  {text:"СК регуляторный",options:{bold:true}},{text:"СК балансовый",options:{bold:true}},
  {text:"Соотношение",options:{bold:true}},{text:"Уровень",options:{bold:true}},
  {text:"Жёлтая граница",options:{bold:true}}],
 ["Август 2023 — начало наблюдений","413 937","322 505","1,2835","121,93 %","112,91 %"],
 ["Февраль 2024 — как записано в реестре","453 740","364 498","1,2448","118,26 %","109,23 %"],
 [{text:"Январь 2026 — дата смены правила",options:{bold:true,color:NAVY}},
  {text:"503 086",options:{bold:true}},{text:"439 961",options:{bold:true}},
  {text:"1,1435",options:{bold:true}},{text:"108,63 %",options:{bold:true,color:NAVY}},
  {text:"99,60 %",options:{bold:true,color:NAVY}}]],
 {x:M,y:3.4,w:W-2*M,colW:[4.2,1.7,1.7,1.5,1.5,1.5],rowH:0.48,fontSize:10.5,fontFace:BF,color:INK,
  border:{type:"solid",color:LINE,pt:0.75},align:"left",valign:"middle",fill:{color:"FFFFFF"},margin:0.06});
card(s,M,5.35,6.0,1.35,"F1F5EC");
s.addText("Почему рекомендуется январь 2026",{x:M+0.26,y:5.5,w:5.5,h:0.28,fontSize:11.5,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0});
s.addText("Это дата, когда изменилась сама система измерения. Перевод по курсу того дня, когда сменилась единица, — единственный вариант, который объясняется правилом, а не удобством. Он же даёт самый строгий из трёх уровней.",
 {x:M+0.26,y:5.82,w:5.5,h:0.8,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:13.5});
card(s,M+6.3,5.35,6.0,1.35,"FBEEEC");
s.addText("Чем это атакуют",{x:M+6.56,y:5.5,w:5.5,h:0.28,fontSize:11.5,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0});
s.addText("Любой перевод повышает число и снимает текущее превышение. Защита одна: дата выбирается по правилу до того, как посмотрели на факт, и на орган выносятся обе картины. Иначе это читается как подгонка.",
 {x:M+6.56,y:5.82,w:5.5,h:0.8,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:13.5});
s.addNotes("Самый частый вопрос — что означают три числа. Объясняю через валюту. У нас есть сумма в старых единицах: 95 процентов. Мы переводим её в новые. Курс перевода — соотношение двух капиталов — меняется во времени. По курсу августа 2023 получается 121,9. По курсу февраля 2024 — 118,3. По курсу января 2026 — 108,6. Сумма одна, число разное. Рекомендуем курс того дня, когда сменилась единица измерения, то есть январь 2026.");

/* 18 ВОПРОСЫ НА ВСТРЕЧУ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 7 · РЕШЕНИЯ ВТОРОЕ И ТРЕТЬЕ","Два вопроса выносятся на отдельную встречу: они не расчётные, а организационные");
card(s,M,2.3,6.0,2.65);
num(s,M+0.26,2.5,2);
s.addText("Сколько времени нужно на реакцию",{x:M+0.82,y:2.5,w:4.9,h:0.4,fontSize:14,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0,valign:"middle"});
s.addText([{text:"Квартал",options:{bold:true}},{text:" → жёлтая 99,6 %, режим 11 % времени\n",options:{breakLine:true}},
 {text:"Два месяца",options:{bold:true}},{text:" → 101,3 %, режим 6 % времени\n",options:{breakLine:true}},
 {text:"Месяц",options:{bold:true}},{text:" → 103,4 %, режим 3 % времени\n\n",options:{breakLine:true}},
 {text:"Чей вопрос: ",options:{bold:true,color:MUTED}},
 {text:"руководителей — сроки согласования перед заместителями председателя их зона ответственности. Сокращается предварительным согласованием мер."}],
 {x:M+0.28,y:3.02,w:5.4,h:1.88,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14});
card(s,M+6.3,2.3,6.0,2.65);
num(s,M+6.56,2.5,3);
s.addText("Как часто наблюдаем",{x:M+7.12,y:2.5,w:4.9,h:0.4,fontSize:14,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0,valign:"middle"});
s.addText([{text:"Еженедельный расчёт возможен ровно по одной метрике из двенадцати.",options:{bold:true,breakLine:true,color:NAVY}},
 {text:"Топ-20 — недельный ряд ведётся с 2016 года, переход ничего не стоит.\n",options:{breakLine:true}},
 {text:"Остальные одиннадцать (EL × 4, PD × 5, CoR × 2) приходят из месячных источников. Еженедельно — это не вопрос формата, а пересборка расчёта в источнике.\n\n",options:{breakLine:true}},
 {text:"Чей вопрос: ",options:{bold:true,color:MUTED}},
 {text:"технический — владельцев расчёта и источников данных."}],
 {x:M+6.58,y:3.02,w:5.4,h:1.88,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14});
card(s,M,5.02,W-2*M,1.80,"F1F5EC");
s.addText("Предложение по частоте, снимающее узкое место (П8)",{x:M+0.28,y:5.14,w:11.5,h:0.3,fontSize:13,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0});
s.addText("Не требовать одинаковой частоты от всех метрик. Базовая частота — та, с которой приходят данные. Зона повышает её на одну ступень по лестнице «квартал → месяц → неделя».",
 {x:M+0.28,y:5.46,w:11.5,h:0.46,fontSize:11.5,color:INK,fontFace:BF,isTextBox:true,margin:0});
s.addTable([
 [{text:"Метрика",options:{bold:true}},{text:"Зелёная",options:{bold:true}},{text:"Жёлтая",options:{bold:true}},{text:"Красная",options:{bold:true}},{text:"Что для этого нужно",options:{bold:true}}],
 ["Концентрация топ-20","месяц","неделя","неделя + вне очереди","ничего: ряд уже недельный"],
 ["EL × 4, PD × 5, CoR × 2","квартал","месяц","месяц + вне очереди","месячная выгрузка уже есть; недельная не требуется"]],
 {x:M+0.28,y:5.96,w:11.5,colW:[3.0,1.6,1.6,2.3,3.0],rowH:0.28,fontSize:10,fontFace:BF,color:INK,
  border:{type:"solid",color:LINE,pt:0.75},align:"left",valign:"middle",fill:{color:"FFFFFF"},margin:0.05});
s.addNotes("Здесь мы ничего не решаем сами. Второй вопрос — про сроки, это зона ответственности руководителей, потому что защищать сроки перед заместителями председателя им. Третий — технический. И по нему у нас есть ответ, снимающий узкое место: не надо требовать недели от всех двенадцати метрик. Недельные данные есть только по топ-20. По остальным достаточно поднять частоту с квартала до месяца — а месячная выгрузка уже существует.");

/* 19 ЧТО МЕНЯТЬ В ДОКУМЕНТАХ */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 7 · ДОКУМЕНТЫ","Что придётся изменить: четыре документа, и в двух из них закрывается давний пробел",
  "Реквизиты действующих редакций — по карте документов контура");
s.addTable([
 [{text:"Документ",options:{bold:true}},{text:"Что меняется",options:{bold:true}},
  {text:"Пункт",options:{bold:true}},{text:"Кто утверждает",options:{bold:true}}],
 [{text:"Приложение № 3 к Политике",options:{bold:true}},
  "Само число уровня; новые строки: сигнальный уровень, зона, база расчёта, дата начала действия",
  "числовые уровни","СД по представлению Правления"],
 [{text:"Политика определения аппетита к риску",options:{bold:true}},
  "Лестница мер и частота наблюдения по зонам — сейчас конкретных мер и сроков нет",
  "п. 12-1 и п. 27 — пробел","СД, пятая редакция от 29.12.2023"],
 [{text:"Приложение № 2 к Методике",options:{bold:true}},
  "Добавление топ-20 в перечень метрик с пределами — сейчас предлимиты только по 8 из 25",
  "пределы уровней (триггеры)","СД"],
 [{text:"Методика / отдельный документ",options:{bold:true}},
  "Порядок расчёта метрик вне ACARI и ALRI — сейчас документа нет ни в одном из полученных",
  "пробел, п. 17 № 86","СД"]],
 {x:M,y:2.4,w:W-2*M,colW:[3.3,5.4,2.2,2.2],rowH:0.62,fontSize:10.5,fontFace:BF,color:INK,
  border:{type:"solid",color:LINE,pt:0.75},align:"left",valign:"middle",fill:{color:"FFFFFF"},margin:0.06});
card(s,M,5.35,W-2*M,1.3,"F1F5EC");
s.addText("Побочный выигрыш",{x:M+0.28,y:5.5,w:11.5,h:0.28,fontSize:12,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0});
s.addText("Две строки таблицы закрывают пробелы, отмеченные в контуре независимо от этой задачи: отсутствие конкретных мер и сроков при нарушении (Политика п. 12-1 и 27) и отсутствие документа о порядке расчёта 23 метрик из 25. То есть пересмотр уровня даёт повод закрыть и их — одним пакетом вместо трёх.",
 {x:M+0.28,y:5.82,w:11.5,h:0.7,fontSize:11,color:INK,fontFace:BF,isTextBox:true,margin:0,lineSpacing:14.5});
s.addNotes("Четыре документа. Первый — само число. Второй — меры и частота, и там сейчас прямой пробел: написано, что при нарушении что-то происходит, но что именно и в какие сроки — не указано. Третий — перечень метрик с пределами. Четвёртый — методика расчёта, которой на 23 метрики из 25 просто нет. Последние два пробела зафиксированы у нас независимо от этой задачи, и разумно закрыть их одним пакетом.");

/* 16 ПЛАН */
s=p.addSlide(); s.background={color:BG};
head(s,"ШАГ 7 · ПЛАН","К 30 сентября — записка с уровнем и зонами; к 31 декабря — предложения на уполномоченный орган");
s.addTable([
 [{text:"Срок",options:{bold:true}},{text:"Что делаем",options:{bold:true}},
  {text:"Что получается на выходе",options:{bold:true}},{text:"Кто",options:{bold:true}}],
 [{text:"30.09.2026",options:{bold:true,color:NAVY}},"Анализ актуальности действующих уровней","Записка: уровень, зоны, меры, обе картины по базам","БРМ"],
 [{text:"31.12.2026",options:{bold:true,color:NAVY}},"Предложения по сохранению либо изменению уровней","Материалы на уполномоченный орган, выписка","БРМ, УО"],
 [{text:"1 кв. 2027",options:{bold:true,color:NAVY}},"Два недостающих уровня риск-аппетита","Отдельный пакет по плану мероприятий","БРМ"]],
 {x:M,y:2.3,w:W-2*M,colW:[1.6,4.2,4.7,1.6],rowH:0.5,fontSize:11,fontFace:BF,color:INK,
  border:{type:"solid",color:LINE,pt:0.75},align:"left",valign:"middle",fill:{color:"FFFFFF"},margin:0.07});
s.addText("Что нужно получить, чтобы записка опиралась на документ, а не на пересказ",
 {x:M,y:4.25,w:9,h:0.35,fontSize:14,bold:true,color:NAVY,fontFace:HF,isTextBox:true,margin:0});
[["Акт службы внутреннего аудита","Чтобы формулировка замечания цитировалась дословно","Внутренний аудит"],
 ["Основание смены правила расчёта капитала","Реквизиты решения о переходе с 01.01.2026 — от него зависит дата перевода уровня","Финансовый блок"],
 ["Фактические сроки согласования","Сегодня длительность этапов — экспертная оценка; нужна проверяемая","БРМ, секретариат"]]
 .forEach((n,i)=>{ const y=4.7+i*0.72; card(s,M,y,W-2*M,0.62);
  s.addText(n[0],{x:M+0.28,y:y+0.08,w:3.6,h:0.46,fontSize:11,bold:true,color:NAVY,fontFace:BF,isTextBox:true,margin:0,valign:"middle"});
  s.addText(n[1],{x:M+4.0,y:y+0.08,w:6.1,h:0.46,fontSize:10.5,color:INK,fontFace:BF,isTextBox:true,margin:0,valign:"middle",lineSpacing:13});
  s.addText(n[2],{x:M+10.25,y:y+0.08,w:1.75,h:0.46,fontSize:10.5,color:MUTED,fontFace:BF,isTextBox:true,margin:0,valign:"middle",align:"right"}); });
foot(s,"Все расчёты воспроизводимы одной командой; ряд и скрипты — в рабочем пространстве контура");
s.addNotes("Заканчиваем тем, что нужно от коллег. Три документа. Без первых двух записка будет опираться на пересказ, а не на документ, и это заметят.");

p.writeFile({fileName:"RA_top20_zones.pptx"}).then(f=>console.log("собрано:", f));

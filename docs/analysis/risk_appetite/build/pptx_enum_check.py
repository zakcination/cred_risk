#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Проверка перечислимых значений в графиках .pptx.

Зачем отдельный скрипт. Штатный валидатор схемы пропускает целый класс дефектов:
если в опцию, ожидающую одно значение, передан массив, генератор пишет в атрибут
строку вида val="solid,dash,dash". Схема этого не ловит — атрибут остаётся строкой, —
а PowerPoint отвергает файл целиком с сообщением «обнаружена проблема с содержимым».
Ровно так и произошло 08.09.2026 с первой сборкой деки.

Запуск: python3 pptx_enum_check.py deck.pptx      (код возврата 1 при находке)
"""
import re, sys, zipfile

ENUM = {
    "prstDash": {"solid","dot","dash","lgDash","dashDot","lgDashDot","lgDashDotDot",
                 "sysDash","sysDot","sysDashDot","sysDashDotDot"},
    "dLblPos":  {"bestFit","b","ctr","inBase","inEnd","l","outEnd","r","t"},
    "barDir":   {"bar","col"},
    "grouping": {"clustered","percentStacked","stacked","standard"},
    "legendPos":{"b","tr","l","r","t"},
    "symbol":   {"circle","dash","diamond","dot","none","plus","square","star",
                 "triangle","x","auto"},
    "orientation": {"maxMin","minMax"},
    "tickLblPos":  {"high","low","nextTo","none"},
    "crosses":     {"autoZero","max","min"},
}
# на накопительной диаграмме допустимы только эти позиции подписи
STACKED_OK = {"ctr","inEnd","inBase"}


def check(path):
    bad = []
    with zipfile.ZipFile(path) as z:
        parts = [n for n in z.namelist() if n.startswith("ppt/charts/") and n.endswith(".xml")]
        for n in parts:
            x = z.read(n).decode("utf-8", "replace")
            for tag, valid in ENUM.items():
                for m in re.finditer(r'<[ac]:%s val="([^"]*)"' % tag, x):
                    v = m.group(1)
                    if v not in valid:
                        bad.append("%s: <%s val=\"%s\"> — недопустимое значение" % (n, tag, v))
            for blk in re.findall(r"<c:barChart>.*?</c:barChart>", x, re.S):
                g = re.search(r'<c:grouping val="([^"]*)"', blk)
                if g and g.group(1) in ("stacked", "percentStacked"):
                    for p in re.findall(r'<c:dLblPos val="([^"]*)"', blk):
                        if p not in STACKED_OK:
                            bad.append("%s: dLblPos=\"%s\" на накопительной диаграмме — "
                                       "PowerPoint отвергнет файл" % (n, p))
        print("проверено частей с графиками: %d" % len(parts))
    if bad:
        print("НАЙДЕНО %d нарушений:" % len(bad))
        for b in bad:
            print("  " + b)
        return 1
    print("перечислимые значения в графиках корректны")
    return 0


if __name__ == "__main__":
    sys.exit(check(sys.argv[1] if len(sys.argv) > 1 else "deck.pptx"))

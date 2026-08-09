#!/usr/bin/env python3
"""Структурная проверка SQL-скриптов ПЕРЕД отдачей на прогон.

Зачем. 09.08 в L2B уехал на прогон файл с закрывающим `*/` без открывающего:
при правке комментария три строки русского текста оказались голым SQL. Прогон
упал с `Msg 102 Incorrect syntax near 'Флаг'`, а вторая ошибка на `'<'` была
каскадом от первой. Прежняя проверка считала только скобки и кавычки И ДЕЛАЛА
ЭТО ПОСЛЕ вырезания комментариев — то есть физически не могла увидеть дефект
в самих комментариях.

Что ловит (машиной состояний за один проход, не регулярками):
  1. Незакрытые `/*` и лишние `*/` — класс ошибки выше.
  2. Голый текст сразу после закрытия шапки комментария — подпись той же
     ошибки, когда правка вставила строки мимо блока.
  3. Незакрытый строковый литерал.
  4. Дисбаланс скобок вне комментариев и строк.
  5. Двухчастные имена объектов и `INFORMATION_SCHEMA` без БД — они молча
     резолвятся в текущую БД сессии (по умолчанию `CL_PORTFOLIO`), а
     `INFORMATION_SCHEMA` при этом вернёт 0 строк БЕЗ ошибки.
  6. Отдельно, как ПРЕДУПРЕЖДЕНИЕ: отсутствие `OPTION (MAXDOP 1)`. Скрипты
     stage3/b3b написаны до этого правила и отработали как есть — смешивать
     их с ошибками структуры нельзя, иначе список FAIL перестают читать.

Чего НЕ ловит: семантику, имена колонок, `Msg 130`/`Msg 207`. Для имён есть
батч-0 аудит схемы внутри самих скриптов.

Запуск:  python3 sql/check_sql_structure.py [файл ...]
         без аргументов — все sql/*.sql
Код возврата 1, если найдены дефекты.
"""
import re
import sys
import glob


def scan(text):
    """Машина состояний: комментарии, строки, скобки — за один проход.

    Регулярками это не делается: `.replace("''", "")` ломается на `N''`
    (пустой литерал против экранированного апострофа), и проверка выдаёт
    ложный дисбаланс. Именно так `risk_dwh_layered_check.sql` — файл, который
    успешно отработал на живой базе, — был помечен как битый. Ложная тревога
    в проверке хуже её отсутствия: она приучает игнорировать вывод.
    """
    i = depth = paren = 0
    line = 1
    instr = False
    stray_close, extra_paren, str_line = [], [], 0
    while i < len(text):
        ch = text[i]
        if ch == '\n':
            line += 1
        if instr:                      # внутри строкового литерала
            if ch == "'":
                if text[i + 1:i + 2] == "'":   # экранированный апостроф
                    i += 2
                    continue
                instr = False
            i += 1
            continue
        if text[i:i + 2] == '/*':
            depth += 1
            i += 2
            continue
        if text[i:i + 2] == '*/':
            depth -= 1
            if depth < 0:
                stray_close.append(line)
                depth = 0
            i += 2
            continue
        if depth:                      # внутри блочного комментария
            i += 1
            continue
        if text[i:i + 2] == '--':
            j = text.find('\n', i)
            i = len(text) if j < 0 else j
            continue
        if ch == "'":
            instr, str_line = True, line
            i += 1
            continue
        if ch == '(':
            paren += 1
        elif ch == ')':
            paren -= 1
            if paren < 0:
                extra_paren.append(line)
                paren = 0
        i += 1
    return {
        'stray_close': stray_close, 'unclosed_comment': depth,
        'unterminated_string': str_line if instr else 0,
        'unbalanced_paren': paren, 'extra_paren': extra_paren,
    }


def strip_for_scan(text):
    """Убирает комментарии и строковые литералы, оставляя только код."""
    out, depth, i, instr = [], 0, 0, False
    while i < len(text):
        if instr:
            if text[i] == "'":
                if text[i + 1:i + 2] == "'":
                    i += 2
                    continue
                instr = False
            i += 1
            continue
        if text[i:i + 2] == '/*':
            depth += 1
            i += 2
            continue
        if text[i:i + 2] == '*/':
            depth = max(0, depth - 1)
            i += 2
            continue
        if depth:
            i += 1
            continue
        if text[i:i + 2] == '--':
            j = text.find('\n', i)
            i = len(text) if j < 0 else j
            continue
        if text[i] == "'":
            instr = True
            i += 1
            continue
        out.append(text[i])
        i += 1
    return ''.join(out)


def check(path):
    text = open(path, encoding='utf-8', errors='replace').read()
    problems = []
    r = scan(text)

    if r['stray_close']:
        problems.append(f"лишний */ без открывающего, строки: {r['stray_close']}")
    if r['unclosed_comment']:
        problems.append(f"незакрытых /*: {r['unclosed_comment']}")
    if r['unterminated_string']:
        problems.append(f"незакрытый строковый литерал, открыт на строке {r['unterminated_string']}")
    if r['unbalanced_paren']:
        problems.append(f"незакрытых скобок: {r['unbalanced_paren']}")
    if r['extra_paren']:
        problems.append(f"лишняя ) на строках: {r['extra_paren']}")

    # В T-SQL НЕТ булева типа: предикат нельзя сравнить с предикатом.
    # `(a <= 1) <> (b <= 1)` даёт `Msg 102 Incorrect syntax near '<'` —
    # ровно так упал L2A 09.08. Разворачивать через CASE ... THEN 1 ELSE 0 END.
    code_only = strip_for_scan(text)
    for m in re.finditer(r'\)\s*(?:<>|!=|=)\s*\(\s*[\w.\[\]]+\s*(?:<=|>=|<|>|=)\s',
                         code_only):
        problems.append(
            'сравнение предиката с предикатом вида `(a <= 1) <> (b <= 1)` — '
            'в T-SQL нет булева типа, нужен CASE ... THEN 1 ELSE 0 END')
        break

    # Двухчастное имя объекта зависит от ТЕКУЩЕЙ БД сессии. Подключение в
    # проекте по умолчанию — CL_PORTFOLIO, а объекты лежат в Dictionaries.
    # Самый коварный случай — INFORMATION_SCHEMA: в чужой БД он вернёт НОЛЬ
    # строк БЕЗ ошибки, то есть аудит схемы «отработает» и ничего не покажет.
    for m in re.finditer(r'(?<![\].])\[risk_analytics\]\.', code_only):
        problems.append('двухчастное имя `[risk_analytics].[…]` — зависит от '
                        'текущей БД; нужно `[Dictionaries].[risk_analytics].[…]`')
        break
    for m in re.finditer(r'(?<![\].])\bINFORMATION_SCHEMA\.', code_only):
        problems.append('`INFORMATION_SCHEMA` без имени БД — в чужой БД вернёт '
                        '0 строк БЕЗ ошибки; нужно `[Dictionaries].INFORMATION_SCHEMA.`')
        break

    # Голый текст сразу после закрытия шапки комментария — подпись правки,
    # вставленной мимо блока (ровно так уехал L2B 09.08).
    for m in re.finditer(r'=\*/[ \t]*\n[ \t]+[А-Яа-яA-Za-z]', text):
        problems.append(
            f"строка {text[:m.start()].count(chr(10)) + 2}: текст сразу после */ "
            f"— вероятно, правка вставлена мимо блока комментария")

    return problems


def check_maxdop(path):
    """Отдельно и как ПРЕДУПРЕЖДЕНИЕ: скрипты stage3/b3b написаны до правила
    MAXDOP 1 и отработали как есть. Смешивать это с ошибками структуры нельзя —
    иначе список FAIL перестают читать."""
    text = open(path, encoding='utf-8', errors='replace').read()
    if re.search(r'(?im)^\s*SELECT\s', text) and not re.search(
            r'OPTION\s*\(\s*MAXDOP\s+1\s*\)', text, re.I):
        return ['нет OPTION (MAXDOP 1) — правило CLAUDE.md']
    return []


def main():
    files = sys.argv[1:] or sorted(glob.glob('sql/*.sql'))
    bad, warned = 0, []
    for f in files:
        problems = check(f)
        if problems:
            bad += 1
            print(f'FAIL {f}')
            for p in problems:
                print(f'     - {p}')
        else:
            print(f'ok   {f}')
        if check_maxdop(f):
            warned.append(f)
    if warned:
        print('\nПРЕДУПРЕЖДЕНИЕ (не блокирует): без OPTION (MAXDOP 1) — '
              + ', '.join(x.split('/')[-1] for x in warned))
    print(f'\n{bad} файл(ов) с дефектами структуры' if bad
          else '\nСтруктура всех файлов корректна')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())

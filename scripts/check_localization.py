#!/usr/bin/env python3
"""Checks the translation tables against the code.

Every text passed to tr("…") or trCount("…") in Swift sources must have a Russian translation in
Sources/KuzmemoCore/Resources/ru.lproj/Localizable.strings (English is the source language and needs no entry, except
for plural forms), and every entry of the tables must still be used. A translation may not use a placeholder its English
key lacks, and a call must pass as many arguments as its text has placeholders (`String(format:)` with too few
arguments reads garbage). A stored static or global property, or the first value of a @State, must not call tr(): it would
keep the language of its first use after the person switches languages (make it a computed property, or keep only what the
person typed and fall back to a computed default). Exit status 1 when something is missing, unused or inconsistent.

    scripts/check_localization.py [--prune]      (--prune deletes unused entries from both tables)
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfeEgGcCsSp])")
TABLES = ROOT / "Sources/KuzmemoCore/Resources"
CALL = re.compile(r'\b(tr|trCount)\(\s*"((?:[^"\\\n]|\\.)*)"')
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$', re.M)
RU_PLURALS = ("one", "few", "many", "other")
EN_PLURALS = ("one", "other")


def unescape(text):
    return text.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")


def load(path):
    return {unescape(k): unescape(v) for k, v in ENTRY.findall(path.read_text())}


def placeholders(text):
    """The number of distinct arguments a format string consumes, and its sorted specifier list."""
    text = text.replace("%%", "")
    found = SPEC.findall(text)
    positions = {int(n) for n, _ in found if n}
    count = max(positions) if positions else len(found)
    return count, sorted(spec for _, spec in found)


def argument_count(source, start):
    """Top-level arguments of the call whose text begins right after the key literal (`, a, b)` or `)`)."""
    depth, args, i, n, current = 0, 0, start, len(source), ""
    while i < n:
        c = source[i]
        if c == '"':  # skip a string literal, including \( ... ) interpolations
            i += 1
            while i < n and source[i] != '"':
                if source[i] == "\\":
                    i += 1
                    if i < n and source[i] == "(":
                        nested = 1
                        i += 1
                        while i < n and nested:
                            nested += {"(": 1, ")": -1}.get(source[i], 0)
                            i += 1
                        continue
                i += 1
            current += "x"
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return args if (current.strip() or args == 0) else args - 1
            depth -= 1
        elif c == "," and depth == 0:
            args += 1
            current = ""
        elif not c.isspace():
            current += c
        i += 1
    return None


STORED = re.compile(r"^\s*(?:(?:private|fileprivate|public|internal)\s+)?(?:nonisolated\s+)?(?:static\s+)?(?:let|var)\s+\w+[^=\n{]*=\s*(.*)$")
STATE = re.compile(r"^\s*@(?:State|StateObject|SceneStorage)\b[^=\n]*=\s*(.*)$")
LOCALIZED = re.compile(r"\b(?:tr|trCount|Wording\.\w+)\(")


def frozen_texts():
    """Stored static or global properties, and @State first values, that call tr()/Wording: they keep their first language."""
    found = []
    for source in sorted((ROOT / "Sources").rglob("*.swift")):
        lines = source.read_text().splitlines()
        for number, line in enumerate(lines):
            m = STORED.match(line)
            if not m or not (re.search(r"\bstatic\b", line) or len(line) - len(line.lstrip()) == 0):
                m = STATE.match(line)
                if not m:
                    continue
            text = m.group(1)
            depth = sum(text.count(c) for c in "([{") - sum(text.count(c) for c in ")]}")
            end = number + 1
            while depth > 0 and end < len(lines):
                text += "\n" + lines[end]
                depth += sum(lines[end].count(c) for c in "([{") - sum(lines[end].count(c) for c in ")]}")
                end += 1
            if LOCALIZED.search(text):
                found.append((source.relative_to(ROOT), number + 1, line.strip()[:90]))
    return found


def used_keys():
    singles, counted, calls = set(), set(), []
    for source in list((ROOT / "Sources").rglob("*.swift")):
        text = source.read_text()
        for m in CALL.finditer(text):
            kind, key = m.group(1), unescape(m.group(2))
            (counted if kind == "trCount" else singles).add(key)
            given = argument_count(text, m.end())
            calls.append((source.relative_to(ROOT), text.count("\n", 0, m.start()) + 1, kind, key, given))
    return singles, counted, calls


def main():
    prune = "--prune" in sys.argv
    ru, en = load(TABLES / "ru.lproj/Localizable.strings"), load(TABLES / "en.lproj/Localizable.strings")
    singles, counted, calls = used_keys()
    needed_ru = set(singles) | {f"{k}|{c}" for k in counted for c in RU_PLURALS}
    needed_en = {f"{k}|{c}" for k in counted for c in EN_PLURALS}
    problems = 0
    for key in sorted(needed_ru - set(ru)):
        print(f"missing in ru: {key!r}"); problems += 1
    for key in sorted(needed_en - set(en)):
        print(f"missing in en: {key!r}"); problems += 1
    for name, table, needed in (("ru", ru, needed_ru), ("en", en, needed_en | set())):
        for key in sorted(set(table) - needed):
            if name == "en" and key in singles:  # an English entry for a plain key is allowed (a different English text)
                continue
            print(f"unused in {name}: {key!r}"); problems += 1
    for path, line, kind, key, given in calls:
        if given is None:
            continue
        wanted, _ = placeholders(key)
        if kind == "trCount":
            if given != 1:  # trCount(key, count)
                print(f"{path}:{line}: trCount needs exactly one count argument: {key!r}"); problems += 1
        elif given > 0 and given != wanted:  # a bare tr("… %1$@ …") is returned as it is, so zero arguments are allowed
            print(f"{path}:{line}: {given} argument(s) for {wanted} placeholder(s): {key!r}"); problems += 1
    for path, line, text in frozen_texts():
        print(f"{path}:{line}: a stored property or @State calls tr(), so it keeps the first language: {text}"); problems += 1
    for table_name, table in (("ru", ru), ("en", en)):
        for key, value in table.items():
            base = key.split("|")[0]
            want_count, want_specs = placeholders(base)
            got_count, got_specs = placeholders(value)
            if got_count > want_count or any(got_specs.count(x) > want_specs.count(x) for x in set(got_specs)):
                print(f"placeholder mismatch in {table_name}: {key!r} -> {value!r}"); problems += 1
    if prune and problems:
        for name, needed in (("ru", needed_ru), ("en", needed_en | singles)):
            path = TABLES / f"{name}.lproj/Localizable.strings"
            kept = []
            for line in path.read_text().split("\n"):
                m = ENTRY.match(line)
                if m and unescape(m.group(1)) not in needed:
                    continue
                kept.append(line)
            path.write_text("\n".join(kept))
        print("pruned")
        return 0
    print(f"{len(singles) + len(counted)} texts in code, {len(ru)} Russian entries, {problems} problem(s)")
    return 1 if problems else 0


sys.exit(main())

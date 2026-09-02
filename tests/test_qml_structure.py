#!/usr/bin/env python3
"""Catch the QML mistakes qmllint does not.

`qmllint` is clean on a file that binds the same property twice; the engine
only complains at load time, with "Property value set multiple times", and by
then the widget has silently vanished from the bar. That is exactly how the
panel extraction shipped broken for one run: a new `onPopupOpenChanged` was
appended to a file that already had one three hundred lines above.

This is the QML half of `test_bridge_structure.py` — same failure shape (a
second definition wins or breaks quietly), same cheap structural guard.
"""

import pathlib
import re
import sys

BINDING = re.compile(r'^\s*(on[A-Z]\w*|[a-z][\w]*(?:\.[\w]+)*)\s*:(?!:)')

# Bindings a single object may legitimately repeat, because they are list
# properties or grouped-property members that QML merges rather than replaces.
REPEATABLE = {"states", "transitions"}

# JS statements that also read as `name:` once string literals are stripped.
NOT_A_BINDING = {"case", "default", "return", "else", "do"}


def strip_noise(line):
    """Remove string literals and line comments so brace counting is honest."""
    out, i, quote = [], 0, ""
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = ""
            i += 1
            continue
        if c in "\"'":
            quote = c
            i += 1
            continue
        if c == "/" and i + 1 < len(line) and line[i + 1] == "/":
            break
        out.append(c)
        i += 1
    return "".join(out)


def duplicate_bindings(path):
    """Report (line, name) for every binding assigned twice in one object."""
    problems = []
    # One set of seen names per open brace, so a nested object starts clean.
    scopes = [set()]
    for number, raw in enumerate(path.read_text().splitlines(), start=1):
        line = strip_noise(raw)

        match = BINDING.match(line)
        if match:
            name = match.group(1)
            # A declaration introduces the property; only plain bindings clash.
            declaration = re.match(r"^\s*(readonly\s+|required\s+)*property\s", raw)
            if not declaration and name not in REPEATABLE and name not in NOT_A_BINDING:
                if name in scopes[-1]:
                    problems.append((number, name))
                else:
                    scopes[-1].add(name)

        for char in line:
            if char == "{":
                scopes.append(set())
            elif char == "}" and len(scopes) > 1:
                scopes.pop()
    return problems


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    failures = []
    for path in sorted(root.glob("*.qml")) + sorted(root.glob("tests/*.qml")):
        for number, name in duplicate_bindings(path):
            failures.append(f"{path.name}:{number}: {name} is bound twice in the same object")

    if failures:
        print("\n".join(failures))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

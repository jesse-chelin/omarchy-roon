#!/usr/bin/env python3
"""Structural checks on the bridge, run by check.sh.

These exist because the same accident happened twice while building this
plugin: a string replace matched in two classes, and a block of RoonBackend's
real implementation was silently copied into MockBackend. Python keeps the
last definition and raises nothing, so a duplicated or accidentally-copied
method is invisible until behaviour goes strange at runtime — which is a bad
way to find out.

No dependencies: parses the source with ast rather than importing it, so it
runs without the venv or a Roon core.
"""

from __future__ import annotations

import ast
import pathlib
import sys

BRIDGE = pathlib.Path(__file__).resolve().parent.parent / "bridge"

# MockBackend legitimately overrides most of the backend surface. What it must
# never do is hold a byte-identical copy — that is always an editing accident,
# never a decision.
COPY_EXEMPT: set[str] = set()


def load(path: pathlib.Path):
    source = path.read_text(encoding="utf-8")
    return ast.parse(source), source.splitlines()


def classes(tree):
    return {n.name: n for n in tree.body if isinstance(n, ast.ClassDef)}


def methods(node):
    out = {}
    for child in node.body:
        if isinstance(child, ast.FunctionDef):
            out.setdefault(child.name, []).append(child)
    return out


def normalised(lines, node):
    """Method source with whitespace flattened, for identity comparison."""
    return "".join(lines[node.lineno - 1 : node.end_lineno]).replace(" ", "")


def check_no_duplicate_definitions(tree, lines, failures):
    for name, node in classes(tree).items():
        for method, defs in methods(node).items():
            if len(defs) > 1:
                at = ", ".join(str(d.lineno) for d in defs)
                failures.append(
                    f"{name}.{method} defined {len(defs)} times (lines {at}); "
                    f"Python silently keeps the last"
                )
    top = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            top.setdefault(node.name, []).append(node.lineno)
    for name, at in top.items():
        if len(at) > 1:
            failures.append(f"top-level {name} defined {len(at)} times (lines {at})")


def check_no_copied_methods(tree, lines, failures):
    found = classes(tree)
    real, mock = found.get("RoonBackend"), found.get("MockBackend")
    if real is None or mock is None:
        return
    real_methods = {n: d[0] for n, d in methods(real).items()}
    for name, defs in methods(mock).items():
        if name in COPY_EXEMPT or name not in real_methods:
            continue
        if normalised(lines, defs[0]) == normalised(lines, real_methods[name]):
            failures.append(
                f"MockBackend.{name} is a byte-identical copy of "
                f"RoonBackend.{name} (line {defs[0].lineno}) — a mock override "
                f"that does not differ is an editing accident"
            )


def check_dispatch_targets_exist(tree, lines, failures):
    """Every command in HANDLERS must name a method the backend actually has."""
    found = classes(tree)
    real = found.get("RoonBackend")
    if real is None:
        return
    available = set(methods(real))
    handlers = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == "HANDLERS" for t in node.targets
        ):
            handlers = node.value
    if not isinstance(handlers, ast.Dict):
        failures.append("HANDLERS is not a dict literal; cannot verify commands")
        return
    for key, value in zip(handlers.keys, handlers.values):
        called = {
            n.func.attr
            for n in ast.walk(value)
            if isinstance(n, ast.Call)
            and isinstance(n.func, ast.Attribute)
            and isinstance(n.func.value, ast.Name)
            and n.func.value.id == "b"
        }
        missing = sorted(called - available)
        if missing:
            command = key.value if isinstance(key, ast.Constant) else "?"
            failures.append(
                f'HANDLERS["{command}"] calls backend.{missing[0]}(), '
                f"which RoonBackend does not define"
            )


def main() -> int:
    failures: list[str] = []
    for path in sorted(BRIDGE.glob("*.py")):
        tree, lines = load(path)
        check_no_duplicate_definitions(tree, lines, failures)
        if path.name == "roon_bridge.py":
            check_no_copied_methods(tree, lines, failures)
            check_dispatch_targets_exist(tree, lines, failures)

    if failures:
        for line in failures:
            print("  FAIL " + line)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

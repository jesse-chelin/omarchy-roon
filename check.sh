#!/usr/bin/env bash
# Everything that can be verified without a Roon core.
#
# Runs the manifest schema check, QML lint against the shell's imports, the
# QML unit tests, and a Python syntax pass over the bridge. This is what a CI
# job should call; it needs a display only in the sense that qmltestrunner
# wants a platform plugin, and offscreen satisfies that.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export PATH="/usr/lib/qt6/bin:$PATH"
status=0
note() { printf '%-22s %s\n' "$1" "$2"; }

if command -v omarchy >/dev/null; then
  if omarchy plugin validate . >/dev/null 2>&1; then note "manifest" "ok"
  else note "manifest" "FAILED"; status=1; fi
fi

# qmllint needs the shell's modules importable as `qs.*`, which means a
# directory literally named `qs` pointing at it.
SHELL_DIR="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
if [[ -d $SHELL_DIR ]] && command -v qmllint >/dev/null; then
  imports=$(mktemp -d)
  ln -s "$SHELL_DIR" "$imports/qs"
  out=$(qmllint -I "$imports" ./*.qml 2>&1 | grep '^Warning' \
    | grep -vE 'not found on type "QObject"|Unqualified access|QProcess::ExitStatus|PanelWindow is not creatable')
  rm -rf "$imports"
  if [[ -z $out ]]; then note "qmllint" "clean"
  else note "qmllint" "FAILED"; echo "$out"; status=1; fi
fi

if command -v qmltestrunner >/dev/null; then
  if QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/ >/tmp/roon-qmltest.$$ 2>&1; then
    note "qml tests" "$(grep -o 'Totals:.*' /tmp/roon-qmltest.$$ | head -1)"
  else
    note "qml tests" "FAILED"; cat /tmp/roon-qmltest.$$; status=1
  fi
  rm -f /tmp/roon-qmltest.$$
fi

if python3 - <<'PYEOF' 2>/dev/null; then note "bridge syntax" "ok"; else note "bridge syntax" "FAILED"; status=1; fi
import ast, pathlib
for f in pathlib.Path("bridge").glob("*.py"):
    ast.parse(f.read_text())
PYEOF

# Duplicate and accidentally-copied methods are invisible to Python and have
# twice slipped in here through a string replace matching two classes.
if out=$(python3 tests/test_bridge_structure.py); then note "bridge structure" "ok"
else note "bridge structure" "FAILED"; echo "$out"; status=1; fi

# qmllint is clean on a file that binds one property twice; the engine only
# says so at load, and the widget disappears from the bar instead.
if out=$(python3 tests/test_qml_structure.py); then note "qml structure" "ok"
else note "qml structure" "FAILED"; echo "$out"; status=1; fi

# The bridge's own logic. Needs the venv rather than the system interpreter,
# because importing the module imports roonapi; skipped with a visible note
# rather than silently when the venv has not been built yet.
# Prefer the plugin's own venv; fall back to any interpreter that can already
# import roonapi, which is what a CI box has after `pip install roonapi`.
VENV="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-roon/venv/bin/python"
if [[ ! -x $VENV ]] && python3 -c 'import roonapi' 2>/dev/null; then
  VENV=$(command -v python3)
fi
if [[ -x $VENV ]]; then
  if out=$("$VENV" -m unittest discover -s tests -p 'test_bridge.py' 2>&1); then
    note "bridge tests" "$(printf '%s' "$out" | grep -oE 'Ran [0-9]+ tests?' | head -1) ok"
  else
    note "bridge tests" "FAILED"; echo "$out"; status=1
  fi
else
  note "bridge tests" "skipped (no venv)"
fi

# The endpoint prober is stdlib-only by design, so its tests need no venv and
# run anywhere — including a CI box with no Roon core and no pyroon.
if out=$(python3 -m unittest discover -s tests -p 'test_endpoints.py' 2>&1); then
  note "endpoint tests" "$(printf '%s' "$out" | grep -oE 'Ran [0-9]+ tests?' | head -1) ok"
else
  note "endpoint tests" "FAILED"; echo "$out"; status=1
fi

exit $status

#!/usr/bin/env bash
# Build the private virtualenv the Roon bridge runs in.
#
# Arch marks its system Python externally-managed, and the shell should never
# depend on whatever happens to be in the user's PATH, so the bridge gets its
# own interpreter under XDG_STATE_HOME. Re-running this is safe and is also
# how you recover after a Python major-version bump.

set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-roon"
VENV="$STATE_DIR/venv"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Creating venv at $VENV"
mkdir -p "$STATE_DIR"
python3 -m venv --clear "$VENV"

echo "==> Installing dependencies"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$HERE/bridge/requirements.txt"

echo "==> Verifying"
"$VENV/bin/python" -c 'import roonapi; print("roonapi", roonapi.__name__, "ok")'

cat <<MSG

Done. Next:

  1. Add the widget to your bar:
       omarchy plugin enable io.github.jesse-chelin.roon
     (or add {"id": "io.github.jesse-chelin.roon"} to bar.layout in
      ~/.config/omarchy/shell.json)

  2. Authorize the extension:
       Roon → Settings → Extensions → Enable "Omarchy"

  3. Optional keybinding for the library browser, in
     ~/.config/hypr/bindings.conf:
       bindd = SUPER, R, Roon library, exec, omarchy-shell roon-browser toggle
MSG

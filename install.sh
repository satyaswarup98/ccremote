#!/bin/bash
# CC Remote one-line installer. Downloads (or updates) the project into ~/ccremote, then runs setup.sh.
#
#   curl -fsSL https://raw.githubusercontent.com/satyaswarup98/ccremote/main/install.sh | bash                 # full setup
#   curl -fsSL https://raw.githubusercontent.com/satyaswarup98/ccremote/main/install.sh | bash -s -- bridge     # Mac bridge only
set -euo pipefail
REPO="https://github.com/satyaswarup98/ccremote.git"
DIR="${CCREMOTE_DIR:-$HOME/ccremote}"

command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1 || {
  echo "git is needed. Installing Apple's Command Line Tools: click Install in the window that opens, then run this command again."
  xcode-select --install 2>/dev/null || true
  exit 1
}

if [ -d "$DIR/.git" ]; then
  echo "Updating ${DIR}…"
  git -C "$DIR" pull --ff-only --quiet
elif [ -e "$DIR" ]; then
  echo "$DIR already exists and isn't a CC Remote download. Move it away (or set CCREMOTE_DIR=/other/path) and run again."
  exit 1
else
  echo "Downloading CC Remote into ${DIR}…"
  git clone --quiet --depth 1 "$REPO" "$DIR"
fi
exec "$DIR/setup.sh" "${1:-all}"

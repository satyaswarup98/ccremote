#!/bin/bash
# CC Remote one-line installer. Downloads (or updates) the project into ~/ccremote, then runs setup.sh.
#
#   curl -fsSL https://raw.githubusercontent.com/satyaswarup98/ccremote/main/install.sh | bash                 # full setup
#   curl -fsSL https://raw.githubusercontent.com/satyaswarup98/ccremote/main/install.sh | bash -s -- bridge     # Mac bridge only
#
# Uses curl + tar only (no git), so it works anywhere this command itself could be downloaded.
set -euo pipefail
ARCHIVE="https://codeload.github.com/satyaswarup98/ccremote/tar.gz/refs/heads/main"
DIR="${CCREMOTE_DIR:-$HOME/ccremote}"

if [ -e "$DIR" ] && [ ! -f "$DIR/setup.sh" ]; then
  echo "${DIR} already exists and isn't a CC Remote download. Move it away (or set CCREMOTE_DIR=/other/path) and run again."
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading CC Remote…"
if ! curl -fsSL --retry 3 "$ARCHIVE" -o "$TMP/ccremote.tar.gz"; then
  echo "Couldn't download from GitHub. Check the Mac's internet connection (or VPN/proxy) and run the command again."
  exit 1
fi
mkdir -p "$TMP/src"
tar -xzf "$TMP/ccremote.tar.gz" -C "$TMP/src" --strip-components 1
[ -f "$TMP/src/setup.sh" ] || { echo "The download looks incomplete. Run the command again."; exit 1; }

# Copy over any existing install; local state lives in ~/.ccremote, not here.
mkdir -p "$DIR"
cp -R "$TMP/src/." "$DIR/"
chmod +x "$DIR/setup.sh" "$DIR/install.sh" "$DIR/bridge/ccr.js" "$DIR/bridge/bin/cc" "$DIR/bridge/bin/ccr-hook"
echo "Installed into ${DIR}"
exec "$DIR/setup.sh" "${1:-all}"

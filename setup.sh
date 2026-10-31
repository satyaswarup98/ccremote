#!/bin/bash
# CC Remote setup: installs the Mac bridge, builds the iPhone app with your own Apple ID,
# installs it on your USB-connected iPhone, and pairs them.
#
#   ./setup.sh          full setup (safe to re-run)
#   ./setup.sh app      rebuild + reinstall the iPhone app only (do this every 7 days on a free Apple ID)
#   ./setup.sh bridge   install/update the Mac bridge only, then pair (no Xcode or Homebrew needed)
#   ./setup.sh pair     show a pairing code
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HOME/.ccremote"
APP_CFG="$STATE/app.json"
BOLD=$'\e[1m'; ORANGE=$'\e[38;5;173m'; GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; OFF=$'\e[0m'

step() { echo; echo "${ORANGE}▸${OFF} ${BOLD}$*${OFF}"; }
ok()   { echo "  ${GREEN}✓${OFF} $*"; }
info() { echo "  ${DIM}$*${OFF}"; }
die()  { echo; echo "  ${RED}✗ $*${OFF}"; exit 1; }
wait_enter() { read -r -p "  Press Enter when done… " _ </dev/tty; }
ask() { local q="$1" def="${2:-}" a; read -r -p "  $q${def:+ [$def]}: " a </dev/tty; echo "${a:-$def}"; }

# ---------- checks ----------

# Homebrew is optional (only for tmux). It may be installed but not on PATH yet.
load_brew() {
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && { eval "$("$b" shellenv)"; return 0; }
  done
  return 1
}

check_mac() {
  [ "$(uname)" = "Darwin" ] || die "This needs macOS."
  command -v brew >/dev/null || load_brew || true
  ok "macOS $(sw_vers -productVersion) on $(uname -m)"
}

# Uses the Mac's node if it's recent enough, otherwise downloads the official build from nodejs.org
# into ~/.ccremote/node (no Homebrew, no admin password).
# Some networks stall connections mid-transfer: give up on a stalled try (no data for 20 s) and retry.
CURL_RETRY="--connect-timeout 15 --speed-limit 1024 --speed-time 20 --retry 6 --retry-delay 2 --retry-all-errors"

NODE=""
ensure_node() {
  local v
  if command -v node >/dev/null 2>&1; then
    v=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
    if [ "$v" -ge 18 ]; then NODE=$(command -v node); ok "Node $(node -v)"; return; fi
  fi
  if [ -x "$STATE/node/bin/node" ]; then NODE="$STATE/node/bin/node"; ok "Node $("$NODE" -v) (private copy)"; return; fi
  step "Downloading Node.js (runs the bridge; about 50 MB, stays in ~/.ccremote/node)"
  local arch; arch=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo x64)
  local ver
  local index
  index=$(curl -fsSL $CURL_RETRY --max-time 60 https://nodejs.org/dist/index.tab) || index=""
  ver=$(awk -F'\t' 'NR>1 && $10 != "-" { print $1; exit }' <<<"$index")
  [ -n "$ver" ] || die "Couldn't reach nodejs.org. Check the internet connection and run the command again."
  local tmp; tmp=$(mktemp -d)
  curl -fSL --progress-bar $CURL_RETRY "https://nodejs.org/dist/$ver/node-$ver-darwin-$arch.tar.gz" -o "$tmp/node.tgz" \
    || die "Node download failed. Run the command again."
  mkdir -p "$STATE/node"
  # Only the node program is needed (no npm, headers or docs): about 110 MB instead of 220.
  tar -xzf "$tmp/node.tgz" -C "$STATE/node" --strip-components 1 "node-$ver-darwin-$arch/bin/node" "node-$ver-darwin-$arch/LICENSE"
  rm -rf "$tmp"
  NODE="$STATE/node/bin/node"
  "$NODE" -v >/dev/null || die "The downloaded Node doesn't run on this Mac."
  ok "Node $("$NODE" -v) installed in ~/.ccremote/node"
}

optional_tmux() {
  command -v tmux >/dev/null 2>&1 && { ok "tmux found (live Terminal view enabled)"; return; }
  if command -v brew >/dev/null 2>&1; then
    info "Installing tmux for the live Terminal view…"
    brew install tmux >/dev/null 2>&1 && { ok "tmux installed"; return; }
  fi
  ok "Using macOS's built-in GNU screen for terminal sessions (install tmux for a coloured live view)"
}

check_xcode() {
  step "Checking Xcode"
  [ -d /Applications/Xcode.app ] || {
    info "Xcode isn't installed. Opening it in the App Store (about 4 GB)."
    open "macappstore://apps.apple.com/app/xcode/id497799835"
    die "Install Xcode, open it once, then re-run ./setup.sh"
  }
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  if ! xcodebuild -version >/dev/null 2>&1; then
    info "Xcode needs its license accepted (asks for your Mac password)."
    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch
  fi
  if ! xcodebuild -showsdks 2>/dev/null | grep -q iphoneos; then
    info "Downloading the iOS platform for Xcode (a few GB)…"
    xcodebuild -downloadPlatform iOS
  fi
  ok "$(xcodebuild -version | head -1) with iOS SDK"
}

# ---------- bridge ----------

install_bridge() {
  step "Installing the Mac bridge"
  [ -f "$HERE/bridge/node_modules/ws/package.json" ] || die "The download is incomplete (bridge/node_modules/ws is missing). Run the install command again."
  if [ -f "$HOME/.claude/settings.json" ] && grep -q '"hooks"' "$HOME/.claude/settings.json" && ! grep -q ccr-hook "$HOME/.claude/settings.json"; then
    info "Your ~/.claude/settings.json already has hooks. CC Remote replaces any 'ccn' notifier hooks"
    info "and adds its own; everything else is kept, and a backup is saved next to it."
    [ "$(ask 'Continue? (y/n)' y)" = "y" ] || die "Stopped. Nothing was changed."
  fi
  "$NODE" "$HERE/bridge/ccr.js" install
}

# ---------- iPhone app ----------

pick_team() {
  local teams
  teams=$(defaults export com.apple.dt.Xcode - 2>/dev/null | plutil -extract IDEProvisioningTeamByIdentifier json -o - - 2>/dev/null || echo '{}')
  "$NODE" -e '
    const t = Object.values(JSON.parse(process.argv[1])).flat();
    const seen = new Set();
    for (const x of t) if (!seen.has(x.teamID)) { seen.add(x.teamID); console.log(`${x.teamID}\t${x.teamName}`); }
  ' "$teams"
}

pick_device() {
  local f; f=$(mktemp)
  xcrun devicectl list devices --json-output "$f" >/dev/null 2>&1 || true
  "$NODE" -e '
    const d = (JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).result?.devices ?? [])
      .filter(x => x.hardwareProperties?.reality === "physical" && x.hardwareProperties?.platform === "iOS");
    for (const x of d) console.log([x.hardwareProperties.udid, x.deviceProperties?.name, x.deviceProperties?.developerModeStatus ?? "unknown", x.connectionProperties?.tunnelState ?? ""].join("\t"));
  ' "$f" 2>/dev/null || true
  rm -f "$f"
}

configure_app() {
  mkdir -p "$STATE"
  if [ -f "$APP_CFG" ]; then
    TEAM=$("$NODE" -e 'console.log(require(process.argv[1]).team)' "$APP_CFG")
    BUNDLE=$("$NODE" -e 'console.log(require(process.argv[1]).bundle)' "$APP_CFG")
    ok "using team $TEAM, app ID $BUNDLE  ${DIM}(saved in $APP_CFG)${OFF}"
    return
  fi
  step "Apple ID for signing"
  local teams
  while :; do
    teams=$(pick_team)
    [ -n "$teams" ] && break
    info "No Apple ID found in Xcode. Open Xcode → Settings (⌘,) → Accounts → + → Apple Account, and sign in."
    open -a Xcode
    wait_enter
  done
  if [ "$(echo "$teams" | wc -l)" -gt 1 ]; then
    echo "$teams" | nl -w4 -s'  '
    local n; n=$(ask "Which team?" 1)
    teams=$(echo "$teams" | sed -n "${n}p")
  fi
  TEAM=$(echo "$teams" | head -1 | cut -f1)
  ok "team: $(echo "$teams" | head -1 | cut -f2) ($TEAM)"
  local user; user=$(whoami | tr -cd 'a-z0-9')
  BUNDLE=$(ask "App ID (must be unique to you)" "com.${user}.ccremote")
  "$NODE" -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({ team: process.argv[2], bundle: process.argv[3] }, null, 2))' "$APP_CFG" "$TEAM" "$BUNDLE"
}

find_iphone() {
  step "Looking for your iPhone"
  local devs
  while :; do
    devs=$(pick_device)
    if [ -z "$devs" ]; then
      info "No iPhone found. Plug it in with a USB cable, unlock it, and tap Trust if asked."
      wait_enter; continue
    fi
    if [ "$(echo "$devs" | wc -l)" -gt 1 ]; then
      echo "$devs" | cut -f2 | nl -w4 -s'  '
      local n; n=$(ask "Which iPhone?" 1)
      devs=$(echo "$devs" | sed -n "${n}p")
    fi
    UDID=$(echo "$devs" | head -1 | cut -f1)
    local name dev; name=$(echo "$devs" | head -1 | cut -f2); dev=$(echo "$devs" | head -1 | cut -f3)
    if [ "$dev" != "enabled" ]; then
      info "Developer Mode is off on $name."
      info "On the iPhone: Settings → Privacy & Security → Developer Mode → On → Restart, then tap Turn On."
      info "(If the option isn't there yet, it appears after the first install attempt below.)"
      [ "$(ask 'Try installing anyway? (y/n)' y)" = "y" ] || { wait_enter; continue; }
    fi
    ok "$name"
    break
  done
}

build_and_install() {
  step "Building CC Remote"
  cd "$HERE/ios"
  local log; log=$(mktemp)
  if ! xcodebuild -project CCRemote.xcodeproj -scheme CCRemote -configuration Debug \
        -destination "id=$UDID" -derivedDataPath build \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build >"$log" 2>&1; then
    grep -E "error:|Developer Mode" "$log" | sort -u | head -10
    if grep -q "Developer Mode" "$log"; then
      die "Turn on Developer Mode on the iPhone (Settings → Privacy & Security), then run ./setup.sh app"
    fi
    die "Build failed. Full log: $log"
  fi
  ok "built"
  step "Installing on the iPhone"
  xcrun devicectl device install app --device "$UDID" build/Build/Products/Debug-iphoneos/CCRemote.app >/dev/null
  ok "installed"
  if ! xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >/dev/null 2>&1; then
    info "iOS needs you to trust your developer certificate once:"
    info "iPhone Settings → General → VPN & Device Management → your Apple ID → Trust"
    wait_enter
    xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  fi
  ok "CC Remote is open on the iPhone. Allow notifications and local network access when asked."
  info "Free Apple IDs: the app stops opening after 7 days. Re-run: ./setup.sh app"
}

app() { check_mac; ensure_node; check_xcode; configure_app; find_iphone; build_and_install; }
pair() { step "Pairing"; info "Tap this Mac in the CC Remote app, then enter this code:"; "$NODE" "$HERE/bridge/ccr.js" pair; }

case "${1:-all}" in
  all)    check_mac; ensure_node; optional_tmux; check_xcode; install_bridge; configure_app; find_iphone; build_and_install; pair ;;
  app)    app ;;
  bridge) check_mac; ensure_node; optional_tmux; install_bridge; pair ;;
  pair)   ensure_node; pair ;;
  *)      sed -n '2,8p' "$0" ;;
esac

#!/bin/bash
# CC Remote setup: installs the Mac bridge, builds the iPhone app with your own Apple ID,
# installs it on your USB-connected iPhone, and pairs them.
#
#   ./setup.sh          full setup (safe to re-run)
#   ./setup.sh app      rebuild + reinstall the iPhone app only (do this every 7 days on a free Apple ID)
#   ./setup.sh bridge   install/update the Mac bridge only
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

check_mac() {
  [ "$(uname)" = "Darwin" ] || die "This needs macOS."
  command -v brew >/dev/null || die "Homebrew is missing. Install it from https://brew.sh, then re-run ./setup.sh"
  ok "macOS $(sw_vers -productVersion) on $(uname -m), Homebrew found"
}

install_tools() {
  step "Installing tools (node, tmux, openssl@3, xcodegen)"
  local need=()
  for f in node tmux openssl@3 xcodegen; do brew list --formula "$f" >/dev/null 2>&1 || need+=("$f"); done
  if [ ${#need[@]} -gt 0 ]; then brew install "${need[@]}"; fi
  ok "tools ready"
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
  (cd "$HERE/bridge" && npm install --silent --no-audit --no-fund)
  if [ -f "$HOME/.claude/settings.json" ] && grep -q '"hooks"' "$HOME/.claude/settings.json" && ! grep -q ccr-hook "$HOME/.claude/settings.json"; then
    info "Your ~/.claude/settings.json already has hooks. CC Remote replaces any 'ccn' notifier hooks"
    info "and adds its own; everything else is kept, and a backup is saved next to it."
    [ "$(ask 'Continue? (y/n)' y)" = "y" ] || die "Stopped. Nothing was changed."
  fi
  node "$HERE/bridge/ccr.js" install
}

# ---------- iPhone app ----------

pick_team() {
  local teams
  teams=$(defaults export com.apple.dt.Xcode - 2>/dev/null | plutil -extract IDEProvisioningTeamByIdentifier json -o - - 2>/dev/null || echo '{}')
  node -e '
    const t = Object.values(JSON.parse(process.argv[1])).flat();
    const seen = new Set();
    for (const x of t) if (!seen.has(x.teamID)) { seen.add(x.teamID); console.log(`${x.teamID}\t${x.teamName}`); }
  ' "$teams"
}

pick_device() {
  local f; f=$(mktemp)
  xcrun devicectl list devices --json-output "$f" >/dev/null 2>&1 || true
  node -e '
    const d = (JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).result?.devices ?? [])
      .filter(x => x.hardwareProperties?.reality === "physical" && x.hardwareProperties?.platform === "iOS");
    for (const x of d) console.log([x.hardwareProperties.udid, x.deviceProperties?.name, x.deviceProperties?.developerModeStatus ?? "unknown", x.connectionProperties?.tunnelState ?? ""].join("\t"));
  ' "$f" 2>/dev/null || true
  rm -f "$f"
}

configure_app() {
  mkdir -p "$STATE"
  if [ -f "$APP_CFG" ]; then
    TEAM=$(node -e 'console.log(require(process.argv[1]).team)' "$APP_CFG")
    BUNDLE=$(node -e 'console.log(require(process.argv[1]).bundle)' "$APP_CFG")
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
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({ team: process.argv[2], bundle: process.argv[3] }, null, 2))' "$APP_CFG" "$TEAM" "$BUNDLE"
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
  xcodegen generate --quiet
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

app() { check_mac; check_xcode; configure_app; find_iphone; build_and_install; }

case "${1:-all}" in
  all)    check_mac; install_tools; check_xcode; install_bridge; configure_app; find_iphone; build_and_install
          step "Pairing"; info "Tap your Mac in the app, then enter this code:"; node "$HERE/bridge/ccr.js" pair ;;
  app)    app ;;
  bridge) check_mac; install_tools; install_bridge ;;
  pair)   node "$HERE/bridge/ccr.js" pair ;;
  *)      sed -n '2,9p' "$0" ;;
esac

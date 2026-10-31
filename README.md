# CC Remote

Control Claude Code on this Mac from your iPhone: approve prompts, answer Claude's questions, send messages, and watch a live terminal mirror.

```
iPhone app ──TLS (pinned cert) over Wi-Fi/Tailscale──▶ bridge (Node, launchd) ◀── Claude Code hooks (ccr-hook → 127.0.0.1:8788)
                                                       └─ tmux (cc sessions): screen capture + send-keys
                                                       └─ ntfy.sh: notifications while the app is closed
```

## Install

Paste into Terminal on the Mac. It downloads everything into `~/ccremote` and runs the setup:

```
curl -fsSL https://raw.githubusercontent.com/satyaswarup98/ccremote/main/install.sh | bash
```

Mac only (when someone else's Mac already installed the app on your iPhone; no Xcode or Homebrew needed):

```
curl -fsSL https://raw.githubusercontent.com/satyaswarup98/ccremote/main/install.sh | bash -s -- bridge
~/ccremote/setup.sh pair
```

Needs: a Mac with Claude Code. Nothing else to install first: if the Mac has no Node.js, setup downloads the official build into `~/.ccremote/node` (no admin password). Homebrew is optional; with it, setup also installs `tmux` for the phone's live Terminal view and `cc`. Building the iPhone app additionally needs Xcode from the App Store, an Apple ID (free is fine), and the iPhone on a USB cable.

```
~/ccremote/setup.sh app     # every 7 days on a free Apple ID: rebuild + reinstall the app
~/ccremote/setup.sh pair    # pair another time
```

Running the install command again updates to the latest version.

**Several Macs:** run the install (or `./setup.sh bridge`) on each Mac, then on the phone tap the Mac's name at the top of the session list → **Add another Mac…** and enter that Mac's `ccr pair` code. Tap the name again to switch. With the app closed, each Mac sends its own ntfy notifications (subscribe to each Mac's topic in Settings); tapping one opens the right Mac.

The script asks for your Apple ID team (from Xcode → Settings → Accounts) and an app ID like `com.yourname.ccremote`, and remembers both in `~/.ccremote/app.json`.

## Mac commands

| Command | What it does |
| --- | --- |
| `ccr pair` | Show a 6-digit pairing code (5 min, single use) |
| `ccr status` | Sessions, away state, connected phones |
| `ccr away on\|off\|auto` | Who answers prompts. `auto` = phone after 2 min of Mac inactivity |
| `cc [args]` | Start `claude` inside tmux (adds the live Terminal tab on the phone) |
| `ccr devices` / `ccr unpair all` | List / revoke paired phones |
| `ccr logs`, `ccr restart`, `ccr uninstall` | Maintenance |

## How control works

- **Approvals**: `PermissionRequest` hook. When away, the bridge holds it until the phone answers (≤58 min); when you touch the Mac again it hands the prompt back to the Mac.
- **Questions** (`AskUserQuestion`): `PreToolUse` hook returns the phone's answers via `updatedInput`.
- **Messages**: tmux sessions get typed into directly. VS Code sessions receive the message through the `Stop` hook: when away, a finished turn waits ~14 min for a reply. For an idle VS Code session the phone offers **Run now in a Terminal copy** (`claude --resume <id> --fork-session "<msg>"` in tmux, live mirror) or **Queue** for the next stop.
- **Session list**: built from hook events plus Claude Code's own registry (`~/.claude/sessions/<pid>.json`), so idle sessions appear too and disappear when their process exits.
- **Notifications**: approvals, questions, task complete, waiting for input. Native banners while the app is open; ntfy pushes while it's closed (turn-finished pings skipped while you're actively typing on the Mac).
- Nothing is ever held until a phone has been paired, and the hook is a no-op if the bridge is down.

## Building the app by hand

`setup.sh app` does this for you:

```
cd ios && xcodegen generate
xcodebuild -project CCRemote.xcodeproj -scheme CCRemote -destination 'id=<iphone udid>' -derivedDataPath build \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<team id> PRODUCT_BUNDLE_IDENTIFIER=<your app id> build
xcrun devicectl device install app --device <udid> build/Build/Products/Debug-iphoneos/CCRemote.app
```

Files: bridge state and keys in `~/.ccremote/`; the original Claude settings backup is `~/.claude/settings.json.ccremote-backup-*`.

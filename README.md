# CC Remote

Control Claude Code on this Mac from your iPhone: approve prompts, answer Claude's questions, send messages, and watch a live terminal mirror.

```
iPhone app ──TLS (pinned cert) over Wi-Fi──▶ bridge (Node, launchd) ◀── Claude Code hooks (ccr-hook → 127.0.0.1:8788)
                                                       └─ tmux (cc sessions): screen capture + send-keys
                                                       └─ ntfy.sh: notifications while the app is closed
```

## Install

Paste into Terminal on the Mac. It installs (or updates) the Mac side and shows a pairing code for the iPhone app. This is the command the app shows on its first screen:

```
curl -fsSL https://raw.githubusercontent.com/satyaswarup98/ccremote/main/install.sh | bash
```

To also build and install the iPhone app from this Mac (needs Xcode and the iPhone on USB):

```
curl -fsSL https://raw.githubusercontent.com/satyaswarup98/ccremote/main/install.sh | bash -s -- all
```

Needs: a Mac with Claude Code. Nothing else to install first: if the Mac has no Node.js, setup downloads the official build into `~/.ccremote/node` (no admin password). Homebrew is optional; with it, setup also installs `tmux` (a coloured live Terminal view). Without it, terminal sessions use macOS's built-in GNU screen. Building the iPhone app additionally needs Xcode from the App Store, an Apple ID (free is fine), and the iPhone on a USB cable.

```
~/ccremote/setup.sh app     # every 7 days on a free Apple ID: rebuild + reinstall the app
~/ccremote/setup.sh pair    # pair another time
```

Running the install command again updates to the latest version.

**Network:** the phone and the Mac need to be on the same Wi-Fi. The bridge keeps the Mac awake while it's on power (`keepAwakeOnPower`). While the Mac is locked or untouched, a finished turn waits for your reply (`stopHoldSec`, `lockedHoldSec`); typing into VS Code needs it unlocked (macOS blocks input behind the lock screen).

**Several Macs:** run the install (or `./setup.sh bridge`) on each Mac, then on the phone tap the Mac's name at the top of the session list → **Add another Mac…** and enter that Mac's `ccr pair` code. Tap the name again to switch. With the app closed, each Mac sends its own ntfy notifications (subscribe to each Mac's topic in Settings); tapping one opens the right Mac.

The script asks for your Apple ID team (from Xcode → Settings → Accounts) and an app ID like `com.yourname.ccremote`, and remembers both in `~/.ccremote/app.json`.

## Mac commands

| Command | What it does |
| --- | --- |
| `ccr pair` | Show a 6-digit pairing code (5 min, single use) |
| `ccr status` | Sessions, away state, connected phones |
| `cc [args]` | Start `claude` inside tmux (adds the live Terminal tab on the phone) |
| `ccr devices` / `ccr unpair all` | List / revoke paired phones |
| `ccr logs`, `ccr restart`, `ccr uninstall` | Maintenance |

## How control works

- **Away is automatic** (no switch): the Mac counts as away when it's locked or untouched for 2 minutes. Then a finished turn stays open for your phone reply (up to 1 h, or 12 h while locked); touching the Mac hands it back.
- **Approvals**: `PermissionRequest` hook. Every prompt shows on the Mac and the phone at once; whichever answers first wins.
- **Questions** (`AskUserQuestion`): `PreToolUse` hook returns the phone's answers via `updatedInput`.
- **Messages**: a turn that's waiting for a reply (Away mode) gets it through the `Stop` hook. Terminal sessions (tmux or screen) are typed into. An idle VS Code session is typed into directly: the bridge brings its tab forward with the extension's documented `vscode://anthropic.claude-code/open?session=…` link, checks the VS Code window title shows that chat and folder, pastes, presses Return, and confirms through that session's `UserPromptSubmit` hook. It waits for a 1.5 s pause in keyboard/mouse input (up to 20 s; `vscodeQuietSec`, `vscodeWaitSec` in `~/.ccremote/config.json`), types in about a second, and puts you back in the app you were using. It never types while the Mac is locked (macOS blocks input behind the lock screen); instead the chat is continued as a background copy (`claude -p --resume <id> --fork-session`), which the phone opens and follows. The original VS Code chat is left as it is. Needs the Accessibility permission for `node` on the Mac (macOS asks once).
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

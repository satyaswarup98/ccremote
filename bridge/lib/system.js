import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);

// CCR_TERM=screen forces the screen backend (for testing on a Mac that has tmux).
export const TMUX = process.env.CCR_TERM === 'screen' ? null
  : ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux'].find(p => fs.existsSync(p)) ?? null;
// macOS ships GNU screen; it stands in for tmux on Macs without Homebrew (plain-text mirror, no colours).
export const SCREEN = fs.existsSync('/usr/bin/screen') ? '/usr/bin/screen' : null;

// Seconds since the last keyboard/mouse event on the Mac.
export async function macIdleSeconds() {
  try {
    const { stdout } = await run('/usr/sbin/ioreg', ['-c', 'IOHIDSystem', '-d', '4']);
    const m = stdout.match(/"HIDIdleTime"\s*=\s*(\d+)/);
    return m ? Number(m[1]) / 1e9 : 0;
  } catch {
    return 0;
  }
}

// Newest Claude Code CLI: one on PATH, else the binary bundled in the VS Code extension.
export function findClaudeBinary() {
  const candidates = [
    path.join(os.homedir(), '.local/bin/claude'),
    '/opt/homebrew/bin/claude',
    '/usr/local/bin/claude',
  ];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  const extDir = path.join(os.homedir(), '.vscode/extensions');
  try {
    const exts = fs.readdirSync(extDir)
      .filter(d => d.startsWith('anthropic.claude-code-'))
      .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
    for (const d of exts.reverse()) {
      const bin = path.join(extDir, d, 'resources/native-binary/claude');
      if (fs.existsSync(bin)) return bin;
    }
  } catch {}
  return null;
}

const tmux = {
  async capture(pane) {
    const { stdout } = await run(TMUX, ['capture-pane', '-p', '-e', '-t', pane], { maxBuffer: 4 << 20 });
    return stdout;
  },

  async paneAlive(pane) {
    try {
      const { stdout } = await run(TMUX, ['display-message', '-p', '-t', pane, '#{pane_id}']);
      return stdout.trim() === pane;
    } catch {
      return false;
    }
  },

  // Bracketed paste so multi-line text lands as one prompt, then Enter to submit.
  async sendText(pane, text) {
    const buf = `ccr-${process.pid}-${Date.now()}`;
    await run(TMUX, ['set-buffer', '-b', buf, '--', text]);
    await run(TMUX, ['paste-buffer', '-p', '-d', '-b', buf, '-t', pane]);
    await new Promise(r => setTimeout(r, 120));
    await run(TMUX, ['send-keys', '-t', pane, 'Enter']);
  },

  async sendKeys(pane, keys) {
    const map = {
      esc: 'Escape', enter: 'Enter', up: 'Up', down: 'Down', left: 'Left', right: 'Right',
      tab: 'Tab', btab: 'BTab', ctrlc: 'C-c', space: 'Space', backspace: 'BSpace',
    };
    for (const k of keys) {
      if (map[k]) await run(TMUX, ['send-keys', '-t', pane, map[k]]);
      else if (/^[0-9a-zA-Z]$/.test(k)) await run(TMUX, ['send-keys', '-t', pane, '-l', k]);
    }
  },

  // Starts claude in a detached tmux session; the SessionStart hook registers it.
  async newSession(cwd, claudeBin, args = [], env = {}) {
    const name = `cc-${path.basename(cwd).replace(/[^\w-]/g, '_').slice(0, 20)}-${Date.now().toString(36).slice(-4)}`;
    const envArgs = Object.entries(env).flatMap(([k, v]) => ['-e', `${k}=${v}`]);
    const { stdout } = await run(TMUX, ['new-session', '-d', '-P', '-F', '#{pane_id}', '-s', name, '-x', '110', '-y', '40', ...envArgs, '-c', cwd, claudeBin, ...args]);
    return { name, pane: stdout.trim() };
  },
};

// GNU screen backend. Handles look like "screen:<pid>.<name>" (the session's $STY).
const SCREEN_KEYS = {
  esc: '\x1b', enter: '\r', up: '\x1b[A', down: '\x1b[B', right: '\x1b[C', left: '\x1b[D',
  tab: '\t', btab: '\x1b[Z', ctrlc: '\x03', space: ' ', backspace: '\x7f',
};

const screen = {
  // screen sends -X arguments through as-is, so text needs no escaping; split long input.
  async stuff(sty, data) {
    for (let i = 0; i < data.length; i += 400) {
      await run(SCREEN, ['-S', sty, '-p', '0', '-X', 'stuff', data.slice(i, i + 400)]);
    }
  },

  async capture(sty) {
    const file = path.join(os.tmpdir(), `ccr-hc-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`);
    try {
      await run(SCREEN, ['-S', sty, '-p', '0', '-X', 'hardcopy', file]);
      // The screen server writes the file after the client returns.
      for (let i = 0; i < 20 && !fs.existsSync(file); i++) await new Promise(r => setTimeout(r, 25));
      await new Promise(r => setTimeout(r, 15));
      return fs.readFileSync(file, 'utf8').replace(/\s+$/, '\n');
    } finally {
      fs.rm(file, { force: true }, () => {});
    }
  },

  async paneAlive(sty) {
    try {
      const { stdout } = await run(SCREEN, ['-ls']);
      return stdout.split('\n').some(l => l.trim().split(/\s/)[0] === sty);
    } catch (e) {
      // `screen -ls` exits non-zero even when it lists sessions.
      return String(e.stdout ?? '').split('\n').some(l => l.trim().split(/\s/)[0] === sty);
    }
  },

  // No bracketed paste through screen: send plain text, and use Claude Code's "\ + Enter" for line breaks.
  async sendText(sty, text) {
    await screen.stuff(sty, text.replace(/\r?\n/g, '\\\r'));
    await new Promise(r => setTimeout(r, 120));
    await screen.stuff(sty, '\r');
  },

  async sendKeys(sty, keys) {
    for (const k of keys) {
      if (SCREEN_KEYS[k]) await screen.stuff(sty, SCREEN_KEYS[k]);
      else if (/^[0-9a-zA-Z]$/.test(k)) await screen.stuff(sty, k);
    }
  },

  async newSession(cwd, claudeBin, args = [], env = {}) {
    const name = `cc-${path.basename(cwd).replace(/[^\w-]/g, '_').slice(0, 20)}-${Date.now().toString(36).slice(-4)}`;
    await run(SCREEN, ['-dmS', name, claudeBin, ...args], { cwd, env: { ...process.env, ...env, TERM: 'xterm-256color' } });
    let sty = null;
    for (let i = 0; i < 20 && !sty; i++) {
      const out = await run(SCREEN, ['-ls']).then(r => r.stdout, e => String(e.stdout ?? ''));
      sty = out.split('\n').map(l => l.trim().split(/\s/)[0]).find(x => x.endsWith(`.${name}`)) ?? null;
      if (!sty) await new Promise(r => setTimeout(r, 50));
    }
    if (!sty) throw new Error('screen session did not start');
    await run(SCREEN, ['-S', sty, '-p', '0', '-X', 'width', '-w', '110']).catch(() => {});
    await run(SCREEN, ['-S', sty, '-p', '0', '-X', 'height', '-w', '40']).catch(() => {});
    return { name, pane: `screen:${sty}` };
  },
};

// One interface for both: tmux handles are "%<n>" panes, screen handles are "screen:<sty>".
function backend(handle) {
  return handle.startsWith('screen:') ? [screen, handle.slice(7)] : [tmux, handle];
}

export const term = {
  available: () => !!(TMUX || SCREEN),
  capture: h => { const [b, id] = backend(h); return b.capture(id); },
  paneAlive: h => { const [b, id] = backend(h); return b.paneAlive(id); },
  sendText: (h, text) => { const [b, id] = backend(h); return b.sendText(id, text); },
  sendKeys: (h, keys) => { const [b, id] = backend(h); return b.sendKeys(id, keys); },
  // New sessions prefer tmux (colours, scrollback); fall back to the built-in screen.
  newSession: (...a) => {
    if (TMUX) return tmux.newSession(...a);
    if (SCREEN) return screen.newSession(...a);
    const e = new Error('no tmux or screen'); e.code = 'ENOENT'; throw e;
  },
};

// ---------- VS Code ----------

const CODE_CLI = '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code';

export async function macLocked() {
  try {
    const { stdout } = await run('/usr/sbin/ioreg', ['-n', 'Root', '-d1']);
    return /"CGSSessionScreenIsLocked"=Yes/.test(stdout);
  } catch {
    return false;
  }
}

async function frontmostApp() {
  // macOS may be showing a permission prompt for this; don't wait on it forever.
  const { stdout } = await run('/usr/bin/osascript', ['-e', 'tell application "System Events" to name of first process whose frontmost is true'], { timeout: 8000 });
  return stdout.trim();
}

// Titles of VS Code's real windows (not popups/overlays), front first. Needs the Accessibility permission.
// A window showing a Claude chat is titled "<tab title> — <folder>".
export async function vscodeWindowTitles() {
  const script = [
    'tell application "System Events" to tell process "Code"',
    'set out to ""',
    'repeat with w in windows',
    'if (value of attribute "AXSubrole" of w) is "AXStandardWindow" then set out to out & (name of w) & linefeed',
    'end repeat',
    'return out',
    'end tell',
  ].join('\n');
  const { stdout } = await run('/usr/bin/osascript', ['-e', script], { timeout: 8000 });
  return stdout.split('\n').map(t => t.trim()).filter(Boolean);
}

async function clipboardGet() {
  return run('/usr/bin/pbpaste', [], { timeout: 3000 }).then(r => r.stdout, () => '');
}

function clipboardSet(text) {
  return new Promise((resolve, reject) => {
    const p = execFile('/usr/bin/pbcopy', [], err => (err ? reject(err) : resolve()));
    p.stdin.end(text);
  });
}

// Types `text` into an existing VS Code session and presses Return. The documented URI handler
// (vscode://anthropic.claude-code/open?session=…) brings the session's tab forward, open or not;
// its `prompt` parameter is ignored when the tab is already open, so the text is pasted instead.
// Throws an Error with .reason: locked | no-vscode | not-front | accessibility.
// True when a window title "<tab> — <folder>" shows the chat `title` from folder `cwd`.
// Long tab names are shortened with "…".
export function titleMatches(windowTitle, title, cwd) {
  const parts = String(windowTitle ?? '').split(' — ');
  const tab = parts[0].replace(/…$/, '').trim();
  const folder = parts.length > 1 ? parts[parts.length - 1].trim() : null;
  const want = String(title ?? '').trim();
  if (folder && cwd && folder !== path.basename(cwd)) return false;
  return tab.length >= 4 && want.length > 0 && (want.startsWith(tab) || tab.startsWith(want));
}

export async function vscodeSubmit({ sessionId, cwd, text, title }) {
  const fail = (reason, msg) => Object.assign(new Error(msg ?? reason), { reason });
  if (await macLocked()) throw fail('locked');
  if (!fs.existsSync('/Applications/Visual Studio Code.app')) throw fail('no-vscode');
  // The handler only resumes sessions from the folder open in the focused window, so focus that folder first.
  if (cwd && fs.existsSync(CODE_CLI)) await run(CODE_CLI, [cwd], { timeout: 10000 }).catch(() => {});
  await new Promise(r => setTimeout(r, 900));
  await run('/usr/bin/open', [`vscode://anthropic.claude-code/open?session=${encodeURIComponent(sessionId)}`], { timeout: 10000 });
  await new Promise(r => setTimeout(r, 1800));
  let front;
  try {
    front = await frontmostApp();
  } catch (e) {
    throw fail('accessibility', String(e.stderr || e.message));
  }
  // Never type into some other app, or into a different chat than the one asked for.
  if (front !== 'Code' && front !== 'Electron') throw fail('not-front', front);
  const shown = (await vscodeWindowTitles().catch(() => []))[0];
  if (!titleMatches(shown, title, cwd)) throw fail('wrong-tab', shown || '(no window)');
  const saved = await clipboardGet();
  try {
    await clipboardSet(text);
    // Ctrl+Opt+Shift+Cmd+K runs "Claude Code: Focus input" (bound in VS Code's keybindings.json by
    // CC Remote), so the paste lands in the visible chat's prompt box rather than wherever focus was.
    await run('/usr/bin/osascript', ['-e', [
      'tell application "System Events"',
      'keystroke "k" using {control down, option down, shift down, command down}',
      'delay 0.4',
      'keystroke "v" using command down',
      'delay 0.5',
      'key code 36',
      'end tell',
    ].join('\n')], { timeout: 8000 });
  } catch (e) {
    throw fail('accessibility', String(e.stderr || e.message));
  } finally {
    setTimeout(() => clipboardSet(saved).catch(() => {}), 800);
  }
}

export function hostName() {
  try {
    return execFileSync('/usr/sbin/scutil', ['--get', 'ComputerName'], { encoding: 'utf8' }).trim();
  } catch {
    return os.hostname().replace(/\.local$/, '');
  }
}

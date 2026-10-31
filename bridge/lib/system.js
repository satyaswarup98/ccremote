import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);

export const TMUX = ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux'].find(p => fs.existsSync(p)) ?? 'tmux';

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

export const tmux = {
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

export function hostName() {
  try {
    return execFileSync('/usr/sbin/scutil', ['--get', 'ComputerName'], { encoding: 'utf8' }).trim();
  } catch {
    return os.hostname().replace(/\.local$/, '');
  }
}

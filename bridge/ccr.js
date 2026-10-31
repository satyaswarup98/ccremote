#!/usr/bin/env node
// ccr: install and control the CC Remote bridge.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  STATE_DIR, DEVICES_FILE, LOG_FILE, LOCAL_PORT, ensureStateDir, readSecret,
} from './lib/paths.js';

const HERE = path.dirname(fs.realpathSync(fileURLToPath(import.meta.url)));
const SETTINGS = path.join(os.homedir(), '.claude/settings.json');
const HOOK_CMD = path.join(STATE_DIR, 'bin/ccr-hook');
const LABEL = 'com.ccremote.bridge';
const PLIST = path.join(os.homedir(), 'Library/LaunchAgents', `${LABEL}.plist`);
// Put ccr/cc in a writable folder that's already on PATH (Homebrew's on most Macs); otherwise use
// ~/.ccremote/bin and add it to PATH for new Terminal windows.
function writable(d) { try { fs.accessSync(d, fs.constants.W_OK); return true; } catch { return false; } }
const BIN_DIR = ['/opt/homebrew/bin', '/usr/local/bin'].find(d => fs.existsSync(d) && writable(d)) ?? path.join(STATE_DIR, 'bin');
const UID = process.getuid();

// Homebrew's node resolves to a versioned Cellar folder that `brew upgrade` deletes; use its stable
// bin/node link instead so the background service and ccr keep working after upgrades.
const NODE = (() => {
  const i = process.execPath.indexOf('/Cellar/');
  if (i > 0) {
    const stable = path.join(process.execPath.slice(0, i), 'bin/node');
    if (fs.existsSync(stable)) return stable;
  }
  return process.execPath;
})();

// Event -> hook timeout (s). Holding events get long timeouts so the phone has time to answer.
const HOOKS = {
  SessionStart: 10,
  UserPromptSubmit: 10,
  PreToolUse: 3660,
  PostToolUse: 10,
  PermissionRequest: 3660,
  Notification: 10,
  Stop: 3600,
  SessionEnd: 10,
};

const c = { b: s => `\x1b[1m${s}\x1b[0m`, o: s => `\x1b[38;5;173m${s}\x1b[0m`, g: s => `\x1b[32m${s}\x1b[0m`, d: s => `\x1b[2m${s}\x1b[0m`, r: s => `\x1b[31m${s}\x1b[0m` };

async function api(method, route, body) {
  const res = await fetch(`http://127.0.0.1:${LOCAL_PORT}${route}`, {
    method, headers: { 'X-Secret': readSecret(), 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  }).catch(() => null);
  if (!res) {
    console.error(c.r('Bridge is not running.') + ' Start it with: ccr install   (or ccr start to run in the foreground)');
    process.exit(1);
  }
  return res.json();
}

function isOurs(cmd = '') {
  return cmd.includes('ccr-hook') || /\bccn hook\b/.test(cmd);
}

function editHooks(add) {
  const raw = fs.existsSync(SETTINGS) ? fs.readFileSync(SETTINGS, 'utf8') : '{}';
  const settings = JSON.parse(raw);
  const hooks = settings.hooks ?? {};
  for (const [event, groups] of Object.entries(hooks)) {
    hooks[event] = groups
      .map(g => ({ ...g, hooks: (g.hooks ?? []).filter(h => !isOurs(h.command)) }))
      .filter(g => g.hooks.length);
    if (!hooks[event].length) delete hooks[event];
  }
  if (add) {
    for (const [event, timeout] of Object.entries(HOOKS)) {
      (hooks[event] ??= []).push({ hooks: [{ type: 'command', command: HOOK_CMD, timeout }] });
    }
  }
  settings.hooks = hooks;
  const updated = JSON.stringify(settings, null, 2) + '\n';
  if (updated === raw) return null;   // already up to date: no rewrite, no extra backup
  const backup = `${SETTINGS}.ccremote-backup-${new Date().toISOString().replace(/[:.]/g, '-')}`;
  fs.writeFileSync(backup, raw);
  fs.writeFileSync(SETTINGS, updated);
  return backup;
}

// VS Code shortcut the bridge presses to run "Claude Code: Focus input" before typing a phone message.
const VSCODE_KEYBINDINGS = path.join(os.homedir(), 'Library/Application Support/Code/User/keybindings.json');
const FOCUS_BINDING = '{ "key": "ctrl+alt+shift+cmd+k", "command": "claude-vscode.focus" }';

function addVSCodeKeybinding() {
  if (!fs.existsSync('/Applications/Visual Studio Code.app')) return 'no VS Code';
  fs.mkdirSync(path.dirname(VSCODE_KEYBINDINGS), { recursive: true });
  if (!fs.existsSync(VSCODE_KEYBINDINGS)) {
    fs.writeFileSync(VSCODE_KEYBINDINGS, `// Added by CC Remote: lets the bridge put the cursor in Claude Code's prompt box\n// before typing a message sent from the phone. Safe to remove (CC Remote then queues instead).\n[\n  ${FOCUS_BINDING}\n]\n`);
    return 'added';
  }
  const text = fs.readFileSync(VSCODE_KEYBINDINGS, 'utf8');
  if (text.includes('ctrl+alt+shift+cmd+k')) return 'present';
  // The file is JSON with comments: insert right after the opening bracket (outside any comment),
  // so the user's own entries and comments stay exactly as they are.
  let open = -1;
  for (let i = 0, inLine = false, inBlock = false; i < text.length; i++) {
    const two = text.slice(i, i + 2);
    if (inLine) { if (text[i] === '\n') inLine = false; continue; }
    if (inBlock) { if (two === '*/') { inBlock = false; i++; } continue; }
    if (two === '//') { inLine = true; i++; continue; }
    if (two === '/*') { inBlock = true; i++; continue; }
    if (text[i] === '[') { open = i; break; }
  }
  if (open < 0) return 'unreadable';
  const rest = text.slice(open + 1);
  const empty = /^\s*(\/\/[^\n]*\n\s*|\/\*[\s\S]*?\*\/\s*)*\]/.test(rest);
  fs.writeFileSync(`${VSCODE_KEYBINDINGS}.ccremote-backup`, text);
  fs.writeFileSync(VSCODE_KEYBINDINGS, `${text.slice(0, open + 1)}\n  // Added by CC Remote (focus Claude's prompt box before typing a phone message)\n  ${FOCUS_BINDING}${empty ? '' : ','}${rest}`);
  return 'added';
}

// Walks through the macOS permissions Send to VS Code needs, while someone is at the Mac, so later
// phone messages work hands-free. Safe to re-run: granted permissions are just confirmed.
async function setupPermissions() {
  if (!fs.existsSync('/Applications/Visual Studio Code.app')) return;
  const ask = async (prompt) => (await fetch(`http://127.0.0.1:${LOCAL_PORT}/ctl/permissions${prompt ? '?prompt=1' : ''}`, {
    headers: { 'X-Secret': readSecret() }, signal: AbortSignal.timeout(120000),
  }).then(r => r.json()).catch(() => null));
  const pane = name => execFileSync('/usr/bin/open', [`x-apple.systempreferences:com.apple.preference.security?Privacy_${name}`]);

  console.log(`\n${c.o('▸')} ${c.b('Permissions for typing phone messages into VS Code')}`);
  console.log(c.d('  If macOS asks whether "node" may control "System Events", click Allow.'));
  let p = await ask(true);
  if (!p) { console.log(c.r('  Could not reach the bridge to check permissions; run: ccr permissions')); return; }
  if (p.automation !== 'granted') {
    console.log(`  ${c.r('✗')} Control of "System Events" isn't allowed yet.`);
    console.log('    System Settings → Privacy & Security → Automation → node → turn on "System Events".');
    try { pane('Automation'); } catch {}
    for (let i = 0; i < 90 && p?.automation !== 'granted'; i++) { await sleep(2000); p = await ask(false); }
    if (p?.automation !== 'granted') { console.log(c.r('  Still not allowed. Run ccr permissions later.')); return; }
  }
  console.log(`  ${c.g('✓')} Control of "System Events"`);
  if (!p.accessibility) {
    console.log(`  ${c.o('→')} Turn on ${c.b('node')} in the Accessibility list that just opened.`);
    console.log(c.d(`    Not in the list? Click +, press ⌘⇧G, paste ${p.node} and click Open.`));
    try { pane('Accessibility'); } catch {}
    process.stdout.write(c.d('    Waiting…'));
    for (let i = 0; i < 90 && !p?.accessibility; i++) { await sleep(2000); p = await ask(false); }
    console.log('\r' + ' '.repeat(20) + '\r');
    if (!p?.accessibility) { console.log(c.r('  Accessibility is still off. Turn it on, then run: ccr permissions')); return; }
  }
  console.log(`  ${c.g('✓')} Accessibility`);
  console.log(c.g('  All set: phone messages can be typed into VS Code without anyone at the Mac.'));
}

function launchctl(...args) {
  try { execFileSync('/bin/launchctl', args, { stdio: 'ignore' }); return true; } catch { return false; }
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function bridgeAnswers() {
  const res = await fetch(`http://127.0.0.1:${LOCAL_PORT}/ctl/status`, {
    headers: { 'X-Secret': readSecret() }, signal: AbortSignal.timeout(1500),
  }).catch(() => null);
  return !!res?.ok;
}

// bootout returns before launchd has finished unloading the job, and bootstrapping too early fails
// silently. Wait for the unload, retry the load, and only report success once the bridge answers.
async function startService() {
  const target = `gui/${UID}/${LABEL}`;
  launchctl('bootout', target);
  for (let i = 0; i < 20 && launchctl('print', target); i++) await sleep(250);
  for (let i = 0; i < 8; i++) {
    if (launchctl('bootstrap', `gui/${UID}`, PLIST) || launchctl('print', target)) break;
    await sleep(500);
  }
  launchctl('kickstart', target);
  for (let i = 0; i < 30; i++) {
    if (await bridgeAnswers()) return true;
    await sleep(300);
  }
  return false;
}

async function install() {
  ensureStateDir();
  fs.mkdirSync(path.dirname(HOOK_CMD), { recursive: true });
  fs.copyFileSync(path.join(HERE, 'bin/ccr-hook'), HOOK_CMD);
  fs.chmodSync(HOOK_CMD, 0o755);

  const backup = editHooks(true);
  console.log(`${c.g('✓')} Claude Code hooks installed  ${c.d(backup ? `(old settings saved to ${backup})` : '(already up to date)')}`);

  fs.mkdirSync(path.dirname(PLIST), { recursive: true });
  fs.writeFileSync(PLIST, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>${NODE}</string><string>${path.join(HERE, 'server.js')}</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${path.join(STATE_DIR, 'launchd.out.log')}</string>
  <key>StandardErrorPath</key><string>${path.join(STATE_DIR, 'launchd.err.log')}</string>
</dict></plist>
`);
  if (!await startService()) {
    console.error(`${c.r('✗')} The bridge did not start. See ${path.join(STATE_DIR, 'launchd.err.log')}, then run: ccr install`);
    process.exit(1);
  }
  console.log(`${c.g('✓')} Bridge running in the background (starts at login)`);
  const kb = addVSCodeKeybinding();
  if (kb === 'added' || kb === 'present') console.log(`${c.g('✓')} VS Code shortcut for typing phone messages into Claude ${c.d(`(${VSCODE_KEYBINDINGS})`)}`);

  // Small wrapper scripts rather than symlinks, so ccr runs with the same node that installed it
  // (which may be a private copy that isn't on PATH).
  fs.mkdirSync(BIN_DIR, { recursive: true });
  const wrappers = {
    ccr: `#!/bin/sh\nexec "${NODE}" "${path.join(HERE, 'ccr.js')}" "$@"\n`,
    cc: `#!/bin/sh\nexec "${path.join(HERE, 'bin/cc')}" "$@"\n`,
  };
  for (const [name, body] of Object.entries(wrappers)) {
    const file = path.join(BIN_DIR, name);
    try { fs.unlinkSync(file); } catch {}
    fs.writeFileSync(file, body, { mode: 0o755 });
  }
  if (BIN_DIR === path.join(STATE_DIR, 'bin')) {
    const line = `export PATH="${BIN_DIR}:$PATH"`;
    const zprofile = path.join(os.homedir(), '.zprofile');
    const current = fs.existsSync(zprofile) ? fs.readFileSync(zprofile, 'utf8') : '';
    if (!current.includes(line)) fs.appendFileSync(zprofile, `\n# CC Remote commands (ccr, cc)\n${line}\n`);
    console.log(c.d(`  (open a new Terminal window for the ccr and cc commands to work)`));
  }
  console.log(`${c.g('✓')} Commands available: ${c.b('ccr')} (control) and ${c.b('cc')} (Claude in a terminal session, with live mirror)`);
  await setupPermissions();
  console.log(`\nNext: run ${c.o('ccr pair')} and type the code into the iPhone app.`);
}

function uninstall() {
  const backup = editHooks(false);
  launchctl('bootout', `gui/${UID}/${LABEL}`);
  try { fs.unlinkSync(PLIST); } catch {}
  for (const n of ['ccr', 'cc']) try { fs.unlinkSync(path.join(BIN_DIR, n)); } catch {}
  console.log(`Removed hooks and background service.${backup ? ` Settings backup: ${backup}` : ''}`);
  console.log(c.d(`Pairings and keys are kept in ${STATE_DIR}; delete that folder to forget everything.`));
}

function bigDigits(code) {
  const font = {
    0: ['█▀█', '█ █', '▀▀▀'], 1: ['▀█ ', ' █ ', '▀▀▀'], 2: ['▀▀█', '█▀▀', '▀▀▀'], 3: ['▀▀█', ' ▀█', '▀▀▀'],
    4: ['█ █', '▀▀█', '  ▀'], 5: ['█▀▀', '▀▀█', '▀▀▀'], 6: ['█▀▀', '█▀█', '▀▀▀'], 7: ['▀▀█', '  █', '  ▀'],
    8: ['█▀█', '█▀█', '▀▀▀'], 9: ['█▀█', '▀▀█', '▀▀▀'],
  };
  return [0, 1, 2].map(row => '   ' + [...code].map((d, i) => font[d][row] + (i === 2 ? '    ' : '  ')).join('')).join('\n');
}

async function pair() {
  const before = (await api('GET', '/ctl/status')).devices.length;
  const p = await api('POST', '/ctl/pair');
  console.log(`\n  ${c.o('CC Remote')} pairing code for ${c.b(p.host)}\n`);
  console.log(c.o(bigDigits(p.code)));
  console.log(`\n   ${c.b(p.code.slice(0, 3) + ' ' + p.code.slice(3))}   ${c.d('valid for 5 minutes, one use')}\n`);
  console.log(`  The app finds this Mac automatically on the same Wi-Fi.`);
  console.log(`  Manual address: ${p.ips.map(i => c.b(`${i.address}:${p.port}`)).join('  ') || c.r('no LAN address')}`);
  console.log(c.d(`  Security code: ${p.fingerprint.slice(0, 4)} ${p.fingerprint.slice(4, 8)} ${p.fingerprint.slice(8, 12)} (the app shows the same after pairing)\n`));
  process.stdout.write(c.d('  Waiting for the phone… (Ctrl-C to stop)'));
  while (Date.now() < p.expiresAt) {
    await new Promise(r => setTimeout(r, 1500));
    const s = await api('GET', '/ctl/status');
    if (s.devices.length > before) {
      console.log(`\r  ${c.g('✓ Paired with ' + s.devices.at(-1).name)}                        \n`);
      return;
    }
  }
  console.log(`\n  ${c.r('Code expired.')} Run ccr pair again.`);
}

async function status() {
  const s = await api('GET', '/ctl/status');
  console.log(`${c.o('CC Remote')} on ${c.b(s.mac)}  away: ${s.away ? c.o('yes') : 'no'} (mode ${s.awayMode}, Mac idle ${s.idleSec}s)`);
  console.log(`phones connected: ${s.clients}   paired: ${s.devices.map(d => d.name).join(', ') || 'none'}`);
  console.log(`addresses: ${s.ips.map(i => `${i.address}:${s.port}`).join('  ')}`);
  console.log(`notifications: ntfy topic ${c.b(s.ntfyTopic)}`);
  console.log(`\nsessions:`);
  if (!s.sessions.length) console.log(c.d('  none yet. They appear on their next activity (new prompt, tool call, or start).'));
  for (const x of s.sessions) {
    console.log(`  ${c.b(x.project.padEnd(22))} ${x.status.padEnd(17)} ${x.hasMirror ? 'tmux ' : x.entrypoint.padEnd(5)}  ${c.d((x.activity ?? x.title ?? '').slice(0, 60))}`);
  }
}

async function devicesCmd(args) {
  const devices = JSON.parse(fs.readFileSync(DEVICES_FILE, 'utf8') || '[]');
  if (args[0] !== 'unpair') {
    for (const d of devices) console.log(`${d.id.slice(0, 8)}  ${d.name.padEnd(24)} paired ${d.created.slice(0, 10)}  last seen ${d.lastSeen?.slice(0, 16) ?? 'never'}`);
    if (!devices.length) console.log('No paired devices.');
    return;
  }
  const which = args[1];
  const keep = which === 'all' ? [] : devices.filter(d => !d.id.startsWith(which ?? '\0'));
  fs.writeFileSync(DEVICES_FILE, JSON.stringify(keep, null, 2), { mode: 0o600 });
  await api('POST', '/ctl/reload');
  console.log(`Removed ${devices.length - keep.length} device(s).`);
}

const [cmd, ...args] = process.argv.slice(2);
switch (cmd) {
  case 'install': await install(); break;
  case 'uninstall': uninstall(); break;
  case 'start': await import('./server.js'); break;
  case 'restart': {
    if (!launchctl('kickstart', '-k', `gui/${UID}/${LABEL}`)) await startService();
    let up = false;
    for (let i = 0; i < 30 && !(up = await bridgeAnswers()); i++) await sleep(300);
    console.log(up ? 'restarted' : c.r('bridge did not come back; run: ccr install'));
    break;
  }
  case 'pair': await pair(); break;
  case 'status': case undefined: await status(); break;
  case 'away': {
    const mode = args[0] ?? 'on';
    const r = await api('POST', '/ctl/away', { mode });
    console.log(r.error ?? `away mode: ${r.awayMode} (currently ${r.away ? 'away' : 'at Mac'})`);
    break;
  }
  case 'permissions': await setupPermissions(); break;
  case 'test-notify': {
    const r = await api('POST', '/ctl/test-notify');
    if (r.error) { console.log(c.r(`ntfy didn't accept it: ${r.error}`)); break; }
    console.log(`${c.g('✓')} Sent to ntfy (message ${r.id}). Your iPhone should show it within a few seconds.`);
    console.log(c.d(`  Not arriving? In the ntfy app, subscribe to topic ${r.topic} on ntfy.sh and allow ntfy's notifications.`));
    break;
  }
  case 'devices': await devicesCmd(args); break;
  case 'unpair': await devicesCmd(['unpair', ...args]); break;
  case 'logs': execFileSync('/usr/bin/tail', ['-n', '60', '-f', LOG_FILE], { stdio: 'inherit' }); break;
  default:
    console.log(`ccr: CC Remote bridge

  ccr install          install hooks + background bridge + cc/ccr commands
  ccr pair             show a 6-digit code to pair the iPhone
  ccr status           sessions, away state, connected phones
  ccr away on|off|auto hold prompts for the phone (auto = when Mac idle ${'>'}2 min)
  ccr devices          list paired phones;  ccr unpair <id|all>
  ccr permissions      check/ask for the macOS permissions VS Code typing needs
  ccr test-notify      send a test notification to the phone (via ntfy)
  ccr logs | restart | uninstall | start (foreground)`);
}

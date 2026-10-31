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
// Homebrew's bin is on PATH on both Apple Silicon (/opt/homebrew) and Intel (/usr/local) Macs.
const BIN_DIR = ['/opt/homebrew/bin', '/usr/local/bin'].find(d => fs.existsSync(d)) ?? '/usr/local/bin';
const UID = process.getuid();

// Event -> hook timeout (s). Holding events get long timeouts so the phone has time to answer.
const HOOKS = {
  SessionStart: 10,
  UserPromptSubmit: 10,
  PreToolUse: 3660,
  PostToolUse: 10,
  PermissionRequest: 3660,
  Notification: 10,
  Stop: 900,
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
  const backup = `${SETTINGS}.ccremote-backup-${new Date().toISOString().replace(/[:.]/g, '-')}`;
  fs.writeFileSync(backup, raw);
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
  fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + '\n');
  return backup;
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
  console.log(`${c.g('✓')} Claude Code hooks installed  ${c.d(`(old settings saved to ${backup})`)}`);

  fs.mkdirSync(path.dirname(PLIST), { recursive: true });
  fs.writeFileSync(PLIST, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>${process.execPath}</string><string>${path.join(HERE, 'server.js')}</string>
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

  for (const [name, target] of [['ccr', path.join(HERE, 'ccr.js')], ['cc', path.join(HERE, 'bin/cc')]]) {
    const link = path.join(BIN_DIR, name);
    try { fs.unlinkSync(link); } catch {}
    fs.symlinkSync(target, link);
  }
  console.log(`${c.g('✓')} Commands available: ${c.b('ccr')} (control) and ${c.b('cc')} (Claude in tmux, with live mirror)`);
  console.log(`\nNext: run ${c.o('ccr pair')} and type the code into the iPhone app.`);
}

function uninstall() {
  const backup = editHooks(false);
  launchctl('bootout', `gui/${UID}/${LABEL}`);
  try { fs.unlinkSync(PLIST); } catch {}
  for (const n of ['ccr', 'cc']) try { fs.unlinkSync(path.join(BIN_DIR, n)); } catch {}
  console.log(`Removed hooks and background service. Settings backup: ${backup}`);
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
  ccr logs | restart | uninstall | start (foreground)`);
}

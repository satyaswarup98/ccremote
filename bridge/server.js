// CC Remote bridge: receives Claude Code hook events on loopback, serves the paired iPhone over TLS.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { WebSocketServer } from 'ws';
import {
  STATE_DIR, TLS_DIR, DEVICES_FILE, LOG_FILE, LOCAL_PORT,
  ensureStateDir, loadConfig, saveConfig, readSecret, certFingerprint,
} from './lib/paths.js';
import { TranscriptTail, toolSummary, PHONE_PREFIX } from './lib/transcript.js';
import { macIdleSeconds, findClaudeBinary, tmux, hostName } from './lib/system.js';

ensureStateDir();
let config = loadConfig();
const SECRET = readSecret();
const FINGERPRINT = certFingerprint();
const HOST = hostName();

function log(...args) {
  const line = `[${new Date().toISOString()}] ${args.join(' ')}`;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch {}
}

// ---------- devices & pairing ----------

const sha = s => crypto.createHash('sha256').update(s).digest('hex');
let devices = (() => { try { return JSON.parse(fs.readFileSync(DEVICES_FILE, 'utf8')); } catch { return []; } })();
const saveDevices = () => fs.writeFileSync(DEVICES_FILE, JSON.stringify(devices, null, 2), { mode: 0o600 });

let pairing = null; // { code, expiresAt, failures }

function startPairing() {
  pairing = { code: String(crypto.randomInt(0, 1e6)).padStart(6, '0'), expiresAt: Date.now() + 5 * 60e3, failures: 0 };
  log('pairing code issued');
  return pairing;
}

// The phone proves it knows the code and binds it to the certificate it actually saw:
// proof = HMAC-SHA256(key = code, msg = cert fingerprint hex). A different cert gives a different proof.
function tryPair(proof, deviceName) {
  if (!pairing || Date.now() > pairing.expiresAt) return { error: 'No active pairing code. Run `ccr pair` on the Mac.' };
  const expected = crypto.createHmac('sha256', pairing.code).update(FINGERPRINT).digest('hex');
  const ok = typeof proof === 'string' && proof.length === expected.length
    && crypto.timingSafeEqual(Buffer.from(proof), Buffer.from(expected));
  if (!ok) {
    pairing.failures += 1;
    if (pairing.failures >= 5) { pairing = null; log('pairing code burned after 5 failures'); }
    return { error: 'Wrong code.' };
  }
  pairing = null;
  const token = crypto.randomBytes(32).toString('base64url');
  const device = { id: crypto.randomUUID(), name: String(deviceName || 'iPhone').slice(0, 60), tokenHash: sha(token), created: new Date().toISOString(), lastSeen: null };
  devices.push(device);
  saveDevices();
  setTimeout(tickIdle, 0);
  log(`paired device "${device.name}"`);
  return { token, deviceId: device.id, macName: HOST };
}

function deviceForToken(token) {
  if (!token) return null;
  const h = sha(token);
  return devices.find(d => d.tokenHash === h) ?? null;
}

// ---------- away detection ----------

let idleSec = 0;
let away = false;

function computeAway() {
  // Holding a prompt only makes sense once there is a phone to answer it.
  if (!devices.length) return false;
  if (config.awayMode === 'on') return true;
  if (config.awayMode === 'off') return false;
  return idleSec >= config.idleThresholdSec;
}

async function tickIdle() {
  idleSec = await macIdleSeconds();
  const was = away;
  away = computeAway();
  if (was && !away && config.awayMode === 'auto' && idleSec < 5) {
    // Back at the keyboard: hand back holds the Mac can't show on its own (permission dialogs already show there).
    let n = 0;
    for (const p of [...pending.values()]) if (p.info.kind !== 'permission') { p.resolve(null); n++; }
    if (n) log(`released ${n} held request(s): back at Mac`);
  }
  if (was !== away) broadcastState();
}
setInterval(tickIdle, 2000);

// ---------- sessions & pending requests ----------

const sessions = new Map();   // sessionId -> session
const pending = new Map();    // requestId -> { info, resolve, timer }
const queued = new Map();     // sessionId -> [text] waiting for the next Stop
const tails = new Map();      // sessionId -> TranscriptTail
const launches = new Map();   // CCR_ORIGIN token -> { ws, placeholderId, title } for sessions started from the phone

// Starts claude in tmux and immediately shows it on the phone as a "Starting…" session with a live
// terminal, so first-run questions (like folder trust) can be answered from the phone. Claude's
// hooks only start once those are answered; SessionStart then swaps in the real session.
async function launchTerminal(ws, cwd, args, title) {
  const bin = findClaudeBinary();
  if (!bin) return toast(ws, 'Could not find the claude binary on the Mac.', 'error');
  const origin = crypto.randomBytes(8).toString('hex');
  let pane;
  try {
    ({ pane } = await tmux.newSession(cwd, bin, args, { CCR_ORIGIN: origin }));
  } catch (e) {
    return toast(ws, `tmux failed: ${e.message}`, 'error');
  }
  const placeholderId = `launch-${origin}`;
  sessions.set(placeholderId, {
    id: placeholderId, cwd, project: path.basename(cwd) || '~', title, entrypoint: 'cli', tmuxPane: pane,
    status: 'working', activity: 'Starting Claude…', lastMessage: null, lastPrompt: null, permissionMode: null,
    startedAt: Date.now(), updatedAt: Date.now(), transcriptPath: null, lastHookAt: Date.now(), placeholder: true,
  });
  launches.set(origin, { ws, placeholderId, title });
  setTimeout(() => {
    if (!launches.has(origin)) return;
    launches.delete(origin);
    sessions.delete(placeholderId);
    broadcastState();
  }, 30 * 60e3);
  broadcastState();
  setTimeout(() => { if (ws.readyState === 1) ws.send(JSON.stringify({ t: 'opened', sessionId: placeholderId })); }, 150);
  log(`launched ${title} in ${cwd} (${pane})`);
}

function upsertSession(ev, headers) {
  const id = ev.session_id;
  if (!id) return null;
  let s = sessions.get(id);
  if (!s) {
    s = {
      id, cwd: ev.cwd, project: path.basename(ev.cwd || '') || '~', title: null,
      entrypoint: headers['x-entrypoint'] || 'cli', tmuxPane: null, status: 'idle',
      activity: null, lastMessage: null, lastPrompt: null, permissionMode: null,
      startedAt: Date.now(), updatedAt: Date.now(), transcriptPath: null,
    };
    sessions.set(id, s);
  }
  if (ev.cwd) { s.cwd = ev.cwd; s.project = path.basename(ev.cwd) || '~'; }
  if (ev.transcript_path) s.transcriptPath = ev.transcript_path;
  if (ev.permission_mode) s.permissionMode = ev.permission_mode;
  const pane = headers['x-tmux-pane'];
  if (pane && /^%\d+$/.test(pane)) s.tmuxPane = pane;
  if (headers['x-entrypoint']) s.entrypoint = headers['x-entrypoint'];
  s.updatedAt = Date.now();
  s.lastHookAt = Date.now();
  return s;
}

// Claude Code writes one ~/.claude/sessions/<pid>.json per running session. Reading it lets the phone
// see sessions that have been quiet since the bridge started, and notice when their process exits.
const REGISTRY_DIR = path.join(os.homedir(), '.claude/sessions');
const PROJECTS_DIR = path.join(os.homedir(), '.claude/projects');

function findTranscript(sessionId) {
  try {
    for (const d of fs.readdirSync(PROJECTS_DIR)) {
      const f = path.join(PROJECTS_DIR, d, `${sessionId}.jsonl`);
      if (fs.existsSync(f)) return f;
    }
  } catch {}
  return null;
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

function scanRegistry() {
  let files = [];
  try { files = fs.readdirSync(REGISTRY_DIR).filter(f => f.endsWith('.json')); } catch { return; }
  const alive = new Set();
  let changed = false;
  for (const f of files) {
    let r;
    try { r = JSON.parse(fs.readFileSync(path.join(REGISTRY_DIR, f), 'utf8')); } catch { continue; }
    if (!r.sessionId || !r.pid || !pidAlive(r.pid)) continue;
    alive.add(r.sessionId);
    let s = sessions.get(r.sessionId);
    if (!s) {
      s = {
        id: r.sessionId, cwd: r.cwd, project: path.basename(r.cwd || '') || '~', title: null,
        entrypoint: r.entrypoint || 'cli', tmuxPane: null, status: 'idle', activity: null,
        lastMessage: null, lastPrompt: null, permissionMode: null, startedAt: r.startedAt ?? Date.now(),
        updatedAt: r.statusUpdatedAt ?? r.updatedAt ?? r.startedAt ?? Date.now(),
        transcriptPath: findTranscript(r.sessionId), lastHookAt: 0,
      };
      sessions.set(s.id, s);
      pollTranscript(s);
      changed = true;
    }
    s.pid = r.pid;
    s.name = r.name ?? null;
    // Hooks know more (approvals, tool activity); the registry only fills in when hooks are quiet.
    if (Date.now() - (s.lastHookAt ?? 0) > 15e3 && s.status !== 'ended') {
      const st = r.status === 'busy' ? 'working' : 'idle';
      if (st !== s.status) { s.status = st; if (st === 'idle') s.activity = null; changed = true; }
    }
  }
  for (const s of sessions.values()) {
    if (s.pid && !alive.has(s.id) && s.status !== 'ended') {
      s.status = 'ended';
      s.activity = null;
      s.updatedAt = Date.now();
      releaseSession(s.id);
      changed = true;
    }
  }
  for (const s of [...sessions.values()]) {
    if (s.placeholder) tmux.paneAlive(s.tmuxPane).then(ok => { if (!ok && sessions.delete(s.id)) broadcastState(); });
  }
  if (changed) broadcastState();
}
setInterval(scanRegistry, 4000);

function sessionView(s) {
  const reqs = [...pending.values()].map(p => p.info).filter(i => i.sessionId === s.id);
  let status = s.status;
  if (reqs.some(r => r.kind === 'permission')) status = 'needs_permission';
  else if (reqs.some(r => r.kind === 'question')) status = 'needs_answer';
  else if (reqs.some(r => r.kind === 'stop')) status = 'waiting_input';
  const tail = tails.get(s.id);
  return {
    id: s.id, cwd: s.cwd, project: s.project, title: tail?.title ?? s.title ?? s.name ?? null,
    entrypoint: s.entrypoint, hasMirror: !!s.tmuxPane, status, activity: s.activity,
    lastMessage: s.lastMessage, lastPrompt: s.lastPrompt, permissionMode: s.permissionMode,
    updatedAt: s.updatedAt, queued: (queued.get(s.id) ?? []).length,
    holdingForPhone: reqs.some(r => r.kind === 'stop'),
  };
}

function suggestionLabel(sug) {
  if (sug.type === 'addRules') {
    const rules = (sug.rules ?? []).map(r => r.ruleContent ? `${r.toolName}(${r.ruleContent})` : r.toolName).join(', ');
    const where = { session: 'this session', localSettings: 'this project', projectSettings: 'this project', userSettings: 'all projects' }[sug.destination] ?? sug.destination;
    return `Always allow ${rules} (${where})`;
  }
  if (sug.type === 'setMode') return `Allow and switch to ${sug.mode} mode`;
  if (sug.type === 'addDirectories') return `Allow and add ${(sug.directories ?? []).join(', ')}`;
  return `Allow (${sug.type})`;
}

function holdRequest(info, maxMs, abort, key = null) {
  return new Promise(resolve => {
    const id = crypto.randomUUID();
    info.id = id;
    info.createdAt = Date.now();
    const finish = output => {
      const p = pending.get(id);
      if (!p) return;
      clearTimeout(p.timer);
      pending.delete(id);
      const s = sessions.get(info.sessionId);
      if (s) s.updatedAt = Date.now();
      broadcastState();
      resolve(output);
    };
    const timer = setTimeout(() => finish(null), maxMs);
    pending.set(id, { info, resolve: finish, timer, key });
    abort?.onClose(() => finish(null));
    broadcastState();
    notifyPhone(info);
  });
}

function releaseAll(reason) {
  let n = 0;
  for (const p of [...pending.values()]) { p.resolve(null); n++; }
  if (n) log(`released ${n}: ${reason}`);
  return n;
}

function releaseSession(sessionId, kinds = null) {
  for (const p of [...pending.values()]) {
    if (p.info.sessionId === sessionId && (!kinds || kinds.includes(p.info.kind))) p.resolve(null);
  }
}

// Permission prompts show on the Mac and the phone at once. Claude Code doesn't cancel the hook
// when you answer on the Mac, so infer it from what the session does next.
function clearAnsweredElsewhere(ev) {
  const kind = ev.hook_event_name;
  if (kind === 'PostToolUse' || kind === 'PostToolUseFailure') {
    const key = `${ev.tool_name}:${JSON.stringify(ev.tool_input ?? {})}`;
    for (const p of [...pending.values()]) if (p.info.sessionId === ev.session_id && p.key === key) p.resolve(null);
  } else if (kind === 'UserPromptSubmit' || kind === 'Stop' || kind === 'SessionEnd') {
    releaseSession(ev.session_id, ['permission']);
  }
}

const PERMISSION_HOLD_MS = 58 * 60e3; // hook timeout is 3660s

async function handleHook(ev, headers, abort) {
  const kind = ev.hook_event_name;
  const s = upsertSession(ev, headers);
  if (!s) return null;
  clearAnsweredElsewhere(ev);
  pollTranscript(s);

  switch (kind) {
    case 'SessionStart': {
      s.status = 'idle';
      s.activity = null;
      broadcastState();
      const origin = headers['x-ccr-origin'];
      const launch = origin && launches.get(origin);
      if (launch) {
        launches.delete(origin);
        sessions.delete(launch.placeholderId);
        if (!s.title) s.title = launch.title;
        broadcastState();
        // Anyone watching the placeholder moves to the real session.
        for (const [cws, c] of clients) {
          if ((cws === launch.ws || c.subscribed === launch.placeholderId) && cws.readyState === 1) {
            setTimeout(() => cws.send(JSON.stringify({ t: 'opened', sessionId: s.id })), 150);
          }
        }
      }
      return null;
    }

    case 'UserPromptSubmit':
      s.idlePinged = false;
      s.status = 'working';
      s.lastPrompt = String(ev.prompt ?? '').slice(0, 500);
      s.activity = 'Thinking…';
      broadcastState();
      return null;

    case 'PreToolUse': {
      s.status = 'working';
      s.activity = `${ev.tool_name}: ${toolSummary(ev.tool_name, ev.tool_input)}`.slice(0, 200);
      broadcastState();
      if (ev.tool_name !== 'AskUserQuestion') return null;
      if (!away) {
        notifyPhone({ kind: 'question', sessionId: s.id, project: s.project, questions: ev.tool_input?.questions ?? [], answerable: false });
        return null;
      }
      const answers = await holdRequest({
        kind: 'question', sessionId: s.id, project: s.project, answerable: true,
        toolName: ev.tool_name, questions: ev.tool_input?.questions ?? [],
      }, PERMISSION_HOLD_MS, abort);
      if (!answers) return null;
      return {
        hookSpecificOutput: {
          hookEventName: 'PreToolUse', permissionDecision: 'allow',
          updatedInput: { ...ev.tool_input, answers },
        },
      };
    }

    case 'PostToolUse':
    case 'PostToolUseFailure':
      s.status = 'working';
      s.activity = 'Thinking…';
      broadcastState();
      return null;

    case 'PermissionRequest': {
      const suggestions = Array.isArray(ev.permission_suggestions) ? ev.permission_suggestions : [];
      const info = {
        kind: 'permission', sessionId: s.id, project: s.project, toolName: ev.tool_name,
        summary: toolSummary(ev.tool_name, ev.tool_input).slice(0, 2000),
        detail: permissionDetail(ev.tool_name, ev.tool_input),
        suggestions: suggestions.map((sug, i) => ({ index: i, label: suggestionLabel(sug) })),
        answerable: true,
      };
      if (!devices.length) return null;
      s.activity = `Waiting for approval: ${ev.tool_name}`;
      const decision = await holdRequest(info, PERMISSION_HOLD_MS, abort, `${ev.tool_name}:${JSON.stringify(ev.tool_input ?? {})}`);
      if (!decision) return null;
      if (decision.behavior === 'allow') {
        const out = { behavior: 'allow' };
        if (ev.tool_name === 'ExitPlanMode') out.updatedInput = ev.tool_input ?? {};
        if (Number.isInteger(decision.suggestion) && suggestions[decision.suggestion]) {
          out.updatedPermissions = [suggestions[decision.suggestion]];
        }
        return { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: out } };
      }
      return {
        hookSpecificOutput: {
          hookEventName: 'PermissionRequest',
          decision: {
            behavior: 'deny',
            message: decision.message ? `Denied from phone: ${decision.message}` : 'The user denied this from their phone.',
            interrupt: !!decision.interrupt,
          },
        },
      };
    }

    case 'Notification': {
      const type = ev.notification_type;
      if (type === 'idle_prompt') { s.status = 'idle'; broadcastState(); }
      // Permission prompts are already announced by PermissionRequest; turn ends by Stop.
      if (type === 'permission_prompt' || type === 'agent_completed') return null;
      if (type === 'idle_prompt') {
        // Already pinged by Stop (or by the held reply) for this turn.
        if (!s.idlePinged) notifyPhone({ kind: 'waiting', sessionId: s.id, project: s.project, summary: ev.message ?? '' });
        s.idlePinged = true;
      } else if (ev.message) {
        notifyPhone({ kind: 'notice', sessionId: s.id, project: s.project, summary: ev.message });
      }
      return null;
    }

    case 'Stop': {
      s.status = 'idle';
      s.activity = null;
      if (ev.last_assistant_message) s.lastMessage = String(ev.last_assistant_message).slice(0, 4000);
      const q = queued.get(s.id);
      if (q?.length) {
        const text = q.shift();
        broadcastState();
        return phoneMessageOutput(text);
      }
      broadcastState();
      s.idlePinged = true;
      // tmux sessions take phone messages as real keystrokes, so there's no reason to hold them.
      if (!away || s.tmuxPane) {
        notifyPhone({ kind: 'done', sessionId: s.id, project: s.project, summary: (s.lastMessage ?? 'Claude finished.').slice(0, 300) });
        return null;
      }
      const reply = await holdRequest({
        kind: 'stop', sessionId: s.id, project: s.project,
        summary: (s.lastMessage ?? 'Claude finished.').slice(0, 300),
      }, config.stopHoldSec * 1000, abort);
      if (!reply) return null;
      s.status = 'working';
      s.activity = 'Thinking…';
      s.lastPrompt = reply.slice(0, 500);
      broadcastState();
      return phoneMessageOutput(reply);
    }

    case 'SessionEnd':
      releaseSession(s.id);
      s.status = 'ended';
      s.activity = null;
      broadcastState();
      return null;

    default:
      return null;
  }
}

function phoneMessageOutput(text) {
  return {
    hookSpecificOutput: {
      hookEventName: 'Stop',
      additionalContext: `${PHONE_PREFIX}\n\n${text}`,
    },
  };
}

function permissionDetail(tool, input = {}) {
  if (tool === 'Edit') return { type: 'diff', file: input.file_path, old: String(input.old_string ?? '').slice(0, 4000), new: String(input.new_string ?? '').slice(0, 4000) };
  if (tool === 'Write') return { type: 'file', file: input.file_path, text: String(input.content ?? '').slice(0, 4000) };
  if (tool === 'Bash') return { type: 'command', text: String(input.command ?? ''), description: input.description ?? null };
  if (tool === 'ExitPlanMode') return { type: 'plan', text: String(input.plan ?? '').slice(0, 8000) };
  return { type: 'json', text: JSON.stringify(input, null, 2).slice(0, 4000) };
}

// ---------- transcript & screen mirror ----------

function pollTranscript(s) {
  if (!s.transcriptPath) return;
  let t = tails.get(s.id);
  if (!t || t.file !== s.transcriptPath) { t = new TranscriptTail(s.transcriptPath); tails.set(s.id, t); }
  const fresh = t.poll();
  if (fresh.length) sendToSubscribers(s.id, { t: 'items', sessionId: s.id, items: fresh, reset: false });
}

const lastScreen = new Map();
setInterval(() => {
  const watched = new Set([...clients.values()].map(c => c.subscribed).filter(Boolean));
  for (const id of watched) {
    const s = sessions.get(id);
    if (!s) continue;
    pollTranscript(s);
    if (s.tmuxPane) {
      tmux.capture(s.tmuxPane).then(text => {
        if (lastScreen.get(id) === text) return;
        lastScreen.set(id, text);
        sendToSubscribers(id, { t: 'screen', sessionId: id, text });
      }).catch(() => {});
    }
  }
}, 500);

// ---------- phone notifications (ntfy) ----------

function phoneInForeground() {
  return [...clients.values()].some(c => c.foreground);
}

// Markdown → one tidy paragraph for a notification body.
function plain(text, max = 180) {
  let t = String(text ?? '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/[*_`#>|]+/g, '')
    .replace(/^\s*[-•]\s+/gm, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (t.length <= max) return t;
  const cut = t.slice(0, max);
  const stop = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('? '), cut.lastIndexOf('! '));
  return (stop > max * 0.5 ? cut.slice(0, stop + 1) : cut.replace(/\s+\S*$/, '') + '…');
}

const NOTICE = {
  permission: { subtitle: 'Needs your approval', tag: 'lock', priority: 5 },
  question: { subtitle: 'Claude has a question', tag: 'question', priority: 5 },
  stop: { subtitle: 'Waiting for your reply', tag: 'speech_balloon', priority: 4 },
  done: { subtitle: 'Task complete', tag: 'white_check_mark', priority: 3 },
  waiting: { subtitle: 'Waiting for your input', tag: 'hourglass', priority: 4 },
  notice: { subtitle: 'Notification', tag: 'bell', priority: 3 },
};

function describe(info) {
  const s = sessions.get(info.sessionId);
  const sessionTitle = s ? (tails.get(s.id)?.title ?? s.title ?? s.name) : null;
  const title = sessionTitle ? `${info.project} · ${plain(sessionTitle, 40)}` : info.project;
  let body;
  switch (info.kind) {
    case 'permission':
      body = `${info.toolName} · ${plain(info.summary, 150)}`;
      break;
    case 'question': {
      const q = info.questions?.[0];
      body = q ? `${plain(q.question, 120)}\n${q.options.map(o => o.label).join('  ·  ')}` : 'Open to answer';
      if ((info.questions?.length ?? 0) > 1) body += `\n+${info.questions.length - 1} more`;
      break;
    }
    default:
      body = plain(info.summary, 180) || 'Open CC Remote';
  }
  if ((info.kind === 'question') && !info.answerable) body += '\nAnswer on the Mac';
  return { title, subtitle: NOTICE[info.kind]?.subtitle ?? '', body };
}

async function notifyPhone(info) {
  // Only phones paired with this Mac get anything; nothing is sent before pairing.
  if (!devices.length) return;
  const { title, subtitle, body } = describe(info);

  // App open: it shows a native banner (with Allow/Deny for approvals) from this event.
  const event = JSON.stringify({
    t: 'event', kind: info.kind, sessionId: info.sessionId, requestId: info.id ?? null,
    title, subtitle, body, answerable: !!info.answerable,
  });
  for (const [ws, c] of clients) if (c.foreground && ws.readyState === 1) ws.send(event);
  if (phoneInForeground() || !config.ntfyTopic) return;

  // App closed: push through ntfy. Turn-finished pings are skipped while you're typing on the Mac.
  if ((info.kind === 'done' || info.kind === 'waiting' || info.kind === 'notice') && idleSec < 20) return;
  const meta = NOTICE[info.kind] ?? NOTICE.notice;
  try {
    await fetch(config.ntfyServer, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        topic: config.ntfyTopic,
        title: `${subtitle} — ${title}`,
        message: config.ntfyDetail ? body : 'Open CC Remote',
        tags: [meta.tag],
        priority: meta.priority,
        click: `ccremote://session/${info.sessionId}`,
      }),
      signal: AbortSignal.timeout(5000),
    });
  } catch (e) {
    log('ntfy failed:', e.message);
  }
}

// ---------- phone protocol ----------

const clients = new Map(); // ws -> { device, subscribed, foreground }

function snapshot() {
  const list = [...sessions.values()]
    .filter(s => s.status !== 'ended' || Date.now() - s.updatedAt < 30 * 60e3)
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .map(sessionView);
  return {
    t: 'state', mac: HOST, away, awayMode: config.awayMode, idleThresholdSec: config.idleThresholdSec,
    ntfyTopic: config.ntfyTopic, ntfyServer: config.ntfyServer,
    sessions: list,
    pending: [...pending.values()].map(p => p.info).filter(i => i.kind !== 'stop'),
  };
}

let stateTimer = null;
function broadcastState() {
  if (stateTimer) return;
  stateTimer = setTimeout(() => {
    stateTimer = null;
    const msg = JSON.stringify(snapshot());
    for (const ws of clients.keys()) if (ws.readyState === 1) ws.send(msg);
  }, 60);
}

function sendToSubscribers(sessionId, obj) {
  const msg = JSON.stringify(obj);
  for (const [ws, c] of clients) if (c.subscribed === sessionId && ws.readyState === 1) ws.send(msg);
}

function toast(ws, text, level = 'info') {
  if (ws.readyState === 1) ws.send(JSON.stringify({ t: 'toast', text, level }));
}

async function onPhoneMessage(ws, c, m) {
  switch (m.t) {
    case 'fg':
      c.foreground = !!m.value;
      return;

    case 'subscribe': {
      c.subscribed = m.sessionId;
      const s = sessions.get(m.sessionId);
      if (!s) return;
      pollTranscript(s);
      const t = tails.get(s.id);
      ws.send(JSON.stringify({ t: 'items', sessionId: s.id, items: t ? t.items.slice(-200) : [], reset: true }));
      lastScreen.delete(s.id);
      return;
    }

    case 'unsubscribe':
      c.subscribed = null;
      return;

    case 'decide': {
      const p = pending.get(m.requestId);
      if (!p) return toast(ws, 'That request was already answered.');
      if (p.info.kind === 'permission') {
        log(`phone ${m.behavior} ${p.info.toolName} in ${p.info.project}`);
        p.resolve({ behavior: m.behavior === 'allow' ? 'allow' : 'deny', suggestion: m.suggestion, message: m.message, interrupt: m.interrupt });
      } else if (p.info.kind === 'question') {
        if (m.behavior === 'release') p.resolve(null);
        else p.resolve(m.answers ?? {});
      }
      return;
    }

    case 'send': {
      const s = sessions.get(m.sessionId);
      const text = String(m.text ?? '').trim();
      if (!s || !text) return;
      const hold = [...pending.values()].find(p => p.info.sessionId === s.id && p.info.kind === 'stop');
      if (m.mode === 'fork' && !hold) {
        // Idle VS Code session: run the message now in a terminal copy of the conversation.
        const title = `Copy: ${tails.get(s.id)?.title ?? s.title ?? s.name ?? s.project}`;
        return launchTerminal(ws, s.cwd || os.homedir(), ['--resume', s.id, '--fork-session', text], title);
      }
      if (hold) {
        log(`phone message -> ${s.project} (via held Stop)`);
        return hold.resolve(text);
      }
      if (s.tmuxPane && await tmux.paneAlive(s.tmuxPane)) {
        log(`phone message -> ${s.project} (via tmux)`);
        await tmux.sendText(s.tmuxPane, text);
        return toast(ws, 'Sent');
      }
      const q = queued.get(s.id) ?? [];
      q.push(text);
      queued.set(s.id, q);
      broadcastState();
      return toast(ws, s.status === 'working'
        ? 'Queued: Claude gets it as soon as this turn finishes.'
        : 'Queued. This session is idle and not in tmux, so it gets the message the next time Claude stops. Turn on Away mode before you leave the Mac to keep sessions reachable.');
    }

    case 'unqueue':
      queued.delete(m.sessionId);
      broadcastState();
      return;

    case 'keys': {
      const s = sessions.get(m.sessionId);
      if (s?.tmuxPane) await tmux.sendKeys(s.tmuxPane, Array.isArray(m.keys) ? m.keys.slice(0, 20) : []);
      return;
    }

    case 'setAway':
      if (['auto', 'on', 'off'].includes(m.mode)) {
        config = { ...loadConfig(), awayMode: m.mode };
        saveConfig(config);
        await tickIdle();
        broadcastState();
      }
      return;

    case 'recentDirs':
      return ws.send(JSON.stringify({ t: 'recentDirs', dirs: recentDirs() }));

    case 'newSession': {
      const cwd = String(m.cwd ?? '');
      if (!cwd.startsWith('/') || !fs.existsSync(cwd)) return toast(ws, 'That folder does not exist on the Mac.', 'error');
      return launchTerminal(ws, cwd, [], `New session in ${path.basename(cwd)}`);
    }
  }
}

function recentDirs() {
  const seen = new Map();
  for (const s of sessions.values()) seen.set(s.cwd, s.updatedAt);
  const root = path.join(process.env.HOME, '.claude/projects');
  try {
    for (const d of fs.readdirSync(root)) {
      const full = path.join(root, d);
      const files = fs.readdirSync(full).filter(f => f.endsWith('.jsonl'));
      if (!files.length) continue;
      const newest = files.map(f => path.join(full, f)).sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0];
      const cwd = readCwd(newest);
      if (cwd && fs.existsSync(cwd) && !seen.has(cwd)) seen.set(cwd, fs.statSync(newest).mtimeMs);
    }
  } catch {}
  return [...seen.entries()].filter(([d]) => d).sort((a, b) => b[1] - a[1]).slice(0, 15).map(([d]) => d);
}

function readCwd(file) {
  try {
    const fd = fs.openSync(file, 'r');
    const buf = Buffer.alloc(64 * 1024);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    const m = buf.toString('utf8', 0, n).match(/"cwd":"((?:[^"\\]|\\.)*)"/);
    return m ? JSON.parse(`"${m[1]}"`) : null;
  } catch { return null; }
}

// ---------- servers ----------

function readBody(req, limit = 2 << 20) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', c => { size += c.length; if (size > limit) { reject(new Error('too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const json = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(obj == null ? '' : JSON.stringify(obj)); };

// Loopback: hook script and ccr CLI. Both send the shared secret from ~/.ccremote/hook.secret.
const local = http.createServer(async (req, res) => {
  if (req.headers['x-secret'] !== SECRET) return json(res, 403, { error: 'bad secret' });
  try {
    if (req.method === 'POST' && req.url === '/hook') {
      const ev = JSON.parse(await readBody(req));
      let aborted = false;
      const onClose = [];
      res.on('close', () => {
        if (res.writableFinished) return;
        aborted = true;
        onClose.forEach(fn => fn());
      });
      const out = await handleHook(ev, req.headers, { onClose: fn => onClose.push(fn) });
      if (aborted) return;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(out ? JSON.stringify(out) : '');
    }
    if (req.method === 'POST' && req.url === '/ctl/pair') {
      const p = startPairing();
      return json(res, 200, { code: p.code, expiresAt: p.expiresAt, fingerprint: FINGERPRINT, host: HOST, port: config.port, ips: lanAddresses() });
    }
    if (req.method === 'GET' && req.url === '/ctl/status') {
      return json(res, 200, { ...snapshot(), idleSec: Math.round(idleSec), devices: devices.map(({ tokenHash, ...d }) => d), fingerprint: FINGERPRINT, port: config.port, ips: lanAddresses(), clients: clients.size });
    }
    if (req.method === 'POST' && req.url === '/ctl/away') {
      const { mode } = JSON.parse(await readBody(req));
      if (!['auto', 'on', 'off'].includes(mode)) return json(res, 400, { error: 'mode must be auto|on|off' });
      config = { ...loadConfig(), awayMode: mode };
      saveConfig(config);
      await tickIdle();
      broadcastState();
      return json(res, 200, { awayMode: mode, away });
    }
    if (req.method === 'POST' && req.url === '/ctl/reload') {
      config = loadConfig();
      devices = (() => { try { return JSON.parse(fs.readFileSync(DEVICES_FILE, 'utf8')); } catch { return []; } })();
      for (const [ws, c] of clients) if (!devices.some(d => d.id === c.device.id)) ws.close(4001, 'unpaired');
      return json(res, 200, { ok: true });
    }
    json(res, 404, { error: 'not found' });
  } catch (e) {
    log('local error:', e.message);
    if (!res.headersSent) json(res, 500, { error: e.message });
  }
});
local.requestTimeout = 0;
local.headersTimeout = 10e3;
local.listen(LOCAL_PORT, '127.0.0.1', () => log(`hook endpoint on 127.0.0.1:${LOCAL_PORT}`));

const tlsServer = https.createServer({
  key: fs.readFileSync(path.join(TLS_DIR, 'key.pem')),
  cert: fs.readFileSync(path.join(TLS_DIR, 'cert.pem')),
}, async (req, res) => {
  log(`phone request ${req.method} ${req.url} from ${req.socket.remoteAddress}`);
  try {
    if (req.method === 'POST' && req.url === '/pair') {
      const body = JSON.parse(await readBody(req, 4096));
      const r = tryPair(body.proof, body.deviceName);
      if (r.error) log(`pairing rejected: ${r.error}`);
      return json(res, r.error ? 401 : 200, r);
    }
    if (req.method === 'GET' && req.url === '/info') {
      return json(res, 200, { app: 'ccremote', mac: HOST, pairing: !!pairing && Date.now() < pairing.expiresAt });
    }
    json(res, 404, { error: 'not found' });
  } catch (e) {
    json(res, 400, { error: e.message });
  }
});

tlsServer.on('tlsClientError', (err, socket) => log(`TLS error from ${socket.remoteAddress}: ${err.code ?? ''} ${err.message}`));

const wss = new WebSocketServer({ noServer: true, maxPayload: 1 << 20 });
tlsServer.on('upgrade', (req, socket, head) => {
  const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
  const device = deviceForToken(token);
  if (!device || !req.url.startsWith('/ws')) {
    socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    return socket.destroy();
  }
  wss.handleUpgrade(req, socket, head, ws => {
    const c = { device, subscribed: null, foreground: true };
    clients.set(ws, c);
    device.lastSeen = new Date().toISOString();
    saveDevices();
    log(`phone connected: ${device.name} (${req.socket.remoteAddress})`);
    ws.send(JSON.stringify(snapshot()));
    ws.on('message', data => {
      let m;
      try { m = JSON.parse(data.toString()); } catch { return; }
      onPhoneMessage(ws, c, m).catch(e => log('phone msg error:', e.message));
    });
    ws.on('close', () => { clients.delete(ws); log(`phone disconnected: ${device.name}`); });
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
  });
});

setInterval(() => {
  for (const ws of clients.keys()) {
    if (!ws.isAlive) { ws.terminate(); continue; }
    ws.isAlive = false;
    ws.ping();
  }
}, 20e3);

function lanAddresses() {
  const out = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs ?? []) if (a.family === 'IPv4' && !a.internal) out.push({ iface: name, address: a.address });
  }
  return out;
}

tlsServer.listen(config.port, '0.0.0.0', () => {
  log(`phone endpoint on https://0.0.0.0:${config.port} (cert ${FINGERPRINT.slice(0, 16)}…)`);
  // Advertise on Bonjour so the app finds the Mac without typing an IP.
  const dnssd = spawn('/usr/bin/dns-sd', ['-R', `CC Remote on ${HOST}`, '_ccremote._tcp', 'local', String(config.port), `fp=${FINGERPRINT.slice(0, 16)}`], { stdio: 'ignore' });
  process.on('exit', () => dnssd.kill());
});

for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { releaseAll('bridge shutting down'); setTimeout(() => process.exit(0), 100); });
log(`bridge started, state in ${STATE_DIR}, away mode ${config.awayMode}`);
tickIdle();
scanRegistry();

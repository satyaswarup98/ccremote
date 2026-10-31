import fs from 'node:fs';

// Turns Claude Code transcript JSONL into compact chat items for the phone.
// Item kinds: user, assistant, tool, result.

const MAX_TEXT = 6000;
export const PHONE_PREFIX = 'New message from the user, sent from their phone (CC Remote). Treat it exactly like a normal user prompt:';
const PHONE_MARKER = PHONE_PREFIX + '\n\n';
const MAX_RESULT = 600;

function clip(s, n) {
  if (typeof s !== 'string') return '';
  return s.length > n ? s.slice(0, n) + `… [+${s.length - n} chars]` : s;
}

export function toolSummary(name, input = {}) {
  switch (name) {
    case 'Bash': return input.command ?? '';
    case 'Read': case 'Write': case 'Edit': case 'NotebookEdit':
      return input.file_path ?? input.notebook_path ?? '';
    case 'Glob': case 'Grep': return input.pattern ?? '';
    case 'WebFetch': return input.url ?? '';
    case 'WebSearch': return input.query ?? '';
    case 'Agent': case 'Task': return input.description ?? '';
    case 'AskUserQuestion': return (input.questions ?? []).map(q => q.question).join(' / ');
    case 'TodoWrite': return `${(input.todos ?? []).length} todos`;
    default: {
      const v = Object.values(input).find(x => typeof x === 'string');
      return v ?? '';
    }
  }
}

function isNoise(text) {
  return /^\s*<(command-name|command-message|command-args|local-command-stdout|system-reminder|ide_selection|ide_opened_file)/.test(text)
    || text.startsWith('Caveat: The messages below');
}

function resultText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.filter(c => c.type === 'text').map(c => c.text).join('\n');
  return '';
}

export function parseLine(line) {
  let o;
  try { o = JSON.parse(line); } catch { return { items: [] }; }
  const out = { items: [] };
  if (o.type === 'ai-title' && o.aiTitle) out.title = o.aiTitle;
  // Messages delivered from the phone through the Stop hook: show them as the user's own bubbles.
  if (o.type === 'attachment' && o.attachment?.type === 'hook_additional_context' && !o.isSidechain) {
    for (const c of o.attachment.content ?? []) {
      const i = typeof c === 'string' ? c.indexOf(PHONE_MARKER) : -1;
      if (i >= 0) out.items.push({ id: o.uuid, kind: 'user', fromPhone: true, text: clip(c.slice(i + PHONE_MARKER.length), MAX_TEXT), ts: o.timestamp });
    }
    return out;
  }
  if ((o.type !== 'user' && o.type !== 'assistant') || o.isSidechain || o.isMeta) return out;
  const ts = o.timestamp;
  const content = o.message?.content;
  if (o.type === 'user') {
    if (typeof content === 'string') {
      if (!isNoise(content)) out.items.push({ id: o.uuid, kind: 'user', text: clip(content, MAX_TEXT), ts });
      return out;
    }
    for (const [i, c] of (content ?? []).entries()) {
      if (c.type === 'text' && !isNoise(c.text)) {
        out.items.push({ id: `${o.uuid}:${i}`, kind: 'user', text: clip(c.text, MAX_TEXT), ts });
      } else if (c.type === 'tool_result') {
        out.items.push({
          id: `${o.uuid}:${i}`, kind: 'result', toolUseId: c.tool_use_id,
          isError: !!c.is_error, text: clip(resultText(c.content), MAX_RESULT), ts,
        });
      }
    }
    return out;
  }
  for (const [i, c] of (content ?? []).entries()) {
    if (c.type === 'text' && c.text?.trim()) {
      out.items.push({ id: `${o.uuid}:${i}`, kind: 'assistant', text: clip(c.text, MAX_TEXT), ts });
    } else if (c.type === 'tool_use') {
      out.items.push({
        id: `${o.uuid}:${i}`, kind: 'tool', toolUseId: c.id, name: c.name,
        summary: clip(toolSummary(c.name, c.input), 300), ts,
      });
    }
  }
  return out;
}

// Incrementally follows one transcript file.
export class TranscriptTail {
  constructor(file) {
    this.file = file;
    this.offset = 0;
    this.partial = '';
    this.items = [];
    this.title = null;
  }

  // Reads anything appended since the last call; returns the new items.
  poll() {
    let fd;
    try { fd = fs.openSync(this.file, 'r'); } catch { return []; }
    try {
      const size = fs.fstatSync(fd).size;
      if (size < this.offset) { this.offset = 0; this.items = []; this.partial = ''; }
      if (size === this.offset) return [];
      const buf = Buffer.alloc(size - this.offset);
      fs.readSync(fd, buf, 0, buf.length, this.offset);
      this.offset = size;
      const text = this.partial + buf.toString('utf8');
      const lines = text.split('\n');
      this.partial = lines.pop();
      const fresh = [];
      for (const l of lines) {
        if (!l) continue;
        const r = parseLine(l);
        if (r.title) this.title = r.title;
        fresh.push(...r.items);
      }
      this.items.push(...fresh);
      if (this.items.length > 400) this.items = this.items.slice(-400);
      return fresh;
    } finally {
      fs.closeSync(fd);
    }
  }
}

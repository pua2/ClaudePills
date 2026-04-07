#!/usr/bin/env node
// ClaudePills — local HTTP + WebSocket relay server
// Receives hook POSTs, tracks session state, broadcasts to all WS clients.

const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = 3737;
const SESSION_EXPIRY_MS = 2 * 60 * 60 * 1000; // 2 hours
const IDLE_COMPLETE_MS = 5 * 60 * 1000;        // 5 min idle → complete

// ─── Session store ───────────────────────────────────────────────────────────
// Map<sessionId, SessionRecord>
const sessions = new Map();
// Map<projectName, Set<sessionId>> — for deduplicate numbering
const projectSessions = new Map();

function projectLabel(project, sessionId) {
  if (!projectSessions.has(project)) projectSessions.set(project, []);
  const arr = projectSessions.get(project);
  if (!arr.includes(sessionId)) arr.push(sessionId);
  const idx = arr.indexOf(sessionId);
  return idx === 0 ? project : `${project} #${idx + 1}`;
}

function getOrCreate(sessionId, cwd) {
  if (sessions.has(sessionId)) return sessions.get(sessionId);
  const project = path.basename(cwd || 'unknown');
  const label = projectLabel(project, sessionId);
  const record = {
    id: sessionId,
    project,
    label,
    state: 'running',
    lastTool: null,
    lastUpdate: Date.now(),
    startedAt: Date.now(),
  };
  sessions.set(sessionId, record);
  return record;
}

function purgeExpired() {
  const now = Date.now();
  for (const [id, s] of sessions) {
    if (now - s.lastUpdate > SESSION_EXPIRY_MS) sessions.delete(id);
  }
}

// Auto-transition: waiting → complete after IDLE_COMPLETE_MS
setInterval(() => {
  const now = Date.now();
  let changed = false;
  for (const s of sessions.values()) {
    if (s.state === 'waiting' && now - s.lastUpdate > IDLE_COMPLETE_MS) {
      s.state = 'complete';
      changed = true;
      broadcast({ type: 'update', session: s });
    }
  }
}, 30_000);

// ─── WebSocket clients ───────────────────────────────────────────────────────
const clients = new Set();

function broadcast(msg) {
  const data = JSON.stringify(msg);
  for (const ws of clients) {
    if (ws.readyState === 1 /* OPEN */) ws.send(data);
  }
}

// ─── HTTP server ─────────────────────────────────────────────────────────────
const DEMO_DIR = path.join(__dirname, '..', 'demo');
const MIME = { '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript' };

const server = http.createServer((req, res) => {
  // POST /update — receive hook payload
  if (req.method === 'POST' && req.url === '/update') {
    let body = '';
    req.on('data', chunk => (body += chunk));
    req.on('end', () => {
      try {
        const payload = JSON.parse(body);
        const { session_id, cwd, hook_event_name, tool_name, terminal_session_id, claude_pid } = payload;

        if (!session_id) { res.writeHead(400); res.end('missing session_id'); return; }

        purgeExpired();
        const session = getOrCreate(session_id, cwd || process.cwd());
        session.lastUpdate = Date.now();
        if (terminal_session_id) session.terminal_session_id = terminal_session_id;
        if (claude_pid) session.claude_pid = claude_pid;

        if (hook_event_name === 'PreToolUse') {
          session.state = 'running';
          session.lastTool = tool_name || null;
        } else if (hook_event_name === 'Stop' || hook_event_name === 'SubagentStop') {
          session.state = 'waiting';
          session.lastTool = null;
        }

        // Deduplicate: when a new session appears on a terminal that already
        // has a different session, mark the older session(s) as complete.
        // This handles /clear and --continue creating new session_ids in the
        // same terminal tab.
        if (terminal_session_id) {
          for (const [otherId, other] of sessions) {
            if (otherId !== session_id &&
                other.terminal_session_id === terminal_session_id &&
                other.state !== 'complete') {
              other.state = 'complete';
              other.lastTool = null;
              other.lastUpdate = Date.now();
              broadcast({ type: 'update', session: other });
            }
          }
        }

        // Handle rename requests from the UI
        if (payload.rename) {
          session.label = payload.rename;
        }

        broadcast({ type: 'update', session });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, label: session.label }));
      } catch {
        res.writeHead(400); res.end('invalid JSON');
      }
    });
    return;
  }

  // DELETE /session/:id — remove a session
  if (req.method === 'DELETE' && req.url.startsWith('/session/')) {
    const id = decodeURIComponent(req.url.slice('/session/'.length));
    const deleted = sessions.delete(id);
    if (deleted) broadcast({ type: 'remove', sessionId: id });
    res.writeHead(deleted ? 200 : 404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: deleted }));
    return;
  }

  // GET /sessions — debug endpoint
  if (req.method === 'GET' && req.url === '/sessions') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify([...sessions.values()], null, 2));
    return;
  }

  // GET static files from demo/
  let filePath = req.url === '/' ? '/index.html' : req.url;
  filePath = path.join(DEMO_DIR, filePath);
  const ext = path.extname(filePath);

  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('Not found'); return; }
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'text/plain' });
    res.end(data);
  });
});

// ─── WebSocket server ────────────────────────────────────────────────────────
const wss = new WebSocketServer({ server });

wss.on('connection', (ws) => {
  clients.add(ws);
  // Send current snapshot on connect
  ws.send(JSON.stringify({ type: 'snapshot', sessions: [...sessions.values()] }));
  ws.on('close', () => clients.delete(ws));
  ws.on('error', () => clients.delete(ws));
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`ClaudePills server running at http://localhost:${PORT}`);
  console.log(`POST http://localhost:${PORT}/update with hook payloads`);
});

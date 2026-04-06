// ─── Constants ───────────────────────────────────────────────────────────────

const STATES = ['running', 'waiting', 'complete', 'hidden-state', 'error'];
const STATE_LABELS = {
  'running':      'Running',
  'waiting':      'Waiting for input',
  'complete':     'Complete',
  'hidden-state': 'Window hidden',
  'error':        'Error',
};
const TOOLS = ['Read', 'Edit', 'Grep', 'Bash', 'Glob', 'Write', 'Agent'];

// ─── State ───────────────────────────────────────────────────────────────────

const projectCounts = {};
const sessions = [];
let nextId = 1;

// fakeWindows maps session id → fake window element (for hide/show demo)
const fakeWindows = {};

// ─── Helpers ─────────────────────────────────────────────────────────────────

function makeLabel(project) {
  projectCounts[project] = (projectCounts[project] || 0) + 1;
  return projectCounts[project] === 1 ? project : `${project} #${projectCounts[project]}`;
}

function randomTool() {
  return TOOLS[Math.floor(Math.random() * TOOLS.length)];
}

function esc(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// ─── Toast ───────────────────────────────────────────────────────────────────

let toastTimer = null;
function showToast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 2200);
}

// ─── Pill DOM ────────────────────────────────────────────────────────────────

function makePill(session) {
  const el = document.createElement('div');
  el.className = `pill ${session.state}`;
  el.dataset.id = session.id;
  el.innerHTML = `
    <div class="pill-indicator"></div>
    <div class="pill-details">
      <div class="pill-top-row">
        <span class="pill-label">${esc(session.label)}</span>
        <div class="pill-actions">
          <button class="pill-action-btn focus-btn" title="Focus terminal">↗</button>
          <button class="pill-action-btn hide-btn"  title="Hide terminal">−</button>
        </div>
      </div>
      <div class="pill-state-row">
        <span class="pill-state-dot"></span>
        <span class="pill-state-text"></span>
      </div>
      <div class="pill-tool-text"></div>
    </div>
  `;

  // Focus button: bring terminal to front (in real app → AppleScript)
  el.querySelector('.focus-btn').addEventListener('click', (e) => {
    e.stopPropagation();
    focusTerminal(session.id);
  });

  // Hide button: hide window without minimizing to Dock
  el.querySelector('.hide-btn').addEventListener('click', (e) => {
    e.stopPropagation();
    toggleHideTerminal(session.id);
  });

  // Click the pill body (not buttons): focus terminal
  el.addEventListener('click', () => focusTerminal(session.id));

  return el;
}

function updatePill(session) {
  const el = document.querySelector(`.pill[data-id="${session.id}"]`);
  if (!el) return;
  el.className = `pill ${session.state}`;
  el.querySelector('.pill-state-text').textContent = STATE_LABELS[session.state] || session.state;
  const tool = el.querySelector('.pill-tool-text');
  tool.textContent = (session.lastTool && session.state === 'running') ? session.lastTool : '';

  // Update hide button label based on state
  const hideBtn = el.querySelector('.hide-btn');
  if (session.state === 'hidden-state') {
    hideBtn.textContent = '□';
    hideBtn.title = 'Show terminal';
  } else {
    hideBtn.textContent = '−';
    hideBtn.title = 'Hide terminal';
  }
}

// ─── Terminal actions ─────────────────────────────────────────────────────────

function focusTerminal(id) {
  const session = sessions.find(s => s.id === id);
  if (!session) return;

  if (session.state === 'hidden-state') {
    // Show the window again
    applyState(id, session.prevState || 'waiting');
    showFakeWindow(id);
    showToast(`Showing window: ${session.label}`);
  } else {
    // In real app: AppleScript to focus iTerm tab via session.itermSessionId
    showToast(`↗  Focusing terminal: ${session.label}`);
    flashFakeWindow(id);
  }
}

function toggleHideTerminal(id) {
  const session = sessions.find(s => s.id === id);
  if (!session) return;

  if (session.state === 'hidden-state') {
    // Show it
    applyState(id, session.prevState || 'waiting');
    showFakeWindow(id);
    showToast(`Window restored: ${session.label}`);
  } else {
    // Hide it — in real app: [NSWindow orderOut] so it disappears without going to Dock
    session.prevState = session.state;
    applyState(id, 'hidden-state');
    hideFakeWindow(id);
    showToast(`Window hidden (not in Dock): ${session.label}`);
  }
}

function newTerminal() {
  // In real app: osascript → iTerm2 create new window with default profile
  const projects = ['ole', 'radial_blocks', 'paddle_maniac', 'claude-usage'];
  const project = projects[Math.floor(Math.random() * projects.length)];
  addSession(project, 'running');
  showToast(`Opened new terminal: ${project}`);
}

// ─── Fake window manipulation (demo only) ────────────────────────────────────

function hideFakeWindow(id) {
  const w = fakeWindows[id];
  if (w) w.classList.add('hidden-window');
}

function showFakeWindow(id) {
  const w = fakeWindows[id];
  if (w) w.classList.remove('hidden-window');
}

function flashFakeWindow(id) {
  const w = fakeWindows[id];
  if (!w) return;
  w.style.outline = '2px solid rgba(96,165,250,0.6)';
  setTimeout(() => { w.style.outline = ''; }, 600);
}

// ─── Session management ──────────────────────────────────────────────────────

function addSession(project, state = 'running') {
  const id = String(nextId++);
  const label = makeLabel(project);
  const session = {
    id, project, label, state,
    lastTool: state === 'running' ? randomTool() : null,
    startedAt: Date.now(),
    prevState: null,
    itermSessionId: `iterm-${id}`, // real app captures $ITERM_SESSION_ID from hook
  };
  sessions.push(session);

  const dock = document.getElementById('edge-dock');
  const footer = dock.querySelector('.dock-footer');
  dock.insertBefore(makePill(session), footer);
  updatePill(session);
  renderControls();
  return session;
}

function applyState(id, state, tool) {
  const s = sessions.find(x => x.id === id);
  if (!s) return;
  s.state = state;
  s.lastTool = state === 'running' ? (tool || randomTool()) : null;
  updatePill(s);
  renderControls();
}

// ─── Controls ────────────────────────────────────────────────────────────────

function renderControls() {
  const container = document.getElementById('ctrl-rows');
  container.innerHTML = '';
  sessions.forEach(s => {
    const row = document.createElement('div');
    row.className = 'ctrl-row';
    row.innerHTML = `
      <span class="ctrl-name">${esc(s.label)}</span>
      ${STATES.map(st => `
        <button class="state-btn ${st} ${s.state === st ? 'active' : ''}"
                data-id="${s.id}" data-state="${st}">${STATE_LABELS[st]}</button>
      `).join('')}
    `;
    container.appendChild(row);
  });
  container.querySelectorAll('.state-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const st = btn.dataset.state;
      const id = btn.dataset.id;
      if (st === 'hidden-state') {
        const session = sessions.find(x => x.id === id);
        if (session) session.prevState = session.state;
        applyState(id, st);
        hideFakeWindow(id);
      } else {
        applyState(id, st);
        showFakeWindow(id);
      }
    });
  });
}

// ─── Draggable dock ──────────────────────────────────────────────────────────

function initDrag() {
  const dock = document.getElementById('edge-dock');
  const handle = dock.querySelector('.dock-handle');
  let dragging = false, startY = 0, startTop = 0;

  function getDockMidY() {
    const r = dock.getBoundingClientRect();
    return r.top + r.height / 2;
  }

  handle.addEventListener('mousedown', (e) => {
    e.preventDefault();
    dragging = true;
    startY = e.clientY;
    const mid = getDockMidY();
    dock.style.top = mid + 'px';
    dock.style.transform = 'none';
    startTop = mid;
  });

  document.addEventListener('mousemove', (e) => {
    if (!dragging) return;
    const newTop = Math.max(60, Math.min(window.innerHeight - 60, startTop + (e.clientY - startY)));
    dock.style.top = newTop + 'px';
  });

  document.addEventListener('mouseup', () => { dragging = false; });
}

// ─── Simulation ──────────────────────────────────────────────────────────────

function startSimulation() {
  setInterval(() => {
    sessions.filter(s => s.state === 'running').forEach(s => {
      s.lastTool = randomTool();
      updatePill(s);
    });
  }, 2000);
}

// ─── Boot ────────────────────────────────────────────────────────────────────

function boot() {
  // Create fake desktop windows to demonstrate hide/show
  const desktop = document.querySelector('.fake-desktop');
  const windowDefs = [
    { id: '1', project: 'ole',          style: 'left:60px;  top:60px;  width:380px; height:200px;' },
    { id: '2', project: 'radial_blocks', style: 'left:480px; top:100px; width:300px; height:170px;' },
    { id: '3', project: 'radial_blocks', style: 'left:100px; top:320px; width:480px; height:180px;' },
  ];
  windowDefs.forEach(def => {
    const win = document.createElement('div');
    win.className = 'fake-window';
    win.style.cssText = def.style;
    win.innerHTML = `
      <div class="titlebar">
        <span class="dot red"></span><span class="dot yellow"></span><span class="dot green"></span>
        <span class="win-label">iTerm2 — ${def.project}</span>
      </div>
      <div class="body">
        <div class="line" style="width:70%"></div>
        <div class="line" style="width:45%;opacity:.6"></div>
        <div class="line" style="width:85%;opacity:.5"></div>
        <div class="line" style="width:55%;opacity:.7"></div>
      </div>`;
    desktop.appendChild(win);
    fakeWindows[def.id] = win;
  });

  // Seed sessions (IDs will be '1', '2', '3' matching windows above)
  addSession('ole', 'running');
  addSession('radial_blocks', 'waiting');
  addSession('radial_blocks', 'complete');

  initDrag();
  startSimulation();

  document.getElementById('add-btn').addEventListener('click', () => {
    const projects = ['ole', 'radial_blocks', 'paddle_maniac', 'claude-usage'];
    const project = projects[Math.floor(Math.random() * projects.length)];
    addSession(project, STATES[Math.floor(Math.random() * 3)]);
  });

  document.getElementById('new-terminal-btn').addEventListener('click', newTerminal);

  if (location.protocol !== 'file:') connectWebSocket();
}

function connectWebSocket() {
  const ws = new WebSocket(`ws://${location.host}`);
  ws.onopen = () => console.log('[monitor] connected');
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.type === 'update') {
      const existing = sessions.find(x => x.id === msg.session.id);
      if (existing) applyState(msg.session.id, msg.session.state, msg.session.lastTool);
      else addSession(msg.session.project, msg.session.state);
    }
  };
  ws.onclose = () => setTimeout(connectWebSocket, 3000);
}

document.addEventListener('DOMContentLoaded', boot);

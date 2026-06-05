const STORAGE_KEY = "autonomous-dev-monitor:v1";
const DEFAULT_ENDPOINT = new URL("/v1/chat/completions", window.location.origin).toString();

const state = loadState();
const els = {
  messages: document.getElementById("messages"),
  summary: document.getElementById("summary"),
  risk: document.getElementById("risk-level"),
  stability: document.getElementById("stability-score"),
  statusLine: document.getElementById("status-line"),
  process: document.getElementById("process"),
  runLog: document.getElementById("run-log"),
  sessionSelect: document.getElementById("session-select"),
  input: document.getElementById("input"),
  form: document.getElementById("composer"),
  endpoint: document.getElementById("endpoint"),
  apiKey: document.getElementById("api-key"),
  model: document.getElementById("model"),
  temperature: document.getElementById("temperature"),
  settings: document.getElementById("settings")
};

init();
setInterval(loadRunHistory, 4000);

function init() {
  bindEvents();
  hydrateConfig();
  renderSessions();
  renderMessages();
  void loadRunHistory(true);
}

function loadState() {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (raw) return JSON.parse(raw);
  const sessionId = crypto.randomUUID();
  return {
    config: {
      endpoint: DEFAULT_ENDPOINT,
      apiKey: "",
      model: "jgo",
      temperature: 0.2
    },
    activeSessionId: sessionId,
    sessions: [{ id: sessionId, title: "Session 1", messages: [] }]
  };
}

function saveState() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

function bindEvents() {
  document.getElementById("new-session").addEventListener("click", createSession);
  document.getElementById("delete-session").addEventListener("click", deleteSession);
  document.getElementById("refresh-runs").addEventListener("click", () => void loadRunHistory(true));
  document.getElementById("toggle-settings").addEventListener("click", () => {
    els.settings.classList.toggle("hidden");
  });
  document.getElementById("save-settings").addEventListener("click", saveConfigFromForm);
  els.sessionSelect.addEventListener("change", (e) => {
    state.activeSessionId = e.target.value;
    saveState();
    renderMessages();
  });
  els.form.addEventListener("submit", sendMessage);
}

function hydrateConfig() {
  state.config.endpoint = state.config.endpoint || DEFAULT_ENDPOINT;
  els.endpoint.value = state.config.endpoint || DEFAULT_ENDPOINT;
  els.apiKey.value = state.config.apiKey || "";
  els.model.value = state.config.model || "jgo";
  els.temperature.value = String(state.config.temperature ?? 0.2);
  els.statusLine.textContent = state.config.endpoint ? "Ready" : "Endpoint not configured";
}

function saveConfigFromForm() {
  state.config = {
    endpoint: els.endpoint.value.trim() || DEFAULT_ENDPOINT,
    apiKey: els.apiKey.value.trim(),
    model: els.model.value.trim() || "jgo",
    temperature: Number(els.temperature.value || "0.2")
  };
  saveState();
  hydrateConfig();
}

function getActiveSession() {
  return state.sessions.find((s) => s.id === state.activeSessionId);
}

function renderSessions() {
  els.sessionSelect.innerHTML = "";
  state.sessions.forEach((s) => {
    const option = document.createElement("option");
    option.value = s.id;
    option.textContent = s.title;
    option.selected = s.id === state.activeSessionId;
    els.sessionSelect.appendChild(option);
  });
}

function renderMessages() {
  const session = getActiveSession();
  els.messages.innerHTML = "";
  if (!session) return;
  session.messages.forEach((m) => {
    const div = document.createElement("div");
    div.className = `msg ${m.role}`;
    div.textContent = m.content;
    els.messages.appendChild(div);
  });
  const lastAssistant = [...session.messages].reverse().find((m) => m.role === "assistant");
  updateSummary(lastAssistant ? lastAssistant.content : "No response yet.");
  els.messages.scrollTop = els.messages.scrollHeight;
}

function appendMessage(role, content) {
  const session = getActiveSession();
  if (!session) return;
  session.messages.push({
    role,
    content,
    at: new Date().toISOString()
  });
  saveState();
  renderMessages();
}

function createSession() {
  const next = state.sessions.length + 1;
  const id = crypto.randomUUID();
  state.sessions.push({ id, title: `Session ${next}`, messages: [] });
  state.activeSessionId = id;
  saveState();
  renderSessions();
  renderMessages();
}

function deleteSession() {
  if (state.sessions.length === 1) return;
  state.sessions = state.sessions.filter((s) => s.id !== state.activeSessionId);
  state.activeSessionId = state.sessions[0].id;
  saveState();
  renderSessions();
  renderMessages();
}

function updateSummary(text) {
  els.summary.textContent = text;
  const riskLine = (text.match(/위험도[:\s]*(낮음|보통|높음)/) || [])[1] || "unknown";
  const scoreLine = (text.match(/(안정도|stability).{0,30}([0-9]+(?:\.[0-9])?)/i) || [])[2] || "-";
  els.risk.textContent = riskLine;
  els.risk.dataset.level = riskLine;
  els.stability.textContent = scoreLine;
}

async function sendMessage(event) {
  event.preventDefault();
  const content = els.input.value.trim();
  if (!content) return;

  appendMessage("user", content);
  els.input.value = "";
  els.statusLine.textContent = "Analyzing...";

  try {
    const reply = await requestCommand();
    appendMessage("assistant", reply.content);
    if (reply.runId) {
      appendProcessStatus(`실행 완료 (run=${reply.runId})`);
    } else {
      appendProcessStatus("실행 완료");
    }
    els.statusLine.textContent = "Ready";
  } catch (error) {
    appendMessage("assistant", `실행 실패: ${error.message}`);
    appendProcessStatus(`실행 실패: ${error.message}`);
    els.statusLine.textContent = "Error";
  } finally {
    await loadRunHistory();
  }
}

function appendProcessStatus(text) {
  const div = document.createElement("div");
  div.className = "process-item";
  div.textContent = `${new Date().toLocaleTimeString()} ${text}`;
  els.process.prepend(div);
  while (els.process.children.length > 10) {
    els.process.lastChild?.remove();
  }
}

async function requestCommand() {
  const session = getActiveSession();
  if (!session) throw new Error("No active session");

  if (!state.config.endpoint) {
    throw new Error("Endpoint is not configured");
  }

  const payload = {
    model: state.config.model || "jgo",
    temperature: Number(state.config.temperature ?? 0.2),
    messages: [
      ...session.messages.map((m) => ({ role: m.role, content: m.content }))
    ],
    stream: false
  };

  const headers = { "Content-Type": "application/json" };
  if (state.config.apiKey) headers.Authorization = `Bearer ${state.config.apiKey}`;

  const res = await fetch(state.config.endpoint, {
    method: "POST",
    headers,
    body: JSON.stringify(payload)
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text.slice(0, 200)}`);
  }

  const data = await res.json();
  const content = data?.choices?.[0]?.message?.content;
  if (!content) throw new Error("No content in model response");
  return {
    content,
    runId: res.headers.get("X-JGO-Run-ID") || ""
  };
}

async function loadRunHistory(initial = false) {
  try {
    const res = await fetch("/api/runs?limit=20", { method: "GET" });
    if (!res.ok) {
      if (initial) {
        appendProcessStatus("실행 이력을 불러오지 못했습니다.");
      }
      return;
    }
    const body = await res.json();
    renderRunHistory(body?.items || []);
    if (body?.items?.length > 0 && !initial) {
      const lastCompleted = body.items.find((run) => run.status === "completed");
      if (lastCompleted) {
        updateSummary(lastCompleted.response || lastCompleted.error || "No response");
      }
    }
  } catch {
    if (initial) appendProcessStatus("실행 이력 API를 사용 불가");
  }
}

function renderRunHistory(items) {
  els.runLog.innerHTML = "";
  els.process.innerHTML = "";
  if (!Array.isArray(items) || items.length === 0) {
    const empty = document.createElement("p");
    empty.textContent = "아직 실행 이력이 없습니다.";
    els.runLog.appendChild(empty);
    return;
  }

  items.forEach((item) => {
    const row = document.createElement("div");
    row.className = `run-row ${item.status}`;

    const left = document.createElement("div");
    left.className = "run-left";
    left.textContent = `${item.timestamp} [${item.status}] ${item.run_id || item.runID || "run-unknown"}`;

    const meta = document.createElement("div");
    meta.className = "run-meta";
    meta.textContent = `${item.duration_ms ?? item.durationMs ?? 0}ms`;

    const prompt = document.createElement("div");
    prompt.className = "run-instruction";
    prompt.textContent = truncate(item.instruction || "", 170);

    const result = document.createElement("div");
    result.className = "run-result";
    result.textContent = item.error ? `ERROR: ${truncate(item.error, 120)}` : truncate(item.response || "", 120);

    row.appendChild(left);
    row.appendChild(meta);
    row.appendChild(prompt);
    row.appendChild(result);
    els.runLog.appendChild(row);

    const processLine = document.createElement("div");
    processLine.className = "process-item";
    processLine.textContent = `${item.timestamp} [${item.status}] ${truncate(item.instruction || "", 80)}`;
    els.process.appendChild(processLine);
  });
}

function truncate(text, max) {
  const raw = String(text || "");
  return raw.length <= max ? raw : `${raw.slice(0, max)}...`;
}

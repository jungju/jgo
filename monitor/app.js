const STORAGE_KEY = "autonomous-dev-monitor:v1";

const monitorSystemPrompt = `# 📡 Autonomous Dev System Live Monitor Prompt
너는 자율 개발 시스템의 실시간 상태 모니터링 AI다.
역할: 현재 상태를 분석하고 판단하고 경고한다.
반드시 아래 출력 구조를 지켜라.

### 1️⃣ 현재 상태 요약 (한눈에 보기)
- 진행 단계:
- 성공/실패:
- 위험도: 낮음 / 보통 / 높음
- 시스템 안정도 점수 (10점 만점):
---
### 2️⃣ 이상 징후 탐지
- 감지된 문제:
- 잠재 리스크:
- 재발 가능성:
---
### 3️⃣ 구조적 분석
- 복잡성 증가 여부:
- 중복 코드 증가 여부:
- 테스트 커버리지 위험:
- 기술 부채 증가 여부:
---
### 4️⃣ 자동화 개선 제안
- 지금 자동화 가능한 것:
- 반복 패턴:
- 제거 가능한 단계:
---
### 5️⃣ 다음 행동 제안 (Top 3)
1.
2.
3.
---

규칙:
- 감정 없이 판단
- 추측은 "추정"이라고 명시
- 과잉 경고 금지
- 근거 기반 분석
- 요약은 간결하게
- 구조 개선 관점 유지`; 

const state = loadState();
const els = {
  messages: document.getElementById("messages"),
  summary: document.getElementById("summary"),
  risk: document.getElementById("risk-level"),
  stability: document.getElementById("stability-score"),
  statusLine: document.getElementById("status-line"),
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

function loadState() {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (raw) return JSON.parse(raw);
  const sessionId = crypto.randomUUID();
  return {
    config: { endpoint: "", apiKey: "", model: "jgo", temperature: 0.2 },
    activeSessionId: sessionId,
    sessions: [{ id: sessionId, title: "Session 1", messages: [] }]
  };
}

function saveState() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

function init() {
  bindEvents();
  hydrateConfig();
  renderSessions();
  renderMessages();
}

function bindEvents() {
  document.getElementById("new-session").addEventListener("click", createSession);
  document.getElementById("delete-session").addEventListener("click", deleteSession);
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
  els.endpoint.value = state.config.endpoint || "";
  els.apiKey.value = state.config.apiKey || "";
  els.model.value = state.config.model || "jgo";
  els.temperature.value = String(state.config.temperature ?? 0.2);
  els.statusLine.textContent = state.config.endpoint ? "Ready" : "Endpoint not configured";
}

function saveConfigFromForm() {
  state.config = {
    endpoint: els.endpoint.value.trim(),
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
  updateSummary(lastAssistant ? lastAssistant.content : "No analysis yet.");
  els.messages.scrollTop = els.messages.scrollHeight;
}

function appendMessage(role, content) {
  const session = getActiveSession();
  if (!session) return;
  session.messages.push({ role, content, at: new Date().toISOString() });
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
  const riskLine = (text.match(/위험도:\s*(낮음|보통|높음)/) || [])[1] || "unknown";
  const scoreLine = (text.match(/시스템 안정도 점수.*?:\s*([0-9]+(?:\.[0-9])?)/) || [])[1] || "-";
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
    const response = await requestAnalysis();
    appendMessage("assistant", enforceResponseTemplate(response));
    els.statusLine.textContent = "Ready";
  } catch (error) {
    appendMessage("assistant", `분석 실패: ${error.message}`);
    els.statusLine.textContent = "Error";
  }
}

async function requestAnalysis() {
  const session = getActiveSession();
  if (!session) throw new Error("No active session");

  if (!state.config.endpoint) {
    return [
      "### 1️⃣ 현재 상태 요약 (한눈에 보기)",
      "- 진행 단계: 입력 대기",
      "- 성공/실패: 추정 불가(데이터 부족)",
      "- 위험도: 보통",
      "- 시스템 안정도 점수 (10점 만점): 5",
      "---",
      "### 2️⃣ 이상 징후 탐지",
      "- 감지된 문제: 엔드포인트 미설정",
      "- 잠재 리스크: 실시간 분석 중단",
      "- 재발 가능성: 높음",
      "---",
      "### 3️⃣ 구조적 분석",
      "- 복잡성 증가 여부: 추정 불가",
      "- 중복 코드 증가 여부: 추정 불가",
      "- 테스트 커버리지 위험: 보통",
      "- 기술 부채 증가 여부: 보통",
      "---",
      "### 4️⃣ 자동화 개선 제안",
      "- 지금 자동화 가능한 것: endpoint/config 자동 주입",
      "- 반복 패턴: 설정 누락",
      "- 제거 가능한 단계: 수동 환경입력",
      "---",
      "### 5️⃣ 다음 행동 제안 (Top 3)",
      "1. Endpoint URL과 API 키를 설정한다.",
      "2. 테스트 로그 샘플을 입력해 응답 품질을 검증한다.",
      "3. 정상 응답 확인 후 세션 템플릿을 표준화한다.",
      "---"
    ].join("\n");
  }

  const payload = {
    model: state.config.model || "jgo",
    temperature: Number(state.config.temperature ?? 0.2),
    messages: [
      { role: "system", content: monitorSystemPrompt },
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
  return content;
}

function enforceResponseTemplate(text) {
  const required = [
    "### 1️⃣ 현재 상태 요약 (한눈에 보기)",
    "### 2️⃣ 이상 징후 탐지",
    "### 3️⃣ 구조적 분석",
    "### 4️⃣ 자동화 개선 제안",
    "### 5️⃣ 다음 행동 제안 (Top 3)"
  ];
  const missing = required.filter((h) => !text.includes(h));
  if (missing.length === 0) return text;

  return `${text}\n\n[template-warning]\n누락된 섹션: ${missing.join(", ")}`;
}

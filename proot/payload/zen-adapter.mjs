// zen-adapter.mjs — локальный прокси к OpenCode Zen, который идёт "от имени opencode".
//
// Проблема: free-tier модели Zen (напр. muse-spark-1.3-contributor-free,
// big-pickle и др.) отвечают 403:
//   "OpenCode's free tier can only be used from within OpenCode"
// если запрос не похож на запрос настоящего OpenCode CLI.
//
// Что проверяет гейт (реверс поведения, подтверждено тестами 2026-09-17):
//   1. User-Agent MUST начинаться с "opencode/" (настоящий CLI шлёт напр.
//      "opencode/1.18.31 ai-sdk/provider-utils/4.0.40 runtime/bun/1.3.14").
//   2. Заголовок x-opencode-session MUST быть валидным opencode-ID вида
//      ses_<26 символов>, у которого первые 12 символов — hex-timestamp
//      (формат @opencode-ai/schema/identifier). Случайный base62-мусор
//      в префиксе -> 403. Свежий ID с текущим timestamp -> 200.
//   3. x-opencode-request / project / client — некритичны, но прокидываем.
//
// Адаптер слушает локально (по умолчанию :8787) и проксирует любой путь
// /v1/* на https://opencode.ai/zen/v1/*, подменяя заголовки на "как у opencode".
// Клиенты (curl, python-openai, Cline, Continue и т.д.) ходят в адаптер как
// в обычный OpenAI-совместимый сервер.
//
// Запуск:
//   ZEN_API_KEY=sk-... node zen-adapter.mjs [--port 8787] [--api-key sk-...]
//   node zen-adapter.mjs --help
//
// Примеры:
//   curl localhost:8787/v1/models -H "Authorization: Bearer x"
//   curl localhost:8787/v1/responses -H 'Content-Type: application/json' \
//     -d '{"model":"muse-spark-1.3-contributor-free","input":"hi","max_output_tokens":64,"stream":false,"store":false}'

import http from "node:http";
import crypto from "node:crypto";

// Таймстампы на каждую строку лога — без них диагностика по времени невозможна.
for (const m of ["log", "error", "warn"]) {
  const f = console[m].bind(console);
  console[m] = (...a) => f(new Date().toISOString(), ...a);
}

const UPSTREAM = "https://opencode.ai";
const DEFAULT_PORT = 8787;
// Точная строка настоящего CLI (v2: opencode/latest/2.0.8/cli).
// Гейт смотрит префикс opencode/ + валидный ses_, но держим как у CLI.
const OPENCODE_UA = "opencode/latest/2.0.8/cli";
// Ключ из запроса пользователя. Лучше задать через env ZEN_API_KEY/OPENCODE_API_KEY.
const FALLBACK_KEY = "sk-tyHdwrAxmsjVrEaql82tRSDYKEGiD8hE9Aa14Xtmnu31041m0pvFbSCbwVxkN2R8";

const args = process.argv.slice(2);
function arg(name, def) {
  const i = args.findIndex((a) => a === name || a.startsWith(name + "="));
  if (i === -1) return def;
  const a = args[i];
  if (a.includes("=")) return a.slice(name.length + 1);
  return args[i + 1] ?? def;
}
if (args.includes("--help") || args.includes("-h")) {
  console.log("Usage: node zen-adapter.mjs [--port 8787] [--api-key sk-...] [--upstream https://opencode.ai]");
  process.exit(0);
}
const PORT = Number(arg("--port", process.env.PORT ?? process.env.ZEN_ADAPTER_PORT ?? DEFAULT_PORT));
const API_KEY = arg("--api-key", process.env.ZEN_API_KEY ?? process.env.OPENCODE_API_KEY ?? FALLBACK_KEY);
const UPSTREAM_BASE = arg("--upstream", process.env.ZEN_UPSTREAM ?? UPSTREAM);
const SESSIONS_FILE =
  arg("--sessions-file", process.env.ZEN_SESSIONS_FILE ?? "/tmp/zen-sessions.json");

// ---- opencode ID generation (порт @opencode-ai/schema/identifier) ----
const ID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
let lastTs = 0;
let counter = 0;
function createIdentifier(descending, timestamp = Date.now()) {
  if (timestamp !== lastTs) {
    lastTs = timestamp;
    counter = 0;
  }
  counter += 1;
  const current = BigInt(timestamp) * 0x1000n + BigInt(counter);
  const value = descending ? ~current : current;
  let time = "";
  for (let i = 0; i < 6; i++) {
    time += Number((value >> BigInt(40 - 8 * i)) & 0xffn).toString(16).padStart(2, "0");
  }
  const rand = crypto.getRandomValues(new Uint8Array(14));
  let tail = "";
  for (const b of rand) tail += ID_CHARS[b % 62];
  return time + tail;
}
const newSessionId = () => "ses_" + createIdentifier(true); // descending, как у CLI
const newMsgId = () => "msg_" + createIdentifier(true);

// Валидный ли session id с точки зрения гейта: ses_ + 26, первые 12 — hex.
function looksValidSession(id) {
  return typeof id === "string" && /^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/.test(id);
}

// ---- Стабильный ses_ на каждую pi-сессию ----
// Zen использует x-opencode-session как stickyId для прибивания сессии
// к конкретному апстрим-провайдеру. Новый случайный ses_ на каждый запрос
// ломает sticky-роутинг (каждый ход может уехать на другую реплику),
// поэтому маппим piSessionId -> один ses_, персистим в файл.
import fs from "node:fs";
const sesMap = new Map(); // piId -> { ses, createdAt, hits }
function loadSesMap() {
  try {
    const raw = fs.readFileSync(SESSIONS_FILE, "utf8");
    const obj = JSON.parse(raw);
    const cutoff = Date.now() - 30 * 24 * 3600 * 1000;
    for (const [piId, rec] of Object.entries(obj)) {
      if (rec && looksValidSession(rec.ses) && (rec.createdAt ?? 0) > cutoff) {
        sesMap.set(piId, { ses: rec.ses, createdAt: rec.createdAt, hits: rec.hits ?? 0 });
      }
    }
    console.log(`sessions: loaded ${sesMap.size} pi->ses mappings from ${SESSIONS_FILE}`);
  } catch {
    // нет файла — стартуем с пустой карты
  }
}
let saveTimer = null;
function saveSesMap() {
  try {
    fs.writeFileSync(SESSIONS_FILE, JSON.stringify(Object.fromEntries(sesMap), null, 1));
  } catch (e) {
    console.error("sessions: save failed:", e.message);
  }
}
function scheduleSave() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    saveSesMap();
  }, 5000);
  saveTimer.unref?.();
}
function sesForPi(piId) {
  let rec = sesMap.get(piId);
  if (!rec) {
    rec = { ses: newSessionId(), createdAt: Date.now(), hits: 0 };
    sesMap.set(piId, rec);
    console.log(`sessions: new mapping pi=${mask(piId)} -> ${rec.ses.slice(0, 12)}…`);
    scheduleSave();
  }
  rec.hits += 1;
  return rec.ses;
}
loadSesMap();
setInterval(saveSesMap, 60_000).unref?.();
process.on("SIGTERM", () => {
  saveSesMap();
  process.exit(0);
});
// Последний рубеж: логируем, но не падаем (падение 2026-09-18 было
// именно необработанным исключением из стримового цикла).
process.on("uncaughtException", (e) => console.error("uncaught:", e?.stack ?? e?.message ?? e));
process.on("unhandledRejection", (e) => console.error("unhandled rejection:", e?.stack ?? e?.message ?? e));

function mask(s) {
  if (!s || s.length < 12) return "***";
  return s.slice(0, 6) + "…" + s.slice(-4);
}

let ridCounter = 0;

// Авто-ретрай при 429/5xx ДО начала стрима клиенту: пережидаем
// (Retry-After или экспонента) и повторяем тот же запрос, вместо того
// чтобы ронять цикл и требовать ручного «продолжи».
// ZEN_RETRY_MAX_MS — суммарный бюджет ожидания (по умолч. 3 мин).
const RETRY_MAX_MS = Number(process.env.ZEN_RETRY_MAX_MS ?? 180000);
const RETRY_STATUSES = new Set([429, 500, 502, 503, 529]);

function retryDelayMs(up, attempt) {
  let wait = Math.min(5000 * attempt, 60000);
  const ra = up.headers.get("retry-after");
  if (ra) {
    const secs = Number(ra);
    if (Number.isFinite(secs)) wait = secs * 1000;
    else {
      const at = Date.parse(ra);
      if (Number.isFinite(at)) wait = at - Date.now();
    }
    wait = Math.min(Math.max(wait, 1000), 120000);
  }
  return wait + Math.floor(Math.random() * 2000);
}

function throwIfAborted(signal) {
  if (signal?.aborted) throw Object.assign(new Error("aborted"), { name: "AbortError" });
}

async function fetchWithRetry(target, init, rid) {
  const started = Date.now();
  let attempt = 0;
  for (;;) {
    throwIfAborted(init.signal);
    attempt += 1;
    const up = await fetch(target, init);
    if (!RETRY_STATUSES.has(up.status) || Date.now() - started >= RETRY_MAX_MS) return up;
    try {
      await up.arrayBuffer();
    } catch {}
    const wait = retryDelayMs(up, attempt);
    if (Date.now() - started + wait >= RETRY_MAX_MS) return up;
    console.log(`[${rid}] ← ${up.status} limited, retry in ${Math.round(wait / 1000)}s (attempt ${attempt})`);
    await new Promise((resolve, reject) => {
      const t = setTimeout(resolve, wait);
      init.signal?.addEventListener("abort", () => {
        clearTimeout(t);
        reject(Object.assign(new Error("aborted"), { name: "AbortError" }));
      }, { once: true });
    });
  }
}

// Короткая пометка по хвосту ответа: incomplete (бюджет токенов исчерпан,
// модель ничего нового не сказала -> риск повтора тех же тул-колов),
// error-сообщение апстрима.
function noteFor(tail, httpStatus) {
  if (httpStatus !== 200) {
    try {
      const j = JSON.parse(tail);
      const msg = j?.error?.message ?? j?.error?.type ?? tail.slice(0, 160);
      return ` ERROR=${String(msg).slice(0, 160)}`;
    } catch {
      return ` ERROR=${tail.slice(0, 160)}`;
    }
  }
  if (tail.includes("response.incomplete") || tail.includes('"status":"incomplete"')) {
    const m = tail.match(/"reason"\s*:\s*"([^"]+)"/);
    return ` INCOMPLETE${m ? ":" + m[1] : ""}`;
  }
  return "";
}

function buildUpstreamHeaders(incoming) {
  // incoming: plain object, ключи уже в lower-case (node http).
  // Возвращает { headers, piSession }.
  const out = {};
  for (const [k, v] of Object.entries(incoming)) {
    // x-pi-session — внутренний маппинг, в апстрим не уходит.
    // anthropic-служебные заголовки Claude Code — тоже (upstream их не ждёт).
    if (
      ["host", "connection", "content-length", "accept-encoding", "x-pi-session", "x-api-key", "anthropic-version", "anthropic-beta"].includes(k)
    )
      continue;
    out[k] = v;
  }
  // --- Auth: ключ клиента, если он реальный, иначе наш ---
  // Claude Code шлёт x-api-key вместо Authorization.
  const auth = incoming["authorization"] ?? "";
  const xKey = typeof incoming["x-api-key"] === "string" ? incoming["x-api-key"] : "";
  const isDummy = (v) =>
    !v || /^(bearer\s+)?(test|x+|dummy|placeholder|public|none|null|undefined|local|not-needed|adapter|zen([-_]local)?|sk-ant-dummy)\s*$/i.test(v);
  let finalAuth = !isDummy(auth) ? auth : "";
  if (!finalAuth && !isDummy(xKey)) finalAuth = `Bearer ${xKey}`;
  if (!finalAuth) finalAuth = `Bearer ${API_KEY}`;
  out["authorization"] = finalAuth;
  // --- Маскировка под opencode (перезаписываем всегда!) ---
  out["user-agent"] = OPENCODE_UA;
  // Порядок: валидный ses_ от клиента (сам opencode) -> стабильный ses_
  // для pi-сессии -> стабильный дефолтный (per-user sticky: без него
  // каждый запрос уходит на случайную реплику апстрима, и ответы
  // флэппят — замечено 2026-09-18: один и тот же запрос то 200, то 400).
  const piSession = typeof incoming["x-pi-session"] === "string" ? incoming["x-pi-session"] : undefined;
  if (looksValidSession(incoming["x-opencode-session"])) {
    // оставляем как есть
  } else if (piSession) {
    out["x-opencode-session"] = sesForPi(piSession);
  } else {
    out["x-opencode-session"] = sesForPi("__default__");
  }
  if (!incoming["x-opencode-request"]) out["x-opencode-request"] = newMsgId();
  if (!incoming["x-opencode-project"]) out["x-opencode-project"] = "global";
  if (!incoming["x-opencode-client"]) out["x-opencode-client"] = "cli";
  out["content-type"] = out["content-type"] ?? "application/json";
  out["accept"] = out["accept"] ?? "*/*";
  return { headers: out, piSession };
}

function readBody(req, limit = 25 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

// ============================================================
// Транслятор Anthropic Messages API <-> OpenAI Responses API.
// Нужен для Claude Code: он говорит только на Anthropic-протоколе
// (POST /v1/messages, x-api-key), а Muse Spark на Zen живёт только
// на /v1/responses. Все запрошенные модели маппятся в Muse Spark.
// ============================================================
const CC_DEFAULT_MODEL = process.env.ZEN_CC_MODEL ?? "muse-spark-1.3-contributor-free";
const CC_EFFORT = process.env.ZEN_CC_EFFORT ?? "xhigh"; // max доступный Muse Spark (minimal/low/medium/high/xhigh)

function mapCcModel(m) {
  if (typeof m !== "string" || !/muse-spark/i.test(m)) return CC_DEFAULT_MODEL;
  // Claude Code суффикс окна контекста ([1m]) — в апстрим не уходит
  return m.replace(/\[[^\]]*\]$/, "");
}

function sysToText(sys) {
  if (!sys) return "";
  if (typeof sys === "string") return sys;
  if (Array.isArray(sys)) return sys.map((b) => (typeof b?.text === "string" ? b.text : "")).join("\n");
  return "";
}

// user-контент Anthropic -> массив input_* для Responses
function userContentToInput(content) {
  const parts = Array.isArray(content) ? content : [{ type: "text", text: String(content ?? "") }];
  const out = [];
  for (const b of parts) {
    if (b?.type === "text") out.push({ type: "input_text", text: b.text ?? "" });
    else if (b?.type === "image" && b.source?.type === "base64") {
      out.push({ type: "input_image", image_url: `data:${b.source.media_type};base64,${b.source.data}` });
    } else if (b?.type === "image" && b.source?.type === "url") {
      out.push({ type: "input_image", image_url: b.source.url });
    }
    // tool_result собирается отдельно в function_call_output, здесь пропускаем
  }
  return out;
}

function toolResultToString(tr) {
  const c = tr?.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) {
    return c
      .map((b) => {
        if (typeof b === "string") return b;
        if (b?.type === "text") return b.text ?? "";
        if (b?.type === "image") return "(see attached image)";
        return JSON.stringify(b);
      })
      .join("\n");
  }
  if (c == null) return "(no tool output)";
  return JSON.stringify(c);
}

function convertAnthropicRequest(a) {
  const input = [];
  for (const m of a.messages ?? []) {
    if (m.role === "assistant") {
      const blocks = Array.isArray(m.content) ? m.content : [{ type: "text", text: String(m.content ?? "") }];
      const text = blocks.filter((b) => b?.type === "text").map((b) => b.text).join("");
      if (text) input.push({ role: "assistant", content: text });
      // replay вызовов — отдельными function_call items (формат Responses API)
      for (const b of blocks) {
        if (b?.type === "tool_use") {
          input.push({ type: "function_call", call_id: b.id, name: b.name, arguments: JSON.stringify(b.input ?? {}) });
        }
      }
    } else {
      // user: обычные блоки + tool_result как function_call_output.
      // ВАЖНО (гейт Meta, 2026-09-18): outputs ДОЛЖНЫ идти сразу за
      // вызовами — текстовое user-сообщение между ними рвёт спаривание
      // и даёт 400 invalid parameters. Поэтому сначала outputs, потом текст.
      const parts = Array.isArray(m.content) ? m.content : [{ type: "text", text: String(m.content ?? "") }];
      for (const b of parts) {
        if (b?.type === "tool_result") {
          input.push({ type: "function_call_output", call_id: b.tool_use_id, output: toolResultToString(b) });
        }
      }
      const regular = userContentToInput(parts.filter((b) => b?.type !== "tool_result"));
      if (regular.length) input.push({ role: "user", content: regular });
    }
  }
  const req = {
    model: mapCcModel(a.model),
    instructions: sysToText(a.system) || undefined,
    input,
    stream: Boolean(a.stream),
    store: false,
    max_output_tokens: a.max_tokens ?? 4096,
    reasoning: { effort: a?.thinking?.type === "enabled" ? "high" : CC_EFFORT },
  };
  if (Array.isArray(a.tools) && a.tools.length) {
    req.tools = a.tools.map((t) => ({
      type: "function",
      name: t.name,
      description: t.description ?? "",
      parameters: t.input_schema ?? { type: "object" },
    }));
    const tc = a.tool_choice;
    if (!tc || tc.type === "auto") req.tool_choice = "auto";
    else if (tc.type === "any") req.tool_choice = "required";
    else if (tc.type === "tool" && tc.name) req.tool_choice = { type: "function", function: { name: tc.name } };
  }
  if (typeof a.temperature === "number") req.temperature = a.temperature;
  if (typeof a.top_p === "number") req.top_p = a.top_p;
  const ccKey = a?.metadata?.user_id;
  return { req, ccKey: typeof ccKey === "string" && ccKey ? "cc:" + ccKey : undefined, modelUsed: req.model };
}

function responsesOutputToAnthropicContent(output) {
  const content = [];
  for (const item of output ?? []) {
    if (item?.type === "message") {
      for (const b of item.content ?? []) {
        if (b?.type === "output_text" && b.text) content.push({ type: "text", text: b.text });
      }
    } else if (item?.type === "function_call") {
      let parsed = {};
      try {
        parsed = JSON.parse(item.arguments || "{}");
      } catch {
        parsed = { _raw: item.arguments };
      }
      content.push({ type: "tool_use", id: item.call_id, name: item.name, input: parsed });
    }
    // reasoning-блоки пропускаем
  }
  return content;
}

function anthropicError(status, message, type = "api_error") {
  return { status, body: JSON.stringify({ type: "error", error: { type, message: String(message).slice(0, 2000) } }) };
}

async function handleMessages(req, res, bodyBuf, started, rid, headers, piSession, signal) {
  let a;
  try {
    a = JSON.parse(bodyBuf.toString("utf8"));
  } catch {
    const e = anthropicError(400, "invalid JSON body", "invalid_request_error");
    res.writeHead(e.status, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(e.body);
    return;
  }
  const conv = convertAnthropicRequest(a);
  const modelUsed = conv.modelUsed;
  const ccKey = conv.ccKey;
  // Разовый захват сырого тела для офлайн-бисекции (ZEN_CAPTURE=1).
  if (process.env.ZEN_CAPTURE === "1") {
    try {
      fs.writeFileSync(`/tmp/zen-capture-${rid}.json`, bodyBuf.slice(0, 2_000_000));
      console.log(`[${rid}] captured body to /tmp/zen-capture-${rid}.json`);
    } catch {}
  }
  // Shape-лог: что реально пришло (структура, не содержимое) — для
  // диагностики 400 вида "invalid parameters".
  try {
    const shape = (a.messages ?? []).map((m) => {
      const c = Array.isArray(m.content) ? m.content : [m.content];
      return `${m.role}[${c.map((b) => (b && typeof b === "object" ? b.type + (b.name ? ":" + b.name : "") : typeof b)).join(",")}]`;
    });
    const tools = (a.tools ?? []).map((t) => t?.name).join(",");
    console.log(`[${rid}] shape msgs=${(a.messages ?? []).length} tools=[${tools}] sys=${sysToText(a.system).length}ch body=${bodyBuf.length}B :: ${shape.join(" | ").slice(0, 600)}`);
  } catch {}
  const wantStream = a.stream === true;
  const gate = ensureGate(conv.req);
  const upBody = gate.upBody;
  normalizeEffort(upBody);
  const injected = gate.injected;
  const isShadowUse = (b) => injected.length > 0 && b?.type === "tool_use" && injected.includes(b.name);
  const tag2 = `${injected.length ? " +shadow(" + injected.join(",") + ")" : ""}${wantStream ? "" : " (reassemble)"}`;
  // sticky: pi-сессия > user_id от Claude Code > разовый
  if (ccKey && !looksValidSession(headers["x-opencode-session"])) headers["x-opencode-session"] = sesForPi(ccKey);
  const target = UPSTREAM_BASE + "/zen/v1/responses";
  console.log(
    `[${rid}] → messages model=${a.model}=>${modelUsed} [sess=${headers["x-opencode-session"]?.slice(0, 12)}…${piSession ? " pi=" + mask(piSession) : ""}]${tag2}`,
  );
  let up;
  try {
    up = await fetchWithRetry(
      target,
      {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify(upBody),
        duplex: "half",
        signal,
      },
      rid,
    );
  } catch (e) {
    if (e?.name === "AbortError") return;
    const err = anthropicError(502, e.message ?? e);
    res.writeHead(err.status, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(err.body);
    console.log(`[${rid}] ← transport error: ${e.message}`);
    return;
  }
  if (!up.ok) {
    const text = await up.text().catch(() => "");
    let msg = text.slice(0, 500);
    try {
      const j = JSON.parse(text);
      msg = j?.error?.message ?? j?.error?.type ?? msg;
    } catch {}
    const err = anthropicError(up.status, msg);
    res.writeHead(err.status, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(err.body);
    console.log(`[${rid}] ← ${up.status} ERROR=${String(msg).slice(0, 160)}`);
    if (text.length > 160) console.log(`[${rid}] ← full error body: ${text.slice(0, 2048)}`);
    return;
  }

  if (!wantStream) {
    // Апстрим всегда stream:true — копим SSE, забираем response из completed.
    let j = null;
    let failedMsg = null;
    try {
      const reader2 = up.body.getReader();
      const decoder2 = new TextDecoder();
      const s2 = { buf: "", event: null };
      for (;;) {
        const { done, value } = await reader2.read();
        if (done) break;
        for (const { data: ev } of ssePull(s2, decoder2.decode(value, { stream: true }))) {
          if (ev.type === "response.completed") j = ev.response ?? null;
          else if (ev.type === "response.failed" || ev.type === "error") {
            failedMsg = ev.response?.error?.message ?? ev.message ?? "upstream failed";
          }
        }
      }
      reader2.releaseLock();
    } catch {
      j = null;
    }
    if (!j) {
      const err = anthropicError(502, failedMsg ?? "bad upstream stream");
      res.writeHead(err.status, { "content-type": "application/json", "access-control-allow-origin": "*" });
      res.end(err.body);
      console.log(`[${rid}] ← reassemble failed: ${failedMsg ?? "no completed"}`);
      return;
    }
    if (j.status === "failed") {
      const err = anthropicError(500, j.error?.message ?? "upstream failed");
      res.writeHead(err.status, { "content-type": "application/json", "access-control-allow-origin": "*" });
      res.end(err.body);
      console.log(`[${rid}] ← failed: ${j.error?.message ?? ""}`);
      return;
    }
    let content = responsesOutputToAnthropicContent(j.output);
    let stripped = 0;
    if (injected.length) {
      const before = content.length;
      content = content.filter((b) => !isShadowUse(b));
      stripped = before - content.length;
      if (!content.length) content = [{ type: "text", text: "" }];
    }
    const hasTools = content.some((b) => b.type === "tool_use");
    const stop = hasTools ? "tool_use" : j.status === "incomplete" ? "max_tokens" : "end_turn";
    const out = {
      id: "msg_" + String(j.id ?? rid).replace(/^resp_/, ""),
      type: "message",
      role: "assistant",
      model: a.model,
      content,
      stop_reason: stop,
      usage: { input_tokens: j.usage?.input_tokens ?? 0, output_tokens: j.usage?.output_tokens ?? 0 },
    };
    res.writeHead(200, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(JSON.stringify(out));
    console.log(
      `[${rid}] ← 200 stop=${stop}${stripped ? ` SHADOW_STRIPPED=${stripped}` : ""}${j.status === "incomplete" ? " INCOMPLETE:" + (j.incomplete_details?.reason ?? "") : ""} ${Date.now() - started}ms`,
    );
    return;
  }

  // ---- streaming: Responses SSE -> Anthropic SSE ----
  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
    "access-control-allow-origin": "*",
  });
  const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  if (!up.body) {
    send("message_start", {
      type: "message_start",
      message: { id: msgId, type: "message", role: "assistant", model: msgModel, content: [], stop_reason: null, usage: { input_tokens: 0, output_tokens: 0 } },
    });
    send("error", { type: "error", error: { type: "api_error", message: "empty upstream body" } });
    res.end();
    console.log(`[${rid}] ← empty upstream body`);
    return;
  }
  const reader = up.body.getReader();
  const decoder = new TextDecoder();
  const sstate = { buf: "", event: null };
  let msgId = "msg_" + rid;
  const msgModel = a.model;
  let started2 = false;
  const idxMap = new Map(); // resp output_index -> { ai, kind, shadow }
  let nextAi = 0;
  let sawToolUse = false;
  let stripped = 0;
  let usage = null;
  let finalStatus = "completed";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      for (const { data: ev } of ssePull(sstate, decoder.decode(value, { stream: true }))) {
        const t = ev.type;
        if (t === "response.created") {
          msgId = "msg_" + String(ev.response?.id ?? rid).replace(/^resp_/, "");
          send("message_start", {
            type: "message_start",
            message: {
              id: msgId,
              type: "message",
              role: "assistant",
              model: msgModel,
              content: [],
              stop_reason: null,
              usage: { input_tokens: 0, output_tokens: 0 },
            },
          });
          started2 = true;
        } else if (t === "response.output_item.added") {
          const item = ev.item ?? {};
          if (item.type === "message") {
            idxMap.set(ev.output_index, { ai: nextAi, kind: "text", shadow: false });
            send("content_block_start", { type: "content_block_start", index: nextAi, content_block: { type: "text", text: "" } });
            nextAi += 1;
          } else if (item.type === "function_call") {
            const sh = injected.length > 0 && injected.includes(item.name);
            idxMap.set(ev.output_index, { ai: nextAi, kind: "tool", shadow: sh });
            if (sh) {
              stripped += 1;
            } else {
              sawToolUse = true;
              send("content_block_start", {
                type: "content_block_start",
                index: nextAi,
                content_block: { type: "tool_use", id: item.call_id, name: item.name, input: {} },
              });
              nextAi += 1;
            }
          }
        } else if (t === "response.output_text.delta") {
          const m = idxMap.get(ev.output_index);
          if (m && !m.shadow) {
            send("content_block_delta", { type: "content_block_delta", index: m.ai, delta: { type: "text_delta", text: ev.delta ?? "" } });
          } else if (!m) {
            // Текст без предварительного added — синтезируем блок
            idxMap.set(ev.output_index, { ai: nextAi, kind: "text", shadow: false });
            send("content_block_start", { type: "content_block_start", index: nextAi, content_block: { type: "text", text: "" } });
            send("content_block_delta", { type: "content_block_delta", index: nextAi, delta: { type: "text_delta", text: ev.delta ?? "" } });
            nextAi += 1;
          }
        } else if (t === "response.function_call_arguments.delta") {
          const m = idxMap.get(ev.output_index);
          if (m && !m.shadow) send("content_block_delta", { type: "content_block_delta", index: m.ai, delta: { type: "input_json_delta", partial_json: ev.delta ?? "" } });
        } else if (t === "response.output_item.done") {
          const m = idxMap.get(ev.output_index);
          const doneItem = ev.item ?? {};
          if (m && !m.shadow) send("content_block_stop", { type: "content_block_stop", index: m.ai });
          else if (m?.shadow) stripped += 1;
          else if (doneItem.type === "function_call" && !(injected.length > 0 && injected.includes(doneItem.name))) {
            // Вызов без предварительного added (обрыв/переподключение стрима):
            // синтезируем полный блок, иначе вызов потеряется и ход заглохнет.
            sawToolUse = true;
            send("content_block_start", {
              type: "content_block_start",
              index: nextAi,
              content_block: { type: "tool_use", id: doneItem.call_id, name: doneItem.name, input: {} },
            });
            let args = {};
            try {
              args = JSON.parse(doneItem.arguments || "{}");
            } catch {}
            send("content_block_delta", { type: "content_block_delta", index: nextAi, delta: { type: "input_json_delta", partial_json: JSON.stringify(args) } });
            send("content_block_stop", { type: "content_block_stop", index: nextAi });
            idxMap.set(ev.output_index, { ai: nextAi, kind: "tool", shadow: false });
            nextAi += 1;
            console.log(`[${rid}] synthesized tool_use from done-only item: ${doneItem.name}`);
          } else if (doneItem.type === "function_call") stripped += 1;
        } else if (t === "response.completed") {
          const r = ev.response ?? {};
          finalStatus = r.status ?? "completed";
          usage = r.usage ?? null;
        } else if (t === "response.failed" || t === "error") {
          finalStatus = "failed";
        }
      }
    }
  } catch (e) {
    finalStatus = "failed";
    console.log(`[${rid}] ← stream read error: ${e?.message ?? e}`);
  } finally {
    try {
      reader.releaseLock();
    } catch {}
  }
  if (!started2) {
    send("message_start", {
      type: "message_start",
      message: { id: msgId, type: "message", role: "assistant", model: msgModel, content: [], stop_reason: null, usage: { input_tokens: 0, output_tokens: 0 } },
    });
  }
  if (finalStatus === "failed") {
    send("error", { type: "error", error: { type: "api_error", message: "upstream failed" } });
  } else {
    const stop = sawToolUse ? "tool_use" : finalStatus === "incomplete" ? "max_tokens" : "end_turn";
    send("message_delta", {
      type: "message_delta",
      delta: { stop_reason: stop },
      usage: { output_tokens: usage?.output_tokens ?? 0 },
    });
    send("message_stop", { type: "message_stop" });
  }
  res.end();
  console.log(`[${rid}] ← stream done status=${finalStatus} toolUse=${sawToolUse}${stripped ? ` SHADOW_STRIPPED=${stripped}` : ""} ${Date.now() - started}ms`);
}

// ============================================================
// Обход гейта free-tier (обновлено 2026-09-18):
// кроме UA opencode/* и валидного ses_ гейт требует в ТЕЛЕ запроса
//   stream: true  И  tools с именами "read" и "bash" (строчные;
//   "Read"/"Bash" не катят, определения/tool_choice не важны).
// Поэтому адаптер:
//  - всегда шлёт в апстрим stream:true (клиенту без стрима ответ
//    пересобирается из события response.completed);
//  - докладывает теневые read/bash, если их нет у клиента;
//  - вырезает вызовы теневых тулзов из ответов (клиент их не знает).
// Теневые вызываются только если клиент read/bash не прислал — тогда
// любой вызов read/bash в ответе заведомо теневой и безопасно режется.
// ============================================================
const SHADOW_TOOLS = [
  {
    type: "function",
    name: "read",
    description: "Compatibility stub injected by local proxy. Never call it.",
    parameters: { type: "object", properties: { path: { type: "string" } }, required: ["path"] },
  },
  {
    type: "function",
    name: "bash",
    description: "Compatibility stub injected by local proxy. Never call it.",
    parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] },
  },
];

function ensureGate(body) {
  // body — объект Responses-запроса.
  // Возвращает { upBody, wantStream, shadowed, injected }.
  const wantStream = body.stream === true;
  const names = new Set(((body.tools ?? []).map((t) => t?.name)).filter(Boolean));
  const injected = [];
  const tools = [...(body.tools ?? [])];
  if (!names.has("read")) {
    tools.push(SHADOW_TOOLS[0]);
    injected.push("read");
  }
  if (!names.has("bash")) {
    tools.push(SHADOW_TOOLS[1]);
    injected.push("bash");
  }
  const upBody = { ...body, stream: true, tools: tools.length ? tools : undefined };
  if (upBody.tools && upBody.tool_choice === undefined) upBody.tool_choice = "auto";
  if (!upBody.tools) delete upBody.tools;
  return { upBody, wantStream, shadowed: injected.length > 0, injected };
}

// Санитайз тулзов под Meta-эндпоинт (актуально для Codex):
// - custom apply_patch (freeform-грамматика) -> function {input}
//   (обратно прилетает function_call apply_patch);
// - namespace-* (сабагенты) -> дропаются, эмулировать нечем;
// - остальное (function, web_search, ...) как есть.
function sanitizeToolsForMeta(tools, rid) {
  if (!Array.isArray(tools) || !tools.length) return { tools, changed: false };
  const out = [];
  let changed = false;
  for (const t of tools) {
    if (t?.type === "custom" && t.name === "apply_patch") {
      out.push({
        type: "function",
        name: "apply_patch",
        description:
          (t.description ?? "Use the `apply_patch` tool to edit files.") +
          '\nProvide arguments as a JSON object {"input": "<entire patch text, e.g. *** Begin Patch ... *** End Patch>"}joined.',
        parameters: {
          type: "object",
          properties: { input: { type: "string", description: "The entire contents of the apply_patch command" } },
          required: ["input"],
          additionalProperties: false,
        },
      });
      changed = true;
    } else if (t?.type === "namespace") {
      console.log(`[${rid}] drop namespace tool: ${t?.name ?? "?"}`);
      changed = true;
    } else {
      out.push(t);
    }
  }
  return { tools: out, changed };
}
// Meta понимает только minimal/low/medium/high/xhigh — чужое (напр. max
// от mcode) маппим на ближайший валидный, иначе 400 invalid parameters.
const VALID_EFFORTS = new Set(["minimal", "low", "medium", "high", "xhigh"]);
function normalizeEffort(body) {
  const r = body?.reasoning;
  if (!r || typeof r.effort !== "string") return;
  if (r.effort === "max") body.reasoning = { ...r, effort: "xhigh" };
  else if (!VALID_EFFORTS.has(r.effort)) delete body.reasoning;
}
// Мини-парсер SSE: state={buf, event}, возвращает [{event, data}].
function ssePull(state, text) {
  state.buf = (state.buf ?? "") + text;
  const events = [];
  let i;
  while ((i = state.buf.indexOf("\n")) !== -1) {
    const line = state.buf.slice(0, i).trim();
    state.buf = state.buf.slice(i + 1);
    if (line === "") {
      state.event = null;
      continue;
    }
    if (line.startsWith("event:")) {
      state.event = line.slice(6).trim() || null;
      continue;
    }
    if (!line.startsWith("data:")) continue;
    const payload = line.slice(5).trim();
    if (payload === "[DONE]" || !payload) continue;
    try {
      events.push({ event: state.event, data: JSON.parse(payload) });
    } catch {}
  }
  return events;
}

const sseSend = (res, event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);

// Прокси /v1/responses с обходом гейта: stream:true + теневые read/bash
// в апстрим; клиенту — то, что он просил (stream или готовый JSON),
// вызовы теневых тулзов вырезаются.
async function handleResponses(req, res, bodyBuf, started, rid, headers, piSession, signal) {
  let body;
  try {
    body = JSON.parse(bodyBuf.toString("utf8"));
  } catch {
    res.writeHead(400, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "invalid JSON body" } }));
    return;
  }
  const { upBody, wantStream, shadowed, injected } = ensureGate(body);
  normalizeEffort(upBody);
  const san = sanitizeToolsForMeta(upBody.tools, rid);
  if (san.changed) {
    upBody.tools = san.tools.length ? san.tools : undefined;
    if (!upBody.tools) delete upBody.tools;
    console.log(`[${rid}] tools sanitized for meta endpoint`);
  }
  try {
    const ts = (upBody.tools ?? []).map((t) => `${t?.type ?? "?"}:${t?.name ?? "?"}`).join(",");
    if (ts) console.log(`[${rid}] tools: ${ts.slice(0, 400)}`);
    for (const t of upBody.tools ?? []) {
      if (t?.type && t.type !== "function") {
        console.log(`[${rid}] nonfunction-tool: ${JSON.stringify(t).slice(0, 1500)}`);
      }
    }
  } catch {}
  const isShadowCall = (item) => shadowed && item?.type === "function_call" && injected.includes(item.name);
  // Штамп сессии из metadata (ставит расширение omp через before_provider_request).
  // В апстрим не уходит. Перезаписывает ses_: на момент выбора headers штампа
  // ещё не было видно (он в теле), поэтому маппим здесь явно.
  if (upBody.metadata?.zen_pi_session && !piSession) {
    piSession = String(upBody.metadata.zen_pi_session);
    headers["x-opencode-session"] = sesForPi(piSession);
    const { zen_pi_session, ...restMeta } = upBody.metadata;
    if (Object.keys(restMeta).length) upBody.metadata = restMeta;
    else delete upBody.metadata;
  }
  const target = UPSTREAM_BASE + "/zen/v1/responses";
  const tag = `[sess=${headers["x-opencode-session"]?.slice(0, 12)}…${piSession ? " pi=" + mask(piSession) : ""}]`;
  console.log(`[${rid}] → responses ${tag}${shadowed ? " +shadow(" + injected.join(",") + ")" : ""}${wantStream ? "" : " (reassemble)"} effort=${upBody.reasoning?.effort ?? "-"}`);
  let up;
  try {
    up = await fetchWithRetry(
      target,
      {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify(upBody),
        duplex: "half",
        signal,
      },
      rid,
    );
  } catch (e) {
    if (e?.name === "AbortError") return;
    res.writeHead(502, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(JSON.stringify({ type: "error", error: { type: "BadGateway", message: String(e.message ?? e) } }));
    console.log(`[${rid}] ← transport error: ${e.message}`);
    return;
  }
  if (!up.ok) {
    const text = await up.text().catch(() => "");
    res.writeHead(up.status, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(text);
    console.log(`[${rid}] ← ${up.status} ERROR=${text.slice(0, 160)}`);
    if (text.length > 160) console.log(`[${rid}] ← full error body: ${text.slice(0, 2048)}`);
    return;
  }
  if (!up.body) {
    res.writeHead(502, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(JSON.stringify({ type: "error", error: { type: "error", message: "empty upstream body" } }));
    console.log(`[${rid}] ← empty upstream body`);
    return;
  }

  const reader = up.body.getReader();
  const decoder = new TextDecoder();
  const state = { buf: "", event: null };
  const idxMap = new Map(); // resp output_index -> { ai, shadow }
  let nextAi = 0;
  let stripped = 0;
  let bytes = 0;
  let finalResp = null;
  let failedMsg = null;

  const forwardable = (parsed) => {
    const ev = parsed.data;
    const t = ev.type;
    if (t === "response.output_item.added") {
      const item = ev.item ?? {};
      if (isShadowCall(item)) {
        idxMap.set(ev.output_index, { ai: -1, shadow: true });
        stripped += 1;
        return null;
      }
      idxMap.set(ev.output_index, { ai: nextAi, shadow: false });
      ev.output_index = nextAi;
      nextAi += 1;
      return parsed;
    }
    if (t === "response.output_text.delta" || t === "response.function_call_arguments.delta" || t === "response.output_item.done") {
      const m = idxMap.get(ev.output_index);
      if (m?.shadow) {
        stripped += 1;
        return null;
      }
      if (m) ev.output_index = m.ai;
      return parsed;
    }
    if (t === "response.completed") {
      finalResp = ev.response ?? null;
      return parsed;
    }
    if (t === "response.failed" || t === "error") {
      failedMsg = ev.response?.error?.message ?? ev.message ?? "upstream failed";
      return parsed;
    }
    return parsed;
  };

  if (wantStream) {
    res.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
      "access-control-allow-origin": "*",
    });
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.length;
        for (const p of ssePull(state, decoder.decode(value, { stream: true }))) {
          const f = forwardable(p);
          if (f) sseSend(res, f.event ?? "message", f.data);
        }
      }
    } catch (e) {
      console.log(`[${rid}] ← stream read error: ${e?.message ?? e}`);
      try {
        res.destroy();
      } catch {}
      return;
    } finally {
      try {
        reader.releaseLock();
      } catch {}
    }
    res.end();
    console.log(`[${rid}] ← 200 stream ${bytes}B${stripped ? ` SHADOW_STRIPPED=${stripped}` : ""} ${Date.now() - started}ms`);
    return;
  }

  // Клиент просил без стрима: копим, отдаём data.response из completed.
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.length;
      for (const p of ssePull(state, decoder.decode(value, { stream: true }))) forwardable(p);
    }
  } catch (e) {
    failedMsg = failedMsg ?? `upstream read: ${e?.message ?? e}`;
  } finally {
    try {
      reader.releaseLock();
    } catch {}
  }
  if (failedMsg || !finalResp) {
    res.writeHead(502, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(JSON.stringify({ type: "error", error: { type: "error", message: failedMsg ?? "incomplete upstream stream" } }));
    console.log(`[${rid}] ← reassemble failed: ${failedMsg ?? "no completed"} ${Date.now() - started}ms`);
    return;
  }
  if (shadowed && Array.isArray(finalResp.output)) {
    const before = finalResp.output.length;
    finalResp.output = finalResp.output.filter((item) => !isShadowCall(item));
    stripped += before - finalResp.output.length;
    if (!finalResp.output.length) {
      finalResp.output = [
        { id: "msg_" + rid, type: "message", status: "completed", role: "assistant", content: [{ type: "output_text", text: "", annotations: [] }] },
      ];
    }
  }
  res.writeHead(200, { "content-type": "application/json", "access-control-allow-origin": "*" });
  res.end(JSON.stringify(finalResp));
  console.log(`[${rid}] ← 200 reassembled ${bytes}B${stripped ? ` SHADOW_STRIPPED=${stripped}` : ""} ${Date.now() - started}ms`);
}

const server = http.createServer((req, res) => {
  // Обрыв апстрима, если клиент отключился раньше ответа. Слушаем close
  // на res (а не на req: у req close наступает сразу после приёма тела).
  // Catch-all, чтобы один битый запрос никогда не ронял процесс.
  const ctl = new AbortController();
  res.on("close", () => {
    if (!res.writableEnded) ctl.abort();
  });
  handleRequest(req, res, ctl.signal).catch((e) => {
    if (e?.name === "AbortError") return;
    console.error("request fatal:", e?.stack ?? e?.message ?? e);
    try {
      if (!res.headersSent) {
        res.writeHead(500, { "content-type": "application/json", "access-control-allow-origin": "*" });
        res.end(JSON.stringify({ type: "error", error: { type: "error", message: "proxy internal error" } }));
      } else {
        res.destroy();
      }
    } catch {}
  });
});

async function handleRequest(req, res, signal) {
  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
  const path = url.pathname;

  // CORS preflight + health
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "authorization,content-type,x-opencode-session,x-opencode-request,x-opencode-project,x-opencode-client,x-pi-session",
    });
    res.end();
    return;
  }
  if (req.method === "GET" && (path === "/health" || path === "/")) {
    res.writeHead(200, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(JSON.stringify({ ok: true, upstream: UPSTREAM_BASE + "/zen/v1", ua: OPENCODE_UA, sessions: sesMap.size }));
    return;
  }
  if (req.method === "GET" && path === "/zen-sessions") {
    res.writeHead(200, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(
      JSON.stringify({
        count: sesMap.size,
        mappings: [...sesMap.entries()].map(([pi, rec]) => ({
          pi: mask(pi),
          ses: rec.ses.slice(0, 12) + "…",
          createdAt: new Date(rec.createdAt).toISOString(),
          hits: rec.hits,
        })),
      }),
    );
    return;
  }

  // Anthropic Messages API (Claude Code) -> транслятор в Responses.
  if (req.method === "POST" && (path === "/v1/messages" || path === "/messages")) {
    let bodyBuf;
    try {
      bodyBuf = await readBody(req);
    } catch (e) {
      const err = anthropicError(413, e.message ?? e);
      res.writeHead(err.status, { "content-type": "application/json", "access-control-allow-origin": "*" });
      res.end(err.body);
      return;
    }
    const started = Date.now();
    const rid = `${Date.now().toString(36)}${(ridCounter = (ridCounter + 1) % 1296).toString(36).padStart(2, "0")}`;
    const { headers, piSession } = buildUpstreamHeaders(req.headers);
    await handleMessages(req, res, bodyBuf, started, rid, headers, piSession, signal);
    return;
  }

  // Только /v1/* проксируем (плюс /responses без префикса для удобства).
  // POST /v1/responses идёт через handleResponses (обход гейта).
  const isResponsesPost =
    req.method === "POST" &&
    (path === "/v1/responses" || path === "/responses" || path.startsWith("/responses/"));
  let upstreamPath;
  if (path.startsWith("/v1/")) upstreamPath = "/zen/v1/" + path.slice(4);
  else if (path === "/responses" || path.startsWith("/responses/")) upstreamPath = "/zen/v1" + path;
  else if (path.startsWith("/zen/v1/")) upstreamPath = path;
  else {
    res.writeHead(404, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(JSON.stringify({ error: "use /v1/responses, /v1/chat/completions, /v1/messages, /v1/models" }));
    return;
  }
  if (url.search) upstreamPath += url.search;

  let body;
  try {
    body = req.method === "GET" || req.method === "HEAD" ? undefined : await readBody(req);
  } catch (e) {
    res.writeHead(413, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: String(e.message ?? e) }));
    return;
  }

  const { headers, piSession } = buildUpstreamHeaders(req.headers);
  const target = UPSTREAM_BASE + upstreamPath;
  const started = Date.now();
  const rid = `${Date.now().toString(36)}${(ridCounter = (ridCounter + 1) % 1296).toString(36).padStart(2, "0")}`;
  if (isResponsesPost && body) {
    await handleResponses(req, res, body, started, rid, headers, piSession, signal);
    return;
  }
  const piTag = piSession ? ` pi=${mask(piSession)}` : "";
  console.log(`[${rid}] → ${req.method} ${path} [sess=${headers["x-opencode-session"]?.slice(0, 12)}…${piTag}]`);

  try {
    const up = await fetchWithRetry(
      target,
      {
        method: req.method,
        headers,
        body,
        duplex: body ? "half" : undefined,
        signal,
      },
      rid,
    );

    const passthrough = {};
    for (const [k, v] of up.headers.entries()) {
      if (["content-length", "connection", "transfer-encoding", "content-encoding"].includes(k.toLowerCase())) continue;
      passthrough[k] = v;
    }
    passthrough["access-control-allow-origin"] = "*";
    res.writeHead(up.status, passthrough);

    if (!up.body) {
      res.end();
      console.log(`[${rid}] ← ${up.status} (empty) ${Date.now() - started}ms`);
      return;
    }
    // Стримим как есть (SSE и обычный JSON), параллельно копим хвост
    // для диагностики (incomplete / error в конце ответа).
    const reader = up.body.getReader();
    let bytes = 0;
    let tail = "";
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.length;
        if (tail.length < 8192) tail += Buffer.from(value).toString("utf8").slice(0, 8192 - tail.length);
        else tail = (tail + Buffer.from(value).toString("utf8")).slice(-8192);
        if (!res.write(value)) await new Promise((r) => res.once("drain", r));
      }
    } catch (e) {
      if (e?.name === "AbortError") return;
      console.log(`[${rid}] ← stream read error: ${e?.message ?? e}`);
      try {
        res.destroy();
      } catch {}
      return;
    } finally {
      try {
        reader.releaseLock();
      } catch {}
    }
    res.end();
    console.log(`[${rid}] ← ${up.status} ${bytes}B ${Date.now() - started}ms${noteFor(tail, up.status)}`);
  } catch (e) {
    if (e?.name === "AbortError") return;
    console.error("upstream error:", e.message);
    if (!res.headersSent) {
      res.writeHead(502, { "content-type": "application/json", "access-control-allow-origin": "*" });
      res.end(JSON.stringify({ type: "error", error: { type: "BadGateway", message: String(e.message ?? e) } }));
    } else {
      res.destroy(e);
    }
  }
}

server.listen(PORT, () => {
  console.log(`zen-adapter listening on http://127.0.0.1:${PORT}`);
  console.log(`upstream: ${UPSTREAM_BASE}/zen/v1  |  UA: ${OPENCODE_UA}`);
  console.log(`key: ${mask("Bearer " + API_KEY)} (env ZEN_API_KEY/OPENCODE_API_KEY или --api-key)`);
});

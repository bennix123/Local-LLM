// Penny — on-device finance UI, wired to the local backend.
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// ---- shared formatting ----
let SYM = "₹";
const M = (n) => SYM + Math.abs(Number(n) || 0).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const M0 = (n) => SYM + Math.abs(Number(n) || 0).toLocaleString("en-IN", { maximumFractionDigits: 0 });
const N = (n) => Number(n || 0).toLocaleString("en-IN");
const MN = { "01": "Jan", "02": "Feb", "03": "Mar", "04": "Apr", "05": "May", "06": "Jun", "07": "Jul", "08": "Aug", "09": "Sep", "10": "Oct", "11": "Nov", "12": "Dec" };
const mlabel = (ym) => `${MN[ym.split("-")[1]]} ${ym.split("-")[0]}`;
const CAT_ICON = { Groceries: "🛒", "Food & Dining": "🍔", Transport: "🚇", Shopping: "🛍️", Utilities: "💡", Entertainment: "🎬", Healthcare: "🩺", "Investment & Insurance": "📈", "Credit Card": "💳", Rent: "🏠", Salary: "💰", Interest: "💵", "Other / Transfers": "🔄" };
const CAT_COLOR = { Groceries: "#84cc16", "Food & Dining": "#ff6b6b", Transport: "#a855f7", Shopping: "#ff9f56", Utilities: "#3b82f6", Entertainment: "#ec4899", Healthcare: "#34d399", "Investment & Insurance": "#eab308", "Credit Card": "#f97316", Rent: "#06b6d4", Salary: "#22c55e", "Other / Transfers": "#94a3b8" };
const IC = (c) => CAT_ICON[c] || "•";
const COL = (c) => CAT_COLOR[c] || "#94a3b8";

// ---- markdown (tables + bold) for chat answers ----
const splitRow = (l) => l.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|").map((c) => c.trim());
const inlineMd = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
function mdToHtml(text) {
  const lines = String(text).split("\n"); let html = ""; let i = 0;
  while (i < lines.length) {
    const l = lines[i];
    const sep = i + 1 < lines.length && /-/.test(lines[i + 1]) && /^\s*\|?[\s:|-]+$/.test(lines[i + 1]);
    if (/\|/.test(l) && sep) {
      const head = splitRow(l); i += 2; const rows = [];
      while (i < lines.length && /\|/.test(lines[i]) && lines[i].trim()) { rows.push(splitRow(lines[i])); i++; }
      html += "<table class='resp'><thead><tr>" + head.map((h) => "<th>" + inlineMd(h) + "</th>").join("") +
        "</tr></thead><tbody>" + rows.map((r) => "<tr>" + r.map((c) => "<td>" + inlineMd(c) + "</td>").join("") + "</tr>").join("") + "</tbody></table>";
      continue;
    }
    if (l.trim()) html += "<div>" + inlineMd(l) + "</div>";
    i++;
  }
  return html || "<div></div>";
}

// ---- screens ----
function show(id) { ["scr-hook", "scr-setup", "scr-upload", "app"].forEach((s) => $(s).classList.add("hidden")); $(id).classList.remove("hidden"); }

let MODELS = [], downloaded = [], selModel = null, DASH = null;

(async function boot() {
  const st = await (await fetch("/api/state")).json();
  MODELS = st.models || []; downloaded = st.downloaded || [];
  selModel = downloaded[0] || ((MODELS.find((m) => m.recommended) || MODELS[0] || {}).id);
  if (st.ready && st.document) return launchApp();
  if (st.ready && !st.document) return show("scr-upload");
  show("scr-hook");
})();

$("hook-btn").onclick = () => { renderModels(); show("scr-setup"); };

function renderModels() {
  $("model-list").innerHTML = MODELS.map((m) => `
    <div class="mk ${m.id === selModel ? "on" : ""}" data-id="${m.id}">
      <div class="mk-ic">${downloaded.includes(m.id) ? "✓" : "⬇"}</div>
      <div class="mk-b"><div class="mk-n">${esc(m.name)}</div><div class="mk-t">${esc(m.approxSize || "")} · ${esc(m.blurb || "")}</div></div>
      <div class="mk-tag">${downloaded.includes(m.id) ? "ready" : "download"}</div>
    </div>`).join("");
  $("model-list").querySelectorAll(".mk").forEach((el) => el.onclick = () => { selModel = el.dataset.id; renderModels(); });
  $("setup-btn").disabled = !selModel;
  $("setup-btn").textContent = downloaded.includes(selModel) ? "Use this model & continue" : "Download & continue";
}

$("setup-btn").onclick = async () => {
  if (!selModel) return;
  $("setup-btn").disabled = true;
  if (downloaded.includes(selModel)) {
    $("dl-progress").classList.remove("hidden"); $("dl-text").textContent = "Loading model…";
    await fetch("/api/load", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: selModel }) });
    afterModelReady();
  } else {
    $("dl-progress").classList.remove("hidden");
    const es = new EventSource("/api/download?id=" + encodeURIComponent(selModel));
    es.addEventListener("progress", (e) => { const d = JSON.parse(e.data); const pct = d.totalSize ? Math.round(d.downloadedSize / d.totalSize * 100) : 0; $("dl-fill").style.width = pct + "%"; $("dl-text").textContent = `Downloading… ${pct}%`; });
    es.addEventListener("status", (e) => { $("dl-text").textContent = JSON.parse(e.data).message; });
    es.addEventListener("done", () => { es.close(); if (!downloaded.includes(selModel)) downloaded.push(selModel); afterModelReady(); });
    es.addEventListener("error", () => { es.close(); $("dl-text").textContent = "❌ download failed — try again"; $("setup-btn").disabled = false; });
  }
};
async function afterModelReady() {
  const st = await (await fetch("/api/state")).json();
  if (st.document) launchApp(); else show("scr-upload");
}

// ---- upload ----
$("upzone").onclick = () => $("file-input").click();
$("file-input").onchange = async (e) => {
  const file = e.target.files[0]; if (!file) return;
  $("up-steps").classList.remove("hidden");
  const setStep = (s, cls) => { const el = $("up-steps").querySelector(`[data-step="${s}"]`); if (el) el.className = "step " + cls; };
  ["upload", "parse", "index", "ready"].forEach((s) => setStep(s, ""));
  setStep("upload", "active");
  const fd = new FormData(); fd.append("file", file);
  try {
    const p = fetch("/api/upload", { method: "POST", body: fd });
    await new Promise((r) => setTimeout(r, 400)); setStep("upload", "done"); setStep("parse", "active");
    const r = await p; const data = await r.json();
    if (!r.ok) { setStep("parse", "error"); return; }
    setStep("parse", "done"); setStep("index", "active");
    await new Promise((r) => setTimeout(r, 400)); setStep("index", "done"); setStep("ready", "done");
    setTimeout(launchApp, 450);
  } catch { setStep("parse", "error"); }
};

// ---- app shell ----
async function launchApp() {
  show("app");
  try { DASH = await (await fetch("/api/dashboard")).json(); SYM = DASH.currency || "₹"; } catch { DASH = { ready: false }; }
  setTab("today");
}
document.querySelectorAll(".bnt").forEach((b) => b.onclick = () => setTab(b.dataset.v));
$("reset-btn").onclick = async () => {
  if (confirm("Clear current statement and upload a new one?")) {
    await fetch("/api/reset", { method: "POST" });
    window.location.reload();
  }
};
function setTab(v) {
  document.querySelectorAll(".bnt").forEach((b) => b.classList.toggle("on", b.dataset.v === v));
  const view = $("view");
  if (v === "today") renderToday(view);
  else if (v === "chat") renderChat(view);
  else if (v === "patterns") renderPatterns(view);
  else if (v === "bills") renderBills(view);
  else if (v === "data") renderData(view);
}

// ---- TODAY ----
function renderToday(view) {
  const d = DASH; if (!d || !d.ready) { view.innerHTML = `<div class="empty">No statement loaded.</div>`; return; }
  const tot = d.totals.spending || 1;
  const bar = d.categories.map((c) => `<span style="width:${(c.amount / tot * 100).toFixed(1)}%;background:${COL(c.name)}"></span>`).join("");
  const pills = d.categories.slice(0, 7).map((c) => `<div class="cat-pill"><div class="cat-pill-icon">${IC(c.name)}</div><div class="cat-pill-amt">${M0(c.amount)}</div><div class="cat-pill-name">${esc(c.name)}</div><div class="cat-pill-trend">${c.count} txns</div></div>`).join("");
  const months = d.months.slice(-12); const mx = Math.max(...months.map((m) => m.spending), 1);
  const trend = months.map((m) => `<div class="b" title="${m.ym}: ${M0(m.spending)}"><i style="height:${Math.max(m.spending / mx * 100, 3)}%"></i><label>${m.ym.slice(2).replace("-", "/")}</label></div>`).join("");
  const recent = d.recent.map((r) => { const out = Number(r.amount) < 0; return `<div class="txn"><div class="txn-icon" style="background:${COL(r.category)}22">${IC(r.category)}</div><div class="txn-body"><div class="txn-name">${esc(r.payee)}</div><div class="txn-meta">${r.date} · ${esc(r.category || "")}</div></div><div class="txn-amt ${out ? "out" : "in"}">${out ? "−" : "+"}${M0(r.amount)}</div></div>`; }).join("");
  view.innerHTML = `<div class="today">
    <div class="hero-card">
      <div class="hero-l">Closing balance</div>
      <div class="hero-amt">${d.balance != null ? M(d.balance) : "—"}</div>
      <div class="hero-grid">
        <div><div class="hero-l">Income</div><div class="hero-v in">${M0(d.totals.income)}</div></div>
        <div><div class="hero-l">Spending</div><div class="hero-v out">${M0(d.totals.spending)}</div></div>
        <div><div class="hero-l">Net</div><div class="hero-v ${d.totals.net < 0 ? "out" : "in"}">${d.totals.net < 0 ? "−" : "+"}${M0(d.totals.net)}</div></div>
      </div>
      <div class="hero-bar-wrap">${bar}</div>
    </div>
    <div class="sec-h"><span>Top categories</span><span>${N(d.totals.count)} txns</span></div>
    <div class="cat-list">${pills}</div>
    <div class="sec-h"><span>Monthly spending</span></div>
    <div class="trend">${trend}</div>
    <div class="sec-h"><span>Recent</span></div>
    <div>${recent}</div>
  </div>`;
}

// ---- PATTERNS ----
function renderPatterns(view) {
  const d = DASH; if (!d || !d.ready) { view.innerHTML = `<div class="empty">No data.</div>`; return; }
  const tot = d.totals.spending || 1; const top = d.categories[0] || { name: "—", amount: 0, count: 0 };
  const ms = [...d.months].sort((a, b) => b.spending - a.spending); const hi = ms[0], lo = ms[ms.length - 1];
  const lg = d.largest;
  const payees = (d.topPayees || []).map((p) => `<div class="bar-data"><span>${esc(p.name)}</span><span>${M0(p.amount)}</span></div>`).join("");
  const cats = d.categories.map((c) => `<div class="bar-data"><span>${IC(c.name)} ${esc(c.name)}</span><span>${M0(c.amount)} · ${(c.amount / tot * 100).toFixed(0)}%</span></div>`).join("");
  view.innerHTML = `<div class="patterns">
    <div class="pattern-card urgent">
      <div class="pattern-tag warn">biggest leak</div>
      <div class="pattern-h">${esc(top.name)} is your top spend 💸</div>
      <div class="pattern-p"><b>${M0(top.amount)}</b> across <b>${top.count}</b> transactions — <span class="warn">${(top.amount / tot * 100).toFixed(0)}%</span> of all spending.</div>
      <div class="mini-chart">${cats}</div>
    </div>
    <div class="pattern-card">
      <div class="pattern-tag">extremes</div>
      <div class="pattern-h">Highs &amp; lows 📈</div>
      <div class="pattern-p">Most in <b>${mlabel(hi.ym)}</b> (${M0(hi.spending)}), least in <b>${mlabel(lo.ym)}</b> (${M0(lo.spending)}).${lg ? ` Largest single expense <span class="warn">${M0(lg.amount)}</span> to ${esc(lg.payee)} on ${lg.date}.` : ""}</div>
    </div>
    <div class="pattern-card">
      <div class="pattern-tag">top payees</div>
      <div class="pattern-h">Where your money goes 🧾</div>
      <div class="mini-chart">${payees}</div>
    </div>
  </div>`;
}

// ---- BILLS ----
const subIcon = (n) => /netflix/i.test(n) ? "🎬" : /spotify/i.test(n) ? "🎵" : /hotstar|prime|disney/i.test(n) ? "📺" : /jio|airtel|vodafone/i.test(n) ? "📱" : /excitel|broadband/i.test(n) ? "🌐" : "🔁";
function renderBills(view) {
  const d = DASH; if (!d || !d.ready) { view.innerHTML = `<div class="empty">No data.</div>`; return; }
  const subs = d.subscriptions || []; const total = subs.reduce((s, x) => s + x.total, 0);
  const cards = subs.length ? subs.map((s) => `<div class="rm-card"><div class="rm-icon" style="background:${COL("Entertainment")}22">${subIcon(s.name)}</div><div class="rm-body"><div class="rm-title">${esc(s.name)}</div><div class="rm-meta">${s.count} payments · last ${s.last}</div></div><div class="rm-amt">${M0(s.total)}</div></div>`).join("") : `<div class="empty">No subscriptions detected in this statement.</div>`;
  view.innerHTML = `<div class="reminders">
    <div class="rm-section"><div class="rm-section-h"><span>Subscriptions &amp; recurring</span><span class="total">${M0(total)}</span></div>${cards}</div>
  </div>`;
}

// ---- DATA (raw transactions, paged + searchable) ----
let dataState = { offset: 0, limit: 40, q: "" };
function renderData(view) {
  view.innerHTML = `<div class="dataview" style="max-width: 100%; overflow-x: auto;">
    <input class="data-search" id="data-q" placeholder="Search transactions…" value="${esc(dataState.q)}">
    <table class="raw-data-table" style="width: 100%; border-collapse: collapse; margin-top: 10px;">
      <thead>
        <tr style="border-bottom: 2px solid var(--line); text-align: left; font-family: 'JetBrains Mono', monospace; font-size: 11px; color: var(--dim);">
          <th style="padding: 10px 8px;">Date</th>
          <th style="padding: 10px 8px;">Description</th>
          <th style="padding: 10px 8px;">Category</th>
          <th style="padding: 10px 8px; text-align: right;">Amount</th>
          <th style="padding: 10px 8px; text-align: right;">Balance</th>
        </tr>
      </thead>
      <tbody id="data-rows"></tbody>
    </table>
    <div class="data-foot" style="margin-top: 15px;"><button class="pgbtn" id="pg-prev">‹ Prev</button><span class="pginfo" id="pg-info"></span><button class="pgbtn" id="pg-next">Next ›</button></div>
  </div>`;
  let t; $("data-q").oninput = (e) => { clearTimeout(t); t = setTimeout(() => { dataState.q = e.target.value; dataState.offset = 0; loadData(); }, 300); };
  $("pg-prev").onclick = () => { dataState.offset = Math.max(0, dataState.offset - dataState.limit); loadData(); };
  $("pg-next").onclick = () => { dataState.offset += dataState.limit; loadData(); };
  loadData();
}
async function loadData() {
  const { offset, limit, q } = dataState;
  const d = await (await fetch(`/api/transactions?offset=${offset}&limit=${limit}&q=${encodeURIComponent(q)}`)).json();
  $("data-rows").innerHTML = d.rows.length ? d.rows.map((r) => { 
    const out = Number(r.amount) < 0; 
    return `<tr style="border-bottom: 1px solid var(--line-soft); font-size: 13px;">
      <td style="padding: 10px 8px; white-space: nowrap; font-family: 'JetBrains Mono', monospace;">${r.date}</td>
      <td style="padding: 10px 8px; font-weight: 600;">${esc(r.payee)}</td>
      <td style="padding: 10px 8px;"><span style="background: ${COL(r.category)}22; color: ${COL(r.category)}; padding: 2px 8px; border-radius: 8px; font-size: 11px; font-weight: 600;">${esc(r.category || "Other")}</span></td>
      <td style="padding: 10px 8px; text-align: right; font-weight: 700; font-family: 'JetBrains Mono', monospace;" class="${out ? "out" : "in"}">${out ? "−" : "+"}${M0(r.amount)}</td>
      <td style="padding: 10px 8px; text-align: right; font-family: 'JetBrains Mono', monospace; color: var(--dim);">${r.balance != null ? M0(r.balance) : "—"}</td>
    </tr>`; 
  }).join("") : `<tr><td colspan="5" class="empty" style="text-align: center; padding: 30px;">No matching transactions.</td></tr>`;
  $("pg-info").textContent = d.total ? `${N(offset + 1)}–${N(Math.min(offset + limit, d.total))} of ${N(d.total)}` : "0";
  $("pg-prev").disabled = offset <= 0;
  $("pg-next").disabled = offset + limit >= d.total;
}

// ---- CHAT (real, streamed, with table rendering) ----
const CHAT = [];
// Penny MLX memory mode — conversation-aware answers (entity memory + pronoun resolution +
// context-LoRA) via the local Penny MLX server, over the Paytm statement.
let PENNY_MODE = false;
const PENNY_SESSION = "web-" + Math.random().toString(36).slice(2, 10);

function renderChat(view) {
  view.innerHTML = `<div class="chat-view">
    <div class="chero"><div class="cav">P</div><div style="flex:1"><div class="chero-name">penny</div><div class="chero-status" id="cstatus">on-device · ask anything</div></div>
      <button class="fun-btn" id="mem-toggle" title="Conversation-aware memory (follow-ups, pronouns) via the Penny MLX server" style="margin-left:auto">🧠 Memory: off</button></div>
    <div class="fun-actions" id="fun"></div>
    <div class="cbody" id="cbody"></div>
    <div class="cinput"><input id="ci" placeholder="Ask about your statement…" autocomplete="off"><button class="send-btn" id="send">→</button></div>
  </div>`;
  const fun = [["📊 Summary", "Summarize my spending over the last 6 months."], ["🍔 Top categories", "What are my top spending categories?"], ["💸 Biggest expense", "What was my largest single expense?"], ["📅 2024", "Give me month-wise expenditure for 2024."]];
  $("fun").innerHTML = fun.map((f, i) => `<button class="fun-btn" data-i="${i}">${f[0]}</button>`).join("");
  $("fun").querySelectorAll(".fun-btn").forEach((b) => b.onclick = () => sendChat(fun[b.dataset.i][1]));
  
  if (CHAT.length) {
    $("cbody").innerHTML = "";
    CHAT.forEach((m, idx) => renderMessageElement(m, idx));
  } else {
    $("cbody").innerHTML = `<div class="empty">Ask anything — totals, a merchant, a category, a month, or a trend.</div>`;
  }
  const go = () => { const v = $("ci").value.trim(); if (v) { $("ci").value = ""; sendChat(v); } };
  $("send").onclick = go; $("ci").onkeydown = (e) => { if (e.key === "Enter") go(); };

  const mt = $("mem-toggle");
  if (mt) {
    const paint = () => {
      mt.textContent = "🧠 Memory: " + (PENNY_MODE ? "on" : "off");
      mt.style.background = PENNY_MODE ? "var(--lime, #c6f24e)" : "";
      $("cstatus").textContent = PENNY_MODE ? "conversation memory · Paytm statement" : "on-device · ask anything";
      $("ci").placeholder = PENNY_MODE ? "Ask a follow-up… e.g. 'and the one before it?'" : "Ask about your statement…";
    };
    mt.onclick = async () => {
      PENNY_MODE = !PENNY_MODE;
      if (PENNY_MODE) { try { await fetch("/api/penny/reset", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ session: PENNY_SESSION }) }); } catch {} }
      paint();
    };
    paint();
  }
}

function renderMessageElement(m, idx) {
  const cb = $("cbody");
  if (!cb) return;
  const empty = cb.querySelector(".empty"); if (empty) empty.remove();
  
  const d = document.createElement("div");
  d.className = "cmg " + m.who;
  d.dataset.idx = idx;

  if (m.who === "us") {
    d.innerHTML = `
      <div class="cmg-bubble-wrapper">
        <div class="cmg-bubble">${m.html}</div>
        <div class="us-actions">
          <span class="edit-btn" onclick="editUserMessage(${idx})">✏️ Edit</span>
        </div>
      </div>
    `;
  } else {
    const isLlm = m.answerType === "llm";
    const badgeText = isLlm ? "✨ Generated by LLM" : "📊 Computed via SQL";
    const badgeClass = isLlm ? "badge-llm" : "badge-sql";
    const feedbackLike = m.liked === true ? "active" : "";
    const feedbackDislike = m.liked === false ? "active" : "";
    
    d.innerHTML = `
      <div class="cmg-bubble">${m.html}</div>
      <div class="ai-meta">
        <span class="source-badge ${badgeClass}">${badgeText}</span>
        <div class="feedback-actions">
          <button class="feedback-btn like-btn ${feedbackLike}" onclick="rateMessage(${idx}, true)" title="Like">👍</button>
          <button class="feedback-btn dislike-btn ${feedbackDislike}" onclick="rateMessage(${idx}, false)" title="Dislike">👎</button>
          <button class="feedback-btn regen-btn" onclick="regenerateMessage(${idx})" title="Regenerate">🔁 Regenerate</button>
        </div>
      </div>
    `;
  }
  
  cb.appendChild(d);
  cb.scrollTop = cb.scrollHeight;
}

window.editUserMessage = function(idx) {
  const cb = $("cbody");
  const d = cb.querySelector(`[data-idx="${idx}"]`);
  if (!d) return;
  
  const originalText = CHAT[idx].text;
  const bubbleWrapper = d.querySelector(".cmg-bubble-wrapper");
  bubbleWrapper.innerHTML = `
    <div class="edit-container">
      <textarea class="edit-textarea">${esc(originalText)}</textarea>
      <div class="edit-buttons">
        <button class="btn-save" onclick="saveUserMessage(${idx})">Save</button>
        <button class="btn-cancel" onclick="cancelEditMessage(${idx})">Cancel</button>
      </div>
    </div>
  `;
};

window.cancelEditMessage = function(idx) {
  const view = $("view");
  renderChat(view);
};

window.saveUserMessage = function(idx) {
  const cb = $("cbody");
  const d = cb.querySelector(`[data-idx="${idx}"]`);
  if (!d) return;
  
  const textarea = d.querySelector(".edit-textarea");
  const newText = textarea.value.trim();
  if (!newText) return;
  
  CHAT.splice(idx);
  const view = $("view");
  renderChat(view);
  sendChat(newText);
};

window.rateMessage = function(idx, rating) {
  const msg = CHAT[idx];
  if (!msg) return;
  msg.liked = msg.liked === rating ? null : rating;
  
  const cb = $("cbody");
  const d = cb.querySelector(`[data-idx="${idx}"]`);
  if (d) {
    const likeBtn = d.querySelector(".like-btn");
    const dislikeBtn = d.querySelector(".dislike-btn");
    if (likeBtn && dislikeBtn) {
      likeBtn.classList.toggle("active", msg.liked === true);
      dislikeBtn.classList.toggle("active", msg.liked === false);
    }
  }
};

window.regenerateMessage = async function(idx) {
  let queryText = "";
  for (let i = idx - 1; i >= 0; i--) {
    if (CHAT[i].who === "us") {
      queryText = CHAT[i].text;
      break;
    }
  }
  
  if (!queryText) return;
  
  CHAT.splice(idx);
  const view = $("view");
  renderChat(view);
  sendChat(queryText, true);
};

async function sendChat(text, forceLLM = false) {
  const userIdx = CHAT.length;
  const userMsg = { who: "us", html: esc(text), text: text };
  CHAT.push(userMsg);
  renderMessageElement(userMsg, userIdx);
  
  const cb = $("cbody");
  const t = document.createElement("div");
  t.className = "typing";
  t.innerHTML = "<span></span><span></span><span></span>";
  cb.appendChild(t);
  cb.scrollTop = cb.scrollHeight;
  
  try {
    const res = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: text, forceLLM: forceLLM, penny: PENNY_MODE, session: PENNY_SESSION })
    });
    t.remove();
    
    if (!res.ok) {
      const errText = (await res.json()).error || "error";
      const errMsg = { who: "ai", html: "⚠️ " + errText, text: errText, answerType: "llm" };
      const aiIdx = CHAT.length;
      CHAT.push(errMsg);
      renderMessageElement(errMsg, aiIdx);
      return;
    }
    
    const answerType = res.headers.get("X-Answer") || "sql";
    const aiIdx = CHAT.length;
    const aiMsg = { who: "ai", html: "…", text: "", answerType: answerType };
    CHAT.push(aiMsg);
    
    renderMessageElement(aiMsg, aiIdx);
    const d = cb.querySelector(`[data-idx="${aiIdx}"]`);
    const bubble = d.querySelector(".cmg-bubble");
    
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let full = "";
    
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      full += dec.decode(value, { stream: true });
      bubble.textContent = full;
      cb.scrollTop = cb.scrollHeight;
    }
    
    const finalHtml = mdToHtml(full || "(no response)");
    bubble.innerHTML = finalHtml;
    
    CHAT[aiIdx].html = finalHtml;
    CHAT[aiIdx].text = full;
    
    cb.scrollTop = cb.scrollHeight;
  } catch (err) {
    t.remove();
    const errText = err.message;
    const errMsg = { who: "ai", html: "⚠️ " + errText, text: errText, answerType: "llm" };
    const aiIdx = CHAT.length;
    CHAT.push(errMsg);
    renderMessageElement(errMsg, aiIdx);
  }
}


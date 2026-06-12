// Frontend logic: model setup → upload → chat. Talks to the local server only.

const $ = (id) => document.getElementById(id);
let selectedModelId = null;

function fmtBytes(n) {
  if (!n) return "0 B";
  const u = ["B", "KB", "MB", "GB"];
  const i = Math.floor(Math.log(n) / Math.log(1024));
  return `${(n / Math.pow(1024, i)).toFixed(1)} ${u[i]}`;
}

async function loadState() {
  const res = await fetch("/api/state");
  return res.json();
}

function renderModels(state) {
  const list = $("model-list");
  list.innerHTML = "";
  // Pre-select the recommended model, or the first downloaded one.
  selectedModelId =
    state.downloaded[0] ||
    (state.models.find((m) => m.recommended) || state.models[0]).id;

  for (const m of state.models) {
    const downloaded = state.downloaded.includes(m.id);
    const el = document.createElement("label");
    el.className = "model-option" + (downloaded ? " downloaded" : "");
    if (m.id === selectedModelId) el.classList.add("selected");
    el.innerHTML = `
      <input type="radio" name="model" value="${m.id}" ${
      m.id === selectedModelId ? "checked" : ""
    }/>
      <div>
        <div class="name">${m.name} <span class="size">(${m.approxSize})</span></div>
        <div class="blurb">${m.blurb}${
      m.vendorUrl
        ? ` · <a href="${m.vendorUrl}" target="_blank" rel="noopener">${
            m.vendor || "website"
          } ↗</a>`
        : ""
    }</div>
      </div>`;
    el.querySelector("input").addEventListener("change", () => {
      selectedModelId = m.id;
      document
        .querySelectorAll(".model-option")
        .forEach((x) => x.classList.remove("selected"));
      el.classList.add("selected");
      // If already downloaded, the button just loads it; else it downloads.
      $("download-btn").textContent = state.downloaded.includes(selectedModelId)
        ? "Use this model"
        : "Download selected model";
    });
    list.appendChild(el);
  }
  $("download-btn").disabled = false;
  $("download-btn").textContent = state.downloaded.includes(selectedModelId)
    ? "Use this model"
    : "Download selected model";
}

function showOfflineBadge() {
  $("offline-badge").classList.remove("hidden");
}

function enterApp(state) {
  $("setup").classList.add("hidden");
  $("app").classList.remove("hidden");
  showOfflineBadge();
  $("model-tag").textContent = `Model loaded: ${
    state.loadedModelId || selectedModelId
  } · running locally`;
  if (state.document) showDocInfo(state.document);
  updateChatEnabled(Boolean(state.document));
}

function showDocInfo(doc) {
  const el = $("doc-info");
  el.classList.remove("hidden");
  el.innerHTML = `📄 <strong>${doc.fileName}</strong> — ${doc.rowCount} rows${
    doc.columns.length ? ` · columns: ${doc.columns.join(", ")}` : ""
  }`;
}

function updateChatEnabled(enabled) {
  $("chat-input").disabled = !enabled;
  $("send-btn").disabled = !enabled;
  $("chat-input").placeholder = enabled
    ? "e.g. How much did I spend in total? What's my biggest debit?"
    : "Upload a bank statement first…";
}

// --- Download flow (SSE) --------------------------------------------------
$("download-btn").addEventListener("click", async () => {
  const state = await loadState();
  // Already downloaded → just load it server-side, then enter app.
  if (state.downloaded.includes(selectedModelId)) {
    $("download-btn").disabled = true;
    $("download-btn").textContent = "Loading…";
    const r = await fetch("/api/load", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: selectedModelId }),
    });
    if (r.ok) {
      $("offline-notice").classList.remove("hidden");
      enterApp(await loadState());
    } else {
      alert("Failed to load model: " + (await r.json()).error);
      $("download-btn").disabled = false;
    }
    return;
  }

  $("download-btn").disabled = true;
  $("download-progress").classList.remove("hidden");
  $("progress-text").textContent = "Starting download…";

  const es = new EventSource(
    "/api/download?id=" + encodeURIComponent(selectedModelId)
  );
  es.addEventListener("progress", (e) => {
    const { downloadedSize, totalSize } = JSON.parse(e.data);
    const pct = totalSize ? (downloadedSize / totalSize) * 100 : 0;
    $("progress-fill").style.width = pct.toFixed(1) + "%";
    $("progress-text").textContent = `Downloading… ${fmtBytes(
      downloadedSize
    )} / ${fmtBytes(totalSize)} (${pct.toFixed(0)}%)`;
  });
  es.addEventListener("status", (e) => {
    $("progress-text").textContent = JSON.parse(e.data).message;
  });
  es.addEventListener("done", async () => {
    es.close();
    $("offline-notice").classList.remove("hidden");
    enterApp(await loadState());
  });
  es.addEventListener("error", (e) => {
    es.close();
    let msg = "Download failed.";
    try {
      msg = JSON.parse(e.data).message;
    } catch {}
    $("progress-text").textContent = "❌ " + msg;
    $("download-btn").disabled = false;
  });
});

// --- Upload flow ----------------------------------------------------------
$("file-input").addEventListener("change", async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const fd = new FormData();
  fd.append("file", file);
  $("doc-info").classList.remove("hidden");
  $("doc-info").textContent = "⏳ Parsing & indexing…";
  const r = await fetch("/api/upload", { method: "POST", body: fd });
  const data = await r.json();
  if (!r.ok) {
    $("doc-info").textContent = "❌ " + data.error;
    updateChatEnabled(false);
    return;
  }
  showDocInfo(data.document);
  updateChatEnabled(true);
});

// --- Chat flow (streamed) -------------------------------------------------
function addMsg(role, text) {
  const el = document.createElement("div");
  el.className = "msg " + role;
  el.textContent = text;
  $("chat").appendChild(el);
  $("chat").scrollTop = $("chat").scrollHeight;
  return el;
}

$("chat-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("chat-input");
  const message = input.value.trim();
  if (!message) return;
  input.value = "";
  addMsg("user", message);
  const botEl = addMsg("assistant", "…");
  $("send-btn").disabled = true;
  input.disabled = true;

  try {
    const res = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message }),
    });
    if (!res.ok) {
      botEl.textContent = "❌ " + (await res.json()).error;
      return;
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let full = "";
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      full += decoder.decode(value, { stream: true });
      botEl.textContent = full;
      $("chat").scrollTop = $("chat").scrollHeight;
    }
    if (!full.trim()) botEl.textContent = "(no response)";
  } catch (err) {
    botEl.textContent = "❌ " + err.message;
  } finally {
    $("send-btn").disabled = false;
    input.disabled = false;
    input.focus();
  }
});

// --- Boot -----------------------------------------------------------------
(async function init() {
  const state = await loadState();
  if (state.offline) showOfflineBadge();
  if (state.ready) {
    enterApp(state);
  } else {
    $("setup").classList.remove("hidden");
    renderModels(state);
  }
})();

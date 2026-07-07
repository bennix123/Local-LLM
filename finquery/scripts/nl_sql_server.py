"""
nl_sql_server.py -- Universal Bank Statement AI: FastAPI Server

Endpoints:
  POST /upload  -- Upload a bank statement PDF; ingests transactions AND extracts account_profile.
  POST /ask     -- Ask a natural language question; returns SQL + result + plain-English answer.
  GET  /profile -- Return the stored account_profile for the current user.
  GET  /status  -- Quick health check (row count, spend, income).

Runs on port 5668 so it does not conflict with the existing Penny server on 5667.
"""
import os
import sys
import time
import json

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, HTMLResponse
import uvicorn

from src.services import txn_store as ts
from src.services import nl_sql_engine as nle

# ---- DB path shared with the existing Penny DB --------------------------------
_PINNED_DB = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "data", "live_txn.db")
)
_env_db = os.environ.get("FINQ_DB")
DB_PATH = _env_db if (_env_db and os.path.exists(_env_db)) else _PINNED_DB

ts.DB_PATH = DB_PATH
nle.DB_PATH = DB_PATH
USER = "local"

print(f"[nl-sql] DB -> {DB_PATH}", flush=True)
ts.init_db()
nle.init_account_profile_table(DB_PATH)
print("[nl-sql] Tables ready.", flush=True)

app = FastAPI(title="Universal Bank Statement AI -- Text-to-SQL")

UPLOAD_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "uploads")
os.makedirs(UPLOAD_DIR, exist_ok=True)


# ============================================================ /upload
@app.post("/upload")
async def upload(request: Request):
    """
    Accept a bank statement PDF.
    1. Validates it as a bank statement.
    2. Ingests transactions into the transactions table.
    3. Extracts and saves account metadata into account_profile.
    """
    name = request.query_params.get("name", "upload.pdf")
    data = await request.body()
    t0 = time.time()

    out = os.path.join(UPLOAD_DIR, os.path.basename(name) or "statement.pdf")
    with open(out, "wb") as f:
        f.write(data)

    if not ts.is_statement_pdf(out):
        return JSONResponse(
            {"error": "That PDF doesn't look like a bank statement."},
            status_code=422
        )

    # Replace existing transactions for this user
    con = ts.connect()
    con.execute("DELETE FROM transactions WHERE user_id=?", (USER,))
    con.execute("DELETE FROM account_profile WHERE user_id=?", (USER,))
    con.commit()
    con.close()

    # Ingest transactions
    rows = ts.ingest_pdf(out, os.path.basename(name), USER)

    # Extract and save account profile
    profile_data = nle.extract_account_profile(out, USER)
    nle.save_account_profile(USER, profile_data, DB_PATH)

    # Update display currency
    ts.set_currency(ts.detect_currency(USER))

    ov = ts.overview(USER)
    dt = time.time() - t0

    return JSONResponse({
        "filename": os.path.basename(name),
        "rows": rows,
        "seconds": round(dt, 2),
        "currency": ts.CURRENCY,
        "spend": ts.inr(ov["debit"]),
        "income": ts.inr(ov["credit"]),
        "profile": dict(profile_data),
    })


# ============================================================ /ask
@app.post("/ask")
async def ask(request: Request):
    """
    Natural language question -> SQL -> Execute -> Explain.

    Request body: { "question": "How much did I spend on Amazon in January 2026?" }

    Response: {
        "intent":  "...",
        "sql":     "SELECT ...",
        "params":  [...],
        "result":  [...],
        "answer":  "You spent Rs. 2,450.00 on Amazon in 2026-01."
    }
    """
    body = await request.json()
    question = (body.get("question") or "").strip()
    if not question:
        return JSONResponse({"error": "Please provide a 'question' field."}, status_code=400)

    result = nle.nl_to_sql(question, USER, DB_PATH)
    return JSONResponse(result)


# ============================================================ /profile
@app.get("/profile")
async def profile():
    """Return the stored account_profile for the current user."""
    nle.init_account_profile_table(DB_PATH)
    con = nle.connect(DB_PATH)
    row = con.execute("SELECT * FROM account_profile WHERE user_id=?", (USER,)).fetchone()
    con.close()
    if not row:
        return JSONResponse({"error": "No profile found. Please upload a bank statement."}, status_code=404)
    return JSONResponse(dict(row))


# ============================================================ /status
@app.get("/status")
async def status():
    ov = ts.overview(USER)
    return JSONResponse({
        "rows": ov["count"],
        "spend": ts.inr(ov["debit"]),
        "income": ts.inr(ov["credit"]),
        "db": DB_PATH,
    })


# ============================================================ /
@app.get("/", response_class=HTMLResponse)
async def index():
    return """
<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<title>Universal Bank Statement AI</title>
<style>
  body{font-family:system-ui,sans-serif;max-width:800px;margin:40px auto;padding:0 20px;background:#0f172a;color:#e2e8f0}
  h1{color:#38bdf8}
  input,button{padding:10px;border-radius:6px;border:none;font-size:1rem}
  input{width:100%;background:#1e293b;color:#e2e8f0;border:1px solid #334155;box-sizing:border-box}
  button{background:#0ea5e9;color:#fff;cursor:pointer;margin-top:8px;padding:10px 24px}
  button:hover{background:#0284c7}
  pre{background:#1e293b;padding:16px;border-radius:8px;overflow-x:auto;white-space:pre-wrap;color:#94a3b8}
  .label{color:#94a3b8;font-size:.85rem;margin-top:16px}
  .answer{color:#4ade80;font-size:1.1rem;margin:12px 0;font-weight:600}
  .upload-area{border:2px dashed #334155;border-radius:8px;padding:24px;text-align:center;margin-bottom:24px}
</style>
</head>
<body>
<h1>Universal Bank Statement AI</h1>
<p>Text-to-SQL engine for bank statement analysis.</p>

<div class=\"upload-area\">
  <p>Upload a bank statement PDF:</p>
  <input type=\"file\" id=\"pdfFile\" accept=\".pdf\">
  <button onclick=\"uploadPdf()\">Upload Statement</button>
  <div id=\"uploadResult\"></div>
</div>

<div>
  <input id=\"q\" type=\"text\" placeholder=\"Ask a question... e.g. How much did I spend on Amazon in January 2026?\" />
  <button onclick=\"ask()\">Ask</button>
</div>

<div id=\"out\"></div>

<script>
async function uploadPdf() {
  const file = document.getElementById('pdfFile').files[0];
  if (!file) return alert('Please select a PDF file.');
  const res = await fetch('/upload?name=' + encodeURIComponent(file.name), {
    method: 'POST', body: file
  });
  const data = await res.json();
  document.getElementById('uploadResult').innerHTML =
    res.ok
      ? '<p style=\"color:#4ade80\">Uploaded: ' + data.filename + ' | Rows: ' + data.rows + '</p>'
      : '<p style=\"color:#f87171\">Error: ' + (data.error || JSON.stringify(data)) + '</p>';
}

async function ask() {
  const q = document.getElementById('q').value.trim();
  if (!q) return;
  const out = document.getElementById('out');
  out.innerHTML = '<p style=\"color:#94a3b8\">Running...</p>';
  const res = await fetch('/ask', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify({question: q})
  });
  const data = await res.json();
  out.innerHTML = 
    <div class=\"label\">Intent: </div>
    <div class=\"answer\"></div>
    <div class=\"label\">SQL:</div>
    <pre></pre>
    <div class=\"label\">Raw Result:</div>
    <pre></pre>
  ;
}

document.getElementById('q').addEventListener('keydown', e => { if (e.key === 'Enter') ask(); });
</script>
</body>
</html>
"""


if __name__ == "__main__":
    uvicorn.run("nl_sql_server:app", host="0.0.0.0", port=5668, reload=False)

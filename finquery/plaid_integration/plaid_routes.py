"""FastAPI router for the Plaid Sandbox flow, mounted into Penny's server.

Endpoints (all under /plaid/sandbox):
  GET  /status  -> link state + environment
  POST /link    -> create + persist a sandbox Item (optional {"institution_id": ...})
  POST /sync    -> full pull, REPLACE the ledger, then run the EXACT post-ingest
                   refresh /upload runs (set_currency, compute_insights, save_insights,
                   invalidate the row-count-keyed ML cache).
"""
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from . import plaid_ingest as ingest
from . import plaid_service as svc

router = APIRouter(prefix="/plaid/sandbox", tags=["plaid-sandbox"])

# The host app (test_server) sets this to invalidate caches keyed on row count
# (its _ML_CACHE). The row-count key already self-invalidates on a changed count;
# this makes the replace explicit. Default no-op keeps the package standalone.
on_data_replaced = None

ts = ingest.ts
USER = ingest.USER


def _err(exc):
    status = getattr(exc, "status", 500)
    return JSONResponse({"error": str(exc)}, status_code=status)


@router.get("/status")
def plaid_status():
    return {"linked": svc.is_linked(), "env": svc.ENV, "country": svc.COUNTRY}


@router.post("/link")
async def plaid_link(request: Request):
    body = {}
    try:
        body = await request.json()
    except Exception:
        pass
    try:
        return svc.link(body.get("institution_id"))
    except Exception as e:
        return _err(e)


@router.post("/sync")
def plaid_sync():
    try:
        transactions, accounts = svc.pull_all()
    except Exception as e:
        return _err(e)

    n = ingest.ingest(transactions, accounts)

    # ---- match /upload's post-ingest semantics EXACTLY ------------------------
    ts.set_currency(ts.detect_currency(USER))       # display currency follows the data
    try:
        ts.save_insights(USER, ts.compute_insights(USER))
    except Exception as e:                           # never fail the sync on insights
        print("[plaid] insights compute failed:", e, flush=True)
    if callable(on_data_replaced):                  # invalidate row-count-keyed ML cache
        try:
            on_data_replaced()
        except Exception as e:
            print("[plaid] cache invalidation hook failed:", e, flush=True)

    ov = ts.overview(USER)
    bal = ts.latest_balance(USER)
    return {
        "synced": n, "rows": ov["count"], "currency": ts.CURRENCY,
        "spend": ts.inr(ov["debit"]), "income": ts.inr(ov["credit"]),
        "balance": ts.inr(bal) if bal is not None else None,
    }

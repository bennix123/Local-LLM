"""Plaid Sandbox client — link a test bank and pull its transactions.

Refactored from the BankPeek single-file reference
(https://github.com/allAboutManas/Plaid-Sandbox-Integration) into Penny's package.
The Plaid SDK calls (model imports, request shapes, the /transactions/sync cursor
loop with the PRODUCT_NOT_READY retry) are kept verbatim from that reference — only
the persistence + app wiring is Penny-specific.

STRICTLY SANDBOX: the client host is hardcoded to ``plaid.Environment.Sandbox`` and
a PLAID_ENV=="sandbox" guard is enforced at client-build time; any other value makes
every Plaid call refuse (rather than sys.exit, which would take Penny down with it).
"""
import json
import os
import time

import plaid
from plaid.api import plaid_api
from plaid.model.country_code import CountryCode
from plaid.model.institutions_get_request import InstitutionsGetRequest
from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
from plaid.model.products import Products
from plaid.model.sandbox_public_token_create_request import SandboxPublicTokenCreateRequest
from plaid.model.transactions_sync_request import TransactionsSyncRequest

from dotenv import load_dotenv

load_dotenv()  # read repo-root .env (PLAID_CLIENT_ID / PLAID_SECRET / PLAID_ENV / PLAID_COUNTRY)

CLIENT_ID = os.getenv("PLAID_CLIENT_ID")
SECRET = os.getenv("PLAID_SECRET")
ENV = os.getenv("PLAID_ENV", "sandbox").lower()
COUNTRY = os.getenv("PLAID_COUNTRY", "GB").upper()

# Keep the access token beside Penny's data dir (gitignored), NOT in the repo tree.
_DATA_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "data"))
TOKEN_FILE = os.path.join(_DATA_DIR, "plaid_token.json")


class PlaidStateError(Exception):
    """A caller/link-state problem (not linked yet, already linked, upstream Plaid
    error) carrying the HTTP status the route should return."""
    def __init__(self, message, status=409):
        super().__init__(message)
        self.status = status


_client = None


def client():
    """Lazily build the sandbox-only Plaid client. Raises (never exits) if the
    environment isn't sandbox or credentials are missing, so Penny keeps running."""
    global _client
    if ENV != "sandbox":
        raise PlaidStateError(
            "PLAID_ENV must be 'sandbox' — refusing to contact any non-sandbox Plaid "
            "environment.", 400)
    if not CLIENT_ID or not SECRET:
        raise PlaidStateError(
            "PLAID_CLIENT_ID and PLAID_SECRET must be set in .env.", 400)
    if _client is None:
        cfg = plaid.Configuration(
            host=plaid.Environment.Sandbox,  # hardcoded: sandbox only, no production risk
            api_key={"clientId": CLIENT_ID, "secret": SECRET},
        )
        _client = plaid_api.PlaidApi(plaid.ApiClient(cfg))
    return _client


# --------------------------------------------------------------- token persistence
def _read_token():
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_token(access_token, item_id):
    os.makedirs(_DATA_DIR, exist_ok=True)
    with open(TOKEN_FILE, "w", encoding="utf-8") as f:
        json.dump({"access_token": access_token, "item_id": item_id}, f)


def _access_token():
    return _read_token().get("access_token")


def is_linked():
    return bool(_access_token())


# --------------------------------------------------------------- institutions
def _txn_institutions():
    """All sandbox institutions for COUNTRY that support the transactions product."""
    c = client()
    insts, offset = [], 0
    while True:
        req = InstitutionsGetRequest(50, offset, country_codes=[CountryCode(COUNTRY)])
        resp = c.institutions_get(req)
        for i in resp["institutions"]:
            products = [str(p) for p in (i.get("products") or [])]
            if "transactions" in products:
                insts.append(i)
        if len(resp["institutions"]) < 50:
            break
        offset += 50
    return insts


def _first_institution():
    insts = _txn_institutions()
    if insts:
        return insts[0]["institution_id"], insts[0].get("name", "")
    raise PlaidStateError(
        f"No sandbox institution for country '{COUNTRY}' supports transactions.", 502)


# --------------------------------------------------------------- link + sync
def link(institution_id=None):
    """Create a sandbox Item (server-side, no Link widget) and exchange the public
    token for a persisted access token. Returns identifying metadata (no secrets)."""
    if is_linked():
        raise PlaidStateError(
            "Already linked. Delete data/plaid_token.json to re-link.", 409)
    c = client()
    inst_name = ""
    if not institution_id:
        institution_id, inst_name = _first_institution()
    try:
        pt = c.sandbox_public_token_create(SandboxPublicTokenCreateRequest(
            institution_id=institution_id,
            initial_products=[Products("transactions")],
        ))
        ex = c.item_public_token_exchange(ItemPublicTokenExchangeRequest(
            public_token=pt["public_token"]))
    except plaid.ApiException as e:
        body = json.loads(e.body) if e.body else {}
        raise PlaidStateError(f"Plaid error: {body.get('error_message', str(e))}", 502)
    _save_token(ex["access_token"], ex["item_id"])
    return {"item_id": ex["item_id"], "institution_id": institution_id,
            "institution_name": inst_name}


def pull_all():
    """Full pull of every transaction for the linked Item (cursor starts fresh each
    call, so a sync REPLACES the ledger just like a fresh /upload — no incremental
    delta is persisted). Returns (transactions, accounts). Retries PRODUCT_NOT_READY
    while the sandbox generates data. Raw Plaid JSON never leaves this layer."""
    access_token = _access_token()
    if not access_token:
        raise PlaidStateError("Link a sandbox bank first (POST /plaid/sandbox/link).", 409)
    c = client()
    # Sandbox generates transactions asynchronously after link, and the first sync on a
    # brand-new Item can return an empty-but-complete page (no PRODUCT_NOT_READY, has_more
    # false) before data lands. Since we have no webhook, poll: drain all pages from a
    # fresh cursor; if nothing came back, wait and re-pull until data appears or we time out.
    deadline = time.time() + 150
    while True:
        added, accounts, cursor, has_more = [], None, None, True
        while has_more:
            req = TransactionsSyncRequest(access_token=access_token)
            if cursor:
                req.cursor = cursor
            try:
                resp = c.transactions_sync(req)
            except plaid.ApiException as e:
                body = json.loads(e.body) if e.body else {}
                code = body.get("error_code", "")
                if code == "PRODUCT_NOT_READY":
                    break  # not ready yet -> fall through to the wait-and-retry below
                if code in ("INVALID_CURSOR", "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION"):
                    added, accounts, cursor, has_more = [], None, None, True
                    continue
                raise PlaidStateError(f"Plaid error: {body.get('error_message', str(e))}", 502)
            added.extend(resp["added"])
            accounts = resp.get("accounts") or accounts
            cursor = resp["next_cursor"]
            has_more = resp["has_more"]
        if added or time.time() >= deadline:
            return added, accounts
        time.sleep(3)  # fresh Item still populating — re-pull from a clean cursor

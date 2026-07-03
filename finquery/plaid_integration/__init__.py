"""Plaid Sandbox integration for Penny.

Links a test bank via Plaid's Sandbox environment and syncs its synthetic
transactions into the same SQLite ledger (data/live_txn.db) that the PDF pipeline
writes to, so every existing SQL/chat feature works on Plaid data unchanged.

Refactored from the BankPeek single-file reference
(https://github.com/allAboutManas/Plaid-Sandbox-Integration) — Sandbox-only,
single user "local", a sync replaces prior data like /upload.

Wire into a FastAPI app with:
    from plaid_integration.plaid_routes import router
    app.include_router(router)
"""

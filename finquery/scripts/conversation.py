"""Canonical conversation layer for Penny.

This module defines the two typed structures the conversation pipeline is built on:

  • CanonicalQuery — the SINGLE resolved query object. Every routing engine
    (SQL dispatch, analytics, concept, advice, intelligence, ML) receives this
    object and reads its already-resolved fields (period / merchant / category /
    filters / amount / comparison / metric / doc_name). No engine re-parses the
    raw text after this object is built — that eliminates the whole class of
    context-loss bugs where each engine independently re-inferred scope.

  • DialogueState — the full dialogue memory (a superset of the legacy
    ConversationState). It serialises to/from the per-thread ``ctx`` dict using
    the SAME legacy keys (type/start/end/category/merchant/n) so existing code
    and saved chats keep working, and adds the fields the architecture review
    found missing (filters, grouping, amount threshold, comparison, active
    transaction, structured last-result, previous spec, confidence).

DETERMINISM: this module never invents a number. It only tracks WHAT the
conversation is about and produces a resolved query object; every figure is
still computed by txn_store SQL downstream. CanonicalQuery.to_intent() emits the
EXACT dict txn_store.dispatch_intent already consumes, so the deterministic
factual path is behaviourally identical (guarded by a differential test).
"""
from dataclasses import dataclass, field, asdict


# --------------------------------------------------------------------------- #
#  CanonicalQuery                                                             #
# --------------------------------------------------------------------------- #
@dataclass
class CanonicalQuery:
    """One fully-resolved query. Built ONCE by the pipeline; consumed read-only
    by every engine. `period()` serialises to txn_store's `_scope` period form
    (None | 'YYYY[-MM[-DD]]' prefix | (start,end) tuple | 'MD-MM-DD'); the factual
    intent dict is carried verbatim so `to_intent()` is byte-identical to today's
    `_resolve_factual` output."""
    raw: str = ""                    # the original user question
    resolved_text: str = ""          # the rewritten standalone query (for the LLM fallback + logs)
    intent_family: str = ""          # factual|analytics|concept|advice|intelligence|ml|followup|smalltalk|help|clarify|reset|unsupported
    intent: str = ""                 # factual type OR analytics metric (spend/count/merchant/category/compare/...)

    # ---- resolved scope (the context the old engines re-inferred) ----
    merchant: str = ""
    category: str = ""
    concept: str = ""                # gambling|loans|bank_fees|flights|coffee|taxis (semantic label)
    start: str = ""                  # canonical period start (YYYY | YYYY-MM | YYYY-MM-DD | MD-MM-DD)
    end: str = ""                    # canonical period end
    period_list: list = field(default_factory=list)   # >=2 resolved periods for compare / balance_delta

    # ---- metric / shape ----
    metric: str = ""                 # spend|count|income|average|extreme|trend|breakdown|top|balance|summary|compare
    group_by: str = ""               # ""|month|category|merchant|weekday|day
    txn_type: str = ""               # debit|credit  (direction filter)
    count_kind: str = ""             # debit|credit|upi  (count qualifier)
    table: bool = False              # user explicitly asked for a table
    n: int = 0                       # top-N / list size
    sort: str = ""
    date_dir: str = ""               # last|first (merchant_date direction)

    # ---- composable filters ----
    weekend: object = None           # True (weekends) | False (weekdays) | None
    exclude: list = field(default_factory=list)       # resolved categories/merchants to NOT-IN
    amount_op: str = ""              # over|under
    amount: object = None            # threshold (float) | None
    comparison: list = field(default_factory=list)    # resolved pair [A, B] (entities or periods)

    # ---- account / special payloads ----
    doc_name: str = ""               # multi-statement scope (was always dropped)
    amount_payload: object = None    # who_paid amount
    date1: str = ""
    date2: str = ""

    # ---- clarification ----
    options: list = field(default_factory=list)       # candidate merchants when ambiguous
    phrase: str = ""

    # ---- meta ----
    signals: list = field(default_factory=list)       # what the resolver injected (for logging)
    confidence: float = 1.0
    _factual_intent: dict = field(default_factory=dict)   # verbatim _resolve_factual output (source of truth for to_intent)

    # -- period serialisation for txn_store._scope ------------------------------
    def period(self):
        """The period value txn_store expects: None | prefix str | (start,end) tuple."""
        s, e = (self.start or ""), (self.end or "")
        if s and e:
            def pad(x, hi):
                return x if len(x) == 10 else (x + hi[7:] if len(x) == 7 else x + hi[4:])
            return (pad(s, "-01-01"), pad(e, "-12-31"))
        if s:
            return s
        return None

    # -- the deterministic factual contract (identical to _resolve_factual) -----
    def to_intent(self):
        """The dict txn_store.dispatch_intent consumes. Carries the proven factual
        intent verbatim so the deterministic path is unchanged."""
        if self._factual_intent:
            return dict(self._factual_intent)
        # built directly (not via _resolve_factual) — assemble the standard shape
        return {"type": self.intent, "category": self.category, "merchant": self.merchant,
                "n": self.n, "start": self.start, "end": self.end, "table": self.table,
                "count_kind": self.count_kind, "date_dir": self.date_dir,
                "amount": self.amount_payload, "date1": self.date1, "date2": self.date2,
                "options": self.options, "phrase": self.phrase}

    def scoped(self):
        """(merchant_or_None, category_or_None) — convenience for engines."""
        return (self.merchant or None, self.category or None)

    def has_own_scope(self):
        return bool(self.merchant or self.category or self.start or self.concept
                    or self.comparison or self.amount is not None or self.weekend is not None
                    or self.exclude)


# --------------------------------------------------------------------------- #
#  DialogueState                                                              #
# --------------------------------------------------------------------------- #
# Legacy keys kept for backward compat with _resolve_factual/_save_ctx/chats.json:
#   type/start/end/category/merchant/n
# New keys are additive; older ctx dicts (without them) still load via from_ctx.
@dataclass
class DialogueState:
    topic: str = ""                  # legacy `type`
    merchant: str = ""
    category: str = ""
    concept: str = ""
    txn_type: str = ""
    payment_mode: str = ""
    account: str = ""                # doc_name scope
    start: str = ""
    end: str = ""
    metric: str = ""
    group_by: str = ""
    filters: dict = field(default_factory=dict)       # {"weekend":True/False, "exclude":[...]}
    amount_op: str = ""
    amount: object = None
    comparison: list = field(default_factory=list)
    sort: str = ""
    limit: int = 0                   # legacy `n`
    presentation: str = ""           # table|line|bar|pie

    # structured memory (were missing → follow-ups couldn't bind)
    active_transaction: dict = field(default_factory=dict)   # {date,merchant,category,amount,direction}
    last_result: dict = field(default_factory=dict)          # {value,rows[],ordering,rowcount,entity_list,intent,period,route}
    prev_spec: dict = field(default_factory=dict)            # the CanonicalQuery of the prior turn (as dict)
    prev_route: str = ""
    prev_query: str = ""
    prev_entities: list = field(default_factory=list)
    prev_answer: str = ""
    confidence: float = 1.0

    @classmethod
    def from_ctx(cls, ctx):
        c = ctx or {}
        return cls(
            topic=c.get("type", "") or "", merchant=c.get("merchant", "") or "",
            category=c.get("category", "") or "", concept=c.get("concept", "") or "",
            txn_type=c.get("txn_type", "") or "", payment_mode=c.get("payment_mode", "") or "",
            account=c.get("account", "") or "", start=c.get("start", "") or "",
            end=c.get("end", "") or "", metric=c.get("metric", "") or "",
            group_by=c.get("group_by", "") or "", filters=dict(c.get("filters") or {}),
            amount_op=c.get("amount_op", "") or "", amount=c.get("amount"),
            comparison=list(c.get("comparison") or []), sort=c.get("sort", "") or "",
            limit=int(c.get("n") or c.get("limit") or 0), presentation=c.get("presentation", "") or "",
            active_transaction=dict(c.get("active_transaction") or {}),
            last_result=dict(c.get("last_result") or {}), prev_spec=dict(c.get("prev_spec") or {}),
            prev_route=c.get("prev_route", "") or "", prev_query=c.get("prev_query", "") or "",
            prev_entities=list(c.get("prev_entities") or []), prev_answer=c.get("prev_answer", "") or "",
            confidence=float(c.get("confidence") or 1.0))

    def to_ctx(self, ctx):
        """Mutate `ctx` in place, keeping the legacy keys plus the new ones."""
        ctx["type"] = self.topic; ctx["merchant"] = self.merchant
        ctx["category"] = self.category; ctx["concept"] = self.concept
        ctx["start"] = self.start; ctx["end"] = self.end; ctx["n"] = self.limit
        ctx["txn_type"] = self.txn_type; ctx["payment_mode"] = self.payment_mode
        ctx["account"] = self.account; ctx["metric"] = self.metric; ctx["group_by"] = self.group_by
        ctx["filters"] = self.filters; ctx["amount_op"] = self.amount_op; ctx["amount"] = self.amount
        ctx["comparison"] = self.comparison; ctx["sort"] = self.sort; ctx["limit"] = self.limit
        ctx["presentation"] = self.presentation
        ctx["active_transaction"] = self.active_transaction; ctx["last_result"] = self.last_result
        ctx["prev_spec"] = self.prev_spec; ctx["prev_route"] = self.prev_route
        ctx["prev_query"] = self.prev_query; ctx["prev_entities"] = self.prev_entities
        ctx["prev_answer"] = self.prev_answer; ctx["confidence"] = self.confidence
        return ctx

    @property
    def entity(self):
        return self.merchant or self.category


# Legacy alias — existing call sites use ConversationState.from_ctx / .to_ctx.
# DialogueState is a strict superset with identical legacy serialisation, so the
# old name keeps working during migration.
ConversationState = DialogueState

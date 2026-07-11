# Modularized txn_store package re-exports
import sys
from types import ModuleType
from . import db
from . import formatters
from . import dispatcher

from .db import connect, init_db
from .formatters import (
    set_currency, inr, grp, _money, _mlabel, _plabel, 
    _norm_period, _mname, _dlabel, _table, _pct, MONTHS
)
from .parsers import (
    ingest_pdf, ingest_csv, ingest_xlsx, ingest_file,
    is_statement_pdf, detect_currency, parse_pdf,
    parse_barclays, parse_pnb, parse_wrenfield, parse_generic_statement,
    BankProfileRegistry, classify_page, find_table_start_page,
    MERCHANT_MAP
)
from .queries import (
    reconciliation_rate,
    coverage, overview, latest_balance, by_category, merchant_spend, by_month,
    income_by_source, top_merchants, txn_count, amount_filter, filtered_summary,
    top_expenses, extreme, merchant_category, merchant_dates, list_transactions,
    balance_extreme, payment_interval, who_paid, balance_after, balance_before,
    balance_delta, months_list, subscription_costs, subscription_trends, category_movers,
    DISCRETIONARY, SUBSCRIPTION_MERCHANTS, advice_facts
)
from .insights import (
    build_insights, save_insights, get_insights, compute_insights, 
    health_score, risk_assessment, behavior_metrics, transaction_impact, 
    category_trend
)
from .dispatcher import dispatch_intent, answer, USER

# Subclass module to support dynamic getters/setters for DB_PATH, CURRENCY, and USER
class TxnStoreModule(ModuleType):
    @property
    def DB_PATH(self):
        return db.DB_PATH

    @DB_PATH.setter
    def DB_PATH(self, value):
        db.DB_PATH = value

    @property
    def CURRENCY(self):
        return formatters.CURRENCY

    @CURRENCY.setter
    def CURRENCY(self, value):
        formatters.CURRENCY = value

    @property
    def USER(self):
        return dispatcher.USER

    @USER.setter
    def USER(self, value):
        dispatcher.USER = value

sys.modules[__name__].__class__ = TxnStoreModule


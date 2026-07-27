// PennyModel — the canonical financial model (architecture layer L1).
//
// This is the single source of truth every higher layer reads from: pure,
// immutable value types with `Decimal` money and minimal dependencies. Nothing
// here parses, computes analytics, or performs I/O — those live in PennyCore (L0)
// and PennyFinance (L2–L4).
//
// The module's public types are defined in their own files: Money, Currency,
// CalendarDate, the typed IDs, Account, Statement, Transaction, Enrichment,
// Merchant, Category, FXInfo, and FinancialGraph. (The Task 0.1 placeholder
// `enum PennyModel` was removed once those real types landed — it shadowed the
// module name.)

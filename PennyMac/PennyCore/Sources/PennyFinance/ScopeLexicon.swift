import Foundation

/// Curated language knowledge for scope matching — merchant aliases and category
/// synonyms. This is **not** data (that's `QueryVocabulary`); it is a fixed lexicon
/// the matcher consults, kept separate so it can grow without touching the resolver.
/// No fuzzy/edit-distance matching (Wave B2 constraint) — only exact aliases and
/// word-stem synonyms.
public enum ScopeLexicon {

    /// alias → a needle that must appear in a present merchant's canonical name.
    /// (e.g. "amex" resolves to whatever present merchant contains "american express").
    public static let merchantAliases: [(alias: String, needle: String)] = [
        ("amex", "american express"),
        ("mcds", "mcdonald"), ("maccies", "mcdonald"), ("maccas", "mcdonald"),
        ("kfc", "kentucky"),
        ("sainos", "sainsbury"), ("sainsburys", "sainsbury"),
        ("waitrose", "waitrose"),
        ("gcp", "google"), ("aws", "amazon web"),
    ]

    /// word-stem → canonical category name. A stem matches a whole word that *starts*
    /// with it ("grocer" → "grocery"/"groceries", never "rent" inside "current"), and
    /// only resolves when that canonical category is present in the data. Ported from
    /// FinanceRouter.categorySynonyms.
    public static let categorySynonyms: [(stem: String, category: String)] = [
        ("grocer", "Groceries"), ("food", "Food & Dining"), ("dining", "Food & Dining"),
        ("restaurant", "Food & Dining"), ("transport", "Transport"), ("travel", "Transport"),
        ("fuel", "Transport"), ("shopping", "Shopping"), ("shop", "Shopping"),
        ("bill", "Bills & Utilities"), ("utilit", "Bills & Utilities"),
        ("cash", "Cash & ATM"), ("atm", "Cash & ATM"), ("transfer", "Transfers"),
        ("entertain", "Entertainment"), ("health", "Health"), ("rent", "Rent"),
        ("fee", "Fees & Charges"), ("charge", "Fees & Charges"),
        ("education", "Education"), ("school", "Education"), ("tuition", "Education"),
        ("subscription", "Subscriptions"), ("recurring", "Subscriptions"),
    ]
}

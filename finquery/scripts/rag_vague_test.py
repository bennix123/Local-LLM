"""
Stress-test the RAG router on 100+ VAGUE / messy questions against the live
/query endpoint. Vague questions rarely have one "right" route, so each case
carries a SET of acceptable routes. Three gates:

  G1 route-family : actual route must be in the acceptable set.
  G2 no-dump      : a chit-chat/gibberish question must NOT dump the insights
                    snapshot (the recurring "greetings dump insights" bug).
  G3 numeric      : for a pinned subset, the number must match the SQL layer.

Routes seen on the wire (meta.path): SQL | chat | advice.
('chat' covers smalltalk, help, followup and the "didn't catch that" nudge.)

Writes data/rag_vague_sheet.csv for manual review.
"""
import sys, os, json, time, re, urllib.request

sys.stdout.reconfigure(encoding="utf-8")
BASE = "http://127.0.0.1:8000"
_TAG = os.environ.get("SHEET_TAG", "")
SHEET = os.path.join(os.path.dirname(__file__), "..", "data",
                     f"rag_vague_sheet{('_' + _TAG) if _TAG else ''}.csv")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend", "src"))
from services import txn_store as ts
ts.DB_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "live_txn.db")
USER = "local"

SQL, CHAT, ADV = "SQL", "chat", "advice"
# Signatures unique to the advice/insights dump (NOT to a followup that merely
# mentions a prior table). The snapshot header + savings/run-rate only come from
# build_insights()/advice_context().
DUMP_MARKERS = ("spending snapshot", "savings rate", "run-rate projection", "annual run-rate")


def ask(q, timeout=320):
    data = json.dumps({"question": q}).encode()
    req = urllib.request.Request(BASE + "/query", data=data,
                                 headers={"Content-Type": "application/json"})
    path, parts = "?", []
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for line in resp:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            if d.get("type") == "meta":
                path = d.get("path", "?")
            elif d.get("type") == "chunk":
                parts.append(d.get("content", ""))
    return path, "".join(parts).strip(), round(time.time() - t0, 1)


# (question, {acceptable routes}, optional ("field", period) for numeric check)
CASES = [
    # --- heavy typos / abbreviations (should still resolve to SQL) ---
    ("hw mch i spnt in 2024",        {SQL},          ("debit", "2024")),
    ("ttl spend 2025",               {SQL},          ("debit", "2025")),
    ("no of txns 2024",              {SQL},          ("count", "2024")),
    ("wat z my balnce",              {SQL},          ("balance", None)),
    ("spnding by catgory",           {SQL},          None),
    ("biggst expnse",                {SQL},          None),
    ("incom in 2024",                {SQL},          ("credit", "2024")),
    ("hw mny transctns in march 2025", {SQL},        ("count", "2025-03")),
    ("amt spnt on netflix",          {SQL},          None),
    ("top 3 xpenses",                {SQL},          None),
    ("blnce plz",                    {SQL},          ("balance", None)),
    ("grocery spnd 2024",            {SQL},          None),

    # --- Hinglish / mixed language ---
    ("kitna kharcha hua 2024 me",    {SQL},          ("debit", "2024")),
    ("mera balance kitna hai",       {SQL},          ("balance", None)),
    ("kitne transaction hue april 2024 me", {SQL},   ("count", "2024-04")),
    ("sabse bada kharcha kya tha",   {SQL},          None),
    ("netflix pe kitna gaya",        {SQL},          None),
    ("kitni income hui 2024",        {SQL},          ("credit", "2024")),
    ("paisa kaha ja raha hai",       {SQL, ADV},     None),
    ("kaise bachau paisa",           {ADV},          None),
    ("march 2025 ka hisaab",         {SQL},          None),
    ("kitna bacha mere paas",        {SQL},          ("balance", None)),

    # --- colloquial / slang ---
    ("how much dough did I blow in 2024", {SQL},     ("debit", "2024")),
    ("how much cash did I burn in 2025",  {SQL},     ("debit", "2025")),
    ("what's left in the bank",      {SQL},          ("balance", None)),
    ("how much did I rake in during 2024", {SQL},    ("credit", "2024")),
    ("where's all my money going",   {SQL, ADV},     None),
    ("am I bleeding money",          {SQL, ADV},     None),
    ("how fat is my wallet",         {SQL},          ("balance", None)),
    ("did I splurge on shopping",    {SQL, ADV},     None),
    ("money in money out for 2024",  {SQL},          None),

    # --- emotional / rhetorical ---
    ("am I broke",                   {SQL, ADV},     None),
    ("why am I always broke",        {ADV, SQL},     None),
    ("am I spending too much",       {ADV},          None),
    ("am I doing ok financially",    {ADV},          None),
    ("should I be worried about my spending", {ADV}, None),
    ("is my spending out of control", {ADV, SQL},    None),
    ("help me i spend too much",     {ADV},          None),
    ("i really need to save money",  {ADV},          None),
    ("roast my spending",            {ADV},          None),
    ("how bad is it",                {ADV, CHAT},    None),

    # --- vague time / scope ---
    ("spending recently",            {SQL, ADV},     None),
    ("what did I spend last month",  {SQL},          None),
    ("give me the last 3 months",    {SQL},          None),
    ("how much lately",              {SQL, ADV},     None),
    ("the year before that",         {SQL, CHAT},    None),

    # --- super short / one-word ---
    ("spending?",                    {SQL, ADV},     None),
    ("balance",                      {SQL},          ("balance", None)),
    ("income",                       {SQL},          None),
    ("expenses",                     {SQL, ADV},     None),
    ("summary",                      {SQL},          None),
    ("categories",                   {SQL},          None),
    ("total",                        {SQL, ADV},     None),
    ("netflix",                      {SQL, ADV},     None),
    ("groceries",                    {SQL},          None),
    ("money",                        {ADV, SQL, CHAT}, None),

    # --- where-does-my-money-go / category vague ---
    ("where does my money go",       {SQL, ADV},     None),
    ("what do I spend most on",      {SQL, ADV},     None),
    ("biggest spending area",        {SQL, ADV},     None),
    ("what's eating my budget",      {SQL, ADV},     None),
    ("what am I wasting money on",   {SQL, ADV},     None),

    # --- merchant / recurring vague ---
    ("how much on food delivery",    {SQL, ADV},     None),
    ("what am I paying every month", {SQL, ADV},     None),
    ("are my subscriptions worth it", {ADV, SQL},    None),
    ("recurring stuff",              {SQL, ADV},     None),

    # --- greetings / smalltalk (must be chat, must NOT dump) ---
    ("yo",                           {CHAT},         None),
    ("sup",                          {CHAT},         None),
    ("heyyy",                        {CHAT},         None),
    ("good evening",                 {CHAT},         None),
    ("hello there",                  {CHAT},         None),
    ("namaste",                      {CHAT},         None),
    ("kya haal hai",                 {CHAT},         None),
    ("how's it going",              {CHAT},         None),
    ("you there?",                   {CHAT},         None),
    ("wassup penny",                 {CHAT},         None),
    ("thanks",                       {CHAT},         None),
    ("ok cool",                      {CHAT},         None),

    # --- help-ish vague (chat) ---
    ("what is this",                 {CHAT},         None),
    ("what do you do",               {CHAT},         None),
    ("how does this work",           {CHAT},         None),
    ("what can I ask",               {CHAT},         None),
    ("give me some examples",        {CHAT, ADV},    None),
    ("options?",                     {CHAT},         None),

    # --- gibberish / noise (chat nudge, must NOT dump) ---
    ("asdfgh",                       {CHAT},         None),
    ("qwerty",                       {CHAT},         None),
    ("blah blah blah",               {CHAT},         None),
    ("...",                          {CHAT},         None),
    ("???",                          {CHAT},         None),
    ("lkjlkj",                       {CHAT},         None),
    ("test test",                    {CHAT, ADV},    None),

    # --- comparison / trend (advice or SQL breakdown) ---
    ("am I spending more than before", {ADV, SQL},   None),
    ("is my spending going up",      {ADV, SQL},     None),
    ("show me the trend of my spending", {SQL, ADV}, None),
    ("how am I trending",            {ADV, SQL},     None),
    ("month over month",             {SQL},          None),

    # === CONTEXT BLOCK 1: count then ellipticals (followup memory) ===
    ("how many transactions in 2025?", {SQL},        ("count", "2025")),   # ctx
    ("and in 2024?",                 {SQL},          ("count", "2024")),   # reuse count
    ("what about april 2024",        {SQL},          ("count", "2024-04")),# reuse count
    ("is that a lot",                {CHAT, ADV},    None),                # about prior

    # === CONTEXT BLOCK 2: spend then ellipticals ===
    ("how much did I spend in 2024?", {SQL},         ("debit", "2024")),   # ctx
    ("what about 2025",              {SQL},          ("debit", "2025")),   # reuse spend
    ("and groceries?",              {SQL},          None),                # reuse->category
    ("why so high",                  {CHAT, ADV},    None),                # about prior

    # === CONTEXT BLOCK 3: balance then followup ===
    ("what's my balance",            {SQL},          ("balance", None)),   # ctx
    ("what does that number mean",   {CHAT},         None),                # followup
    ("is that good or bad",          {CHAT, ADV},    None),                # followup

    # --- more vague one-liners to push past 100 ---
    ("did I overspend",              {ADV, SQL},     None),
    ("give me the lowdown",          {ADV, SQL},     None),
    ("break it down for me",         {SQL, ADV},     None),
    ("whats the damage",             {SQL, ADV},     None),
    ("hit me with the numbers",      {SQL, ADV},     None),
    ("how much have I blown total",  {SQL, ADV},     None),
    ("am I rich yet",                {SQL, ADV, CHAT}, None),
    ("paise ka kya scene hai",       {SQL, ADV},     None),
    ("kya main zyada kharch kar raha hu", {ADV, SQL}, None),
    ("show me everything",           {SQL, ADV},     None),
    ("gimme a quick overview",       {SQL},          None),
    ("whats up with my finances",    {ADV, SQL},     None),
]


def first_money(s):
    m = re.search(r"[₹]\s*([\d,]+(?:\.\d+)?)", s)
    return float(m.group(1).replace(",", "")) if m else None


def first_int(s):
    # first integer-ish token, ignoring year-looking 4-digit numbers handled by caller
    m = re.search(r"([\d][\d,]*)", s)
    return int(m.group(1).replace(",", "")) if m else None


def last_int(s):
    """The count answer is '**Transactions in <label>:** <count>' — the count is
    the last number after the final colon. Robust to range labels that contain
    day numbers (e.g. '01 Jan 2024 – 31 Dec 2024')."""
    tail = s.split(":")[-1]
    nums = re.findall(r"[\d][\d,]*", tail)
    return int(nums[-1].replace(",", "")) if nums else None


def truth(field, period):
    if field == "balance":
        return ts.latest_balance(USER)
    o = ts.overview(USER, None, period)
    return o[field]


def main():
    print(f"Stress-testing {len(CASES)} vague questions against {BASE}/query\n")
    rows, g1, g2, g3, g3n = [], 0, 0, 0, 0
    hard_fails, dump_fails, num_fails = [], [], []

    for i, (q, acc, verify) in enumerate(CASES, 1):
        try:
            path, ans, dt = ask(q)
        except Exception as e:
            path, ans, dt = "ERROR", f"{type(e).__name__}: {e}", 0.0
        flat = " ".join(ans.split())

        # G1: route family
        ok1 = path in acc
        g1 += ok1
        if not ok1:
            hard_fails.append((i, q, path, "/".join(sorted(acc))))

        # G2: chit-chat / gibberish must not dump insights
        dumped = any(m in flat.lower() for m in DUMP_MARKERS)
        chatish = acc == {CHAT}
        ok2 = not (chatish and dumped)
        g2 += ok2 if chatish else 0
        if chatish and not ok2:
            dump_fails.append((i, q, flat[:60]))

        # G3: numeric correctness on pinned subset (only when it actually went SQL)
        nres = ""
        if verify and path == SQL:
            g3n += 1
            field, period = verify
            want = truth(field, period)
            if field == "count":
                got = last_int(flat)               # count is the last number after the colon
                ok3 = got == int(want)
                nres = f"want {want} got {got}"
            else:
                got = first_money(flat)
                ok3 = got is not None and abs(got - want) < 0.5
                nres = f"want {round(want,2)} got {got}"
            g3 += ok3
            if not ok3:
                num_fails.append((i, q, nres))

        mark = "ok " if ok1 else "BAD"
        dflag = "  <DUMP!>" if (chatish and dumped) else ""
        print(f"{i:>3} [{mark}] {path:<6} acc={'/'.join(sorted(acc)):<14} {dt:>4}s {q[:42]}{dflag}")
        rows.append((q, "/".join(sorted(acc)), path, "PASS" if ok1 else "FAIL",
                     "DUMP" if (chatish and dumped) else "", nres, dt, flat))

    n = len(CASES)
    chat_n = sum(1 for _, acc, _ in CASES if acc == {CHAT})
    print("\n================= RESULTS =================")
    print(f"G1 route-family : {g1}/{n} acceptable")
    print(f"G2 no-dump      : {g2}/{chat_n} chit-chat answers stayed clean")
    print(f"G3 numeric      : {g3}/{g3n} pinned numbers exact")

    if hard_fails:
        print(f"\nROUTE MISSES ({len(hard_fails)}):")
        for i, q, got, acc in hard_fails:
            print(f"  {i:>3} got={got:<6} acc={acc:<12} {q}")
    if dump_fails:
        print(f"\nINSIGHT-DUMP ON CHIT-CHAT ({len(dump_fails)}):")
        for i, q, s in dump_fails:
            print(f"  {i:>3} {q!r} -> {s}")
    if num_fails:
        print(f"\nNUMERIC MISMATCHES ({len(num_fails)}):")
        for i, q, r in num_fails:
            print(f"  {i:>3} {q!r}: {r}")

    # route distribution
    from collections import Counter
    dist = Counter(r[2] for r in rows)
    print(f"\nRoute distribution: {dict(dist)}")

    import csv
    os.makedirs(os.path.dirname(SHEET), exist_ok=True)
    with open(SHEET, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["#", "question", "acceptable", "route", "route_result",
                    "dump_flag", "numeric", "seconds", "answer"])
        for i, r in enumerate(rows, 1):
            w.writerow([i, *r])
    print(f"\nSheet: {os.path.abspath(SHEET)}")


if __name__ == "__main__":
    main()

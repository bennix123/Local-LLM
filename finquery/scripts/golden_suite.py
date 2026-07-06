"""
Golden Test Suite — 10 production categories for a Bank-Statement RAG.

Curated, representative questions per category, run live against /query, scored.
Verdict kinds:
  amount/percent/count  -> deterministic: the figure must match SQL truth
  advice                -> must route='advice', be fully grounded (no number outside
                           the SQL facts), and mention the expected topic
  probe                 -> capability check: must give an on-topic answer (route
                           advice/SQL + a keyword); else flagged as a GAP

Output: data/golden_suite_results.csv + a per-category, per-priority scorecard.
Run from finquery/.
"""
import os, sys, json, re, csv, time, urllib.request, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, "backend")
from src.services import txn_store as ts
ts.DB_PATH = os.path.join("data", "live_txn.db")
BASE = f"http://127.0.0.1:{os.environ.get('PORT','5667')}"; USER = "local"
FACTS = ts.advice_facts(USER)

# ---------- number helpers ----------
_MULT = {"crore":1e7,"crores":1e7,"cr":1e7,"lakh":1e5,"lakhs":1e5,"lac":1e5,"lacs":1e5,"thousand":1e3,"k":1e3,"million":1e6,"mn":1e6}
_AMT = re.compile(r"₹\s*([\d,]+(?:\.\d+)?)|\b(\d[\d,]*(?:\.\d+)?)\s*(crores?|cr|lakhs?|lacs?|lac|thousand|million|mn|k)\b", re.I)
_PCT = re.compile(r"(\d+(?:\.\d+)?)\s*%")
_INT = re.compile(r"(?<![\d.])([\d,]{1,})(?![\d.])")
def amts(s):
    o=[]
    for m in _AMT.finditer(s):
        if m.group(1) is not None: o.append(float(m.group(1).replace(",","")))
        else: o.append(float(m.group(2).replace(",",""))*_MULT.get(m.group(3).lower(),1))
    return o
def pcts(s): return [float(x) for x in _PCT.findall(s)]
def ints(s): return [int(x.replace(",","")) for x in _INT.findall(s)]
FA=amts(FACTS); FP=pcts(FACTS)
def ungrounded(a):
    return [round(v) for v in amts(a) if not any(abs(v-f)<=max(1.0,0.005*max(v,f)) for f in FA)] + \
           [f"{v}%" for v in pcts(a) if not any(abs(v-f)<=0.5 for f in FP)]

# ---------- SQL truths ----------
o=ts.overview(USER); TOT_SPEND,TOT_INC,NET,COUNT=o["debit"],o["credit"],o["net"],o["count"]
RATE=NET/TOT_INC*100
cats=dict((c,a) for c,a,_ in ts.by_category(USER))
GROC,SHOP=cats["Groceries"],cats["Shopping"]
ZER=ts.merchant_spend(USER,"Zerodha")["debit"]; AMZ=ts.merchant_spend(USER,"Amazon")["debit"]
LARGEST=ts.extreme(USER,"largest_expense")[2]; SMALLEST=ts.extreme(USER,"smallest_expense")[2]
LARGEST_DEP=ts.extreme(USER,"largest_income")[2]
SPEND24=ts.overview(USER,None,"2024")["debit"]; INC24=ts.overview(USER,None,"2024")["credit"]
MAR24=ts.overview(USER,None,"2024-03")["debit"]
nmon=max(len(ts.months_list(USER)),1); bal=ts.latest_balance(USER); RUNWAY=bal/(TOT_SPEND/nmon)

# ---------- the suite: (category, question, kind, expected) ----------
SUITE=[
 # 1 Transaction Retrieval (Must)
 ("Transaction Retrieval","What was my largest expense?","amount",LARGEST),
 ("Transaction Retrieval","What was my biggest deposit?","amount",LARGEST_DEP),
 ("Transaction Retrieval","How much did I spend at Amazon?","amount",AMZ),
 ("Transaction Retrieval","What did I spend in March 2024?","amount",MAR24),
 ("Transaction Retrieval","What was my smallest expense?","amount",SMALLEST),
 # 2 Aggregation & Summaries (Must)
 ("Aggregation & Summaries","What is my total spending?","amount",TOT_SPEND),
 ("Aggregation & Summaries","How much did I spend on Groceries?","amount",GROC),
 ("Aggregation & Summaries","What did I earn in 2024?","amount",INC24),
 ("Aggregation & Summaries","How much have I spent at Zerodha in total?","amount",ZER),
 ("Aggregation & Summaries","How many transactions are there?","count",COUNT),
 # 3 Comparison Analysis (Must)
 ("Comparison Analysis","Did I spend more on Shopping or Groceries?","amount",SHOP),
 ("Comparison Analysis","Compare my 2024 vs 2025 spending","amount",SPEND24),
 ("Comparison Analysis","Did I spend more at Zerodha or Amazon?","amount",ZER),
 ("Comparison Analysis","Compare cash withdrawals vs digital payments","advice",["digital","upi","71"]),
 # 4 Pattern Detection (Must)
 ("Pattern Detection","What are my recurring payments?","probe",["netflix","spotify","subscription","recurring","jio","airtel","lic"]),
 ("Pattern Detection","Which subscriptions increased in cost?","probe",["netflix","spotify","subscription","increase","%","stable"]),
 ("Pattern Detection","What are my hidden spending patterns?","probe",["zerodha","%","risk","income","stands out"]),
 ("Pattern Detection","Which merchants do I spend the most with?","probe",["zerodha","axis","lic","flipkart","amazon"]),
 # 5 Trend Analysis (Must)
 ("Trend Analysis","Is my spending going up or down?","probe",["%","half","trend","month","spend"]),
 ("Trend Analysis","Compare my last 6 months with the previous 6 months","probe",["%","recent","previous","spend","month"]),
 ("Trend Analysis","Is my income growing?","probe",["%","income","half","trend","flat","grow"]),
 ("Trend Analysis","Which month did I spend the most?","probe",["mar 2024","2024","highest","month"]),
 # 6 Financial Health (Important)
 ("Financial Health Analysis","What is my savings rate?","percent",RATE),
 ("Financial Health Analysis","How long could I survive without income?","amount",None),  # runway months, checked specially
 ("Financial Health Analysis","How am I doing financially?","probe",["health","income","%","24","savings"]),
 ("Financial Health Analysis","Rate my financial health","probe",["health","income","%","24","savings"]),
 # 7 Risk Detection (Important)
 ("Risk Detection","Which months were financially risky?","probe",["risky","month","net","income exceeded","no risky","tightest"]),
 ("Risk Detection","How dependent am I on a single income source?","advice",["86.8","salary","%","concentrat","reliant"]),
 ("Risk Detection","Which transactions suggest future financial risk?","probe",["concentrat","salary","risk","%","income"]),
 ("Risk Detection","Am I too concentrated in a few merchants?","advice",["77","concentrat","zerodha","merchant","%"]),
 # 8 Anomaly Detection (Important)
 ("Anomaly Detection","Are there any unusual transactions?","probe",["unusual","anomal","large","79,9","zerodha","largest","biggest"]),
 ("Anomaly Detection","Flag any transactions far larger than normal","probe",["79,9","zerodha","largest","unusual","biggest","top"]),
 ("Anomaly Detection","Any suspicious or out-of-pattern spending?","probe",["unusual","anomal","zerodha","79,9","largest","pattern"]),
 # 9 Recommendations (Advanced)
 ("Recommendations","How can I save more?","advice",["shopping","discretionary","%","cut","flexible"]),
 ("Recommendations","Where should I cut back?","advice",["shopping","entertainment","discretionary","cut","flexible"]),
 ("Recommendations","How much can I safely invest each month?","advice",["52,00,217","surplus","invest","43,09"]),
 ("Recommendations","What should I monitor every month?","advice",["savings rate","runway","43,09","monitor","subscription"]),
 # 10 Forecasting & What-If (Advanced)
 ("Forecasting & What-If","What is my projected annual spending at this rate?","probe",["per year","run-rate","19,6","annual","project","a year"]),
 ("Forecasting & What-If","How much will I likely spend next month?","probe",["next month","forecast","predict","average","1,63","per month"]),
 ("Forecasting & What-If","If I cut Shopping by 20%, how much would I save?","probe",["shopping","20","4,47","save","89","reduc"]),
 ("Forecasting & What-If","At this pace, how much will I save this year?","probe",["per year","run-rate","save","annual","surplus","52,00"]),
]

PRIORITY={ "Transaction Retrieval":"Must","Aggregation & Summaries":"Must","Comparison Analysis":"Must",
 "Pattern Detection":"Must","Trend Analysis":"Must","Financial Health Analysis":"Important",
 "Risk Detection":"Important","Anomaly Detection":"Important","Recommendations":"Advanced",
 "Forecasting & What-If":"Advanced"}

def ask(q):
    body=json.dumps({"question":q,"thread":f"gold_{abs(hash(q))%99999}","reset":True}).encode()
    req=urllib.request.Request(BASE+"/query",data=body,headers={"Content-Type":"application/json"})
    path,parts="?",[]
    with urllib.request.urlopen(req,timeout=120) as r:
        for line in r:
            line=line.strip()
            if not line: continue
            d=json.loads(line)
            if d.get("type")=="meta": path=d.get("path","?")
            elif d.get("type")=="chunk": parts.append(d.get("content",""))
    return path," ".join("".join(parts).split())

def verdict(cat,q,kind,exp,route,ans):
    low=ans.lower()
    if kind=="amount":
        if "survive" in q.lower():  # runway: months figure
            ms=re.findall(r"([\d.]+)\s*months?",low)
            return (any(abs(float(m)-RUNWAY)<=0.2 for m in ms),"")
        return (any(abs(exp-a)<=max(0.6,0.005*exp) for a in amts(ans)),"")
    if kind=="percent":
        return (any(abs(exp-p)<=0.6 for p in pcts(ans)),"")
    if kind=="count":
        return (exp in ints(ans),"")
    if kind=="advice":
        ug=ungrounded(ans)
        if route!="advice": return (False,f"route={route} (not advice)")
        if ug: return (False,f"ungrounded {ug[:4]}")
        if not any(k.lower() in low for k in exp): return (False,"off-topic")
        return (True,"")
    if kind=="probe":
        if route not in ("advice","SQL","chat","ML"): return (False,f"route={route}")
        hit=any(k.lower() in low for k in exp)
        return (hit, "" if hit else f"GAP route={route}")
    return (False,"?")

rows=[]; t0=time.time()
for cat,q,kind,exp in SUITE:
    try: route,ans=ask(q)
    except Exception as e: route,ans=("ERR",str(e))
    ok,note=verdict(cat,q,kind,exp,route,ans)
    rows.append({"category":cat,"priority":PRIORITY[cat],"kind":kind,"pass":ok,"route":route,
                 "note":note,"question":q,"answer":ans[:280]})

out=os.path.join("data","golden_suite_results.csv")
with open(out,"w",newline="",encoding="utf-8-sig") as f:
    w=csv.DictWriter(f,fieldnames=["category","priority","kind","pass","route","note","question","answer"]); w.writeheader(); w.writerows(rows)

# ---------- scorecard ----------
print(f"\n{'='*68}\nGOLDEN SUITE: {sum(r['pass'] for r in rows)}/{len(rows)} passed  in {time.time()-t0:.0f}s   sheet:{out}\n")
bycat=collections.OrderedDict()
for cat,_q,_k,_e in SUITE: bycat.setdefault(cat,[0,0])
for r in rows:
    bycat[r["category"]][0]+=1; bycat[r["category"]][1]+=r["pass"]
print(f"{'Category':28s} {'Priority':9s}  Score")
print("-"*52)
for cat,(n,p) in bycat.items():
    mark="✓" if p==n else ("~" if p>=n*0.5 else "✗")
    print(f"{cat:28s} {PRIORITY[cat]:9s}  {p}/{n} {mark}")
print("-"*52)
for tier in ("Must","Important","Advanced"):
    tr=[r for r in rows if r["priority"]==tier]
    print(f"{tier+' have':28s} {'':9s}  {sum(r['pass'] for r in tr)}/{len(tr)}")
fails=[r for r in rows if not r["pass"]]
print(f"\nFailures / gaps: {len(fails)}")
for r in fails:
    a=r["answer"]
    for x,y in [("₹","Rs "),("—","-")]: a=a.replace(x,y)
    print(f"  [{r['category']}] {r['question']}\n     route={r['route']} {r['note']} :: {a[:150]}")

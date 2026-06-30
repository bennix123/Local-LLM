"""
1000 VAGUE questions to stress the parrot fix + advisory routing.

Design: 250 conversation THREADS x 4 questions = 1000. Each thread is
  [advisory, random/off-topic, gibberish, vague-followup]
sent IN THE SAME THREAD (reset only on the first), because parroting only shows
up when there is prior history to echo. The advisory Q1 produces a substantive
answer; Q2-Q4 must NOT come back as that same answer.

Checks:
  * routing — advisory should -> 'advice'; random/gibberish/vague -> 'chat' nudge.
    A random/gibberish/vague question that comes back as route='advice' is a
    misroute (the parrot source).
  * PARROT — within a thread, a non-advisory question whose answer is byte-identical
    to an EARLIER different question's SUBSTANTIVE answer (route advice/SQL). Nudge/
    greeting repeats are expected and NOT counted.
  * grounding — every Rs amount / % in an advisory answer must exist in the SQL facts.
  * distinctness — advisory answers should vary by question (not one canned reply).

Output: data/qa_vague_1000_results.csv + printed summary.  Run from finquery/.
"""
import os, sys, json, re, csv, time, random, string, urllib.request
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, "backend")
from src.services import txn_store as ts
ts.DB_PATH = os.path.join("data", "live_txn.db")

BASE = "http://127.0.0.1:8000"
FACTS = ts.advice_facts("local")
random.seed(42)

# ---------- grounding helpers (mirror the server's validator) ----------
_MULT = {"crore":1e7,"crores":1e7,"cr":1e7,"lakh":1e5,"lakhs":1e5,"lac":1e5,"lacs":1e5,
         "thousand":1e3,"k":1e3,"million":1e6,"mn":1e6}
_AMT = re.compile(r"₹\s*([\d,]+(?:\.\d+)?)|\b(\d[\d,]*(?:\.\d+)?)\s*(crores?|cr|lakhs?|lacs?|lac|thousand|million|mn|k)\b", re.I)
_PCT = re.compile(r"(\d+(?:\.\d+)?)\s*%")
def amts(s):
    o=[]
    for m in _AMT.finditer(s):
        if m.group(1) is not None: o.append(float(m.group(1).replace(",","")))
        else: o.append(float(m.group(2).replace(",",""))*_MULT.get(m.group(3).lower(),1))
    return o
FA=amts(FACTS); FP=[float(x) for x in _PCT.findall(FACTS)]
def ungrounded(a):
    bad=[]
    for v in amts(a):
        if not any(abs(v-f)<=max(1.0,0.005*max(v,f)) for f in FA): bad.append(f"Rs{v:,.0f}")
    for v in (float(x) for x in _PCT.findall(a)):
        if not any(abs(v-f)<=0.5 for f in FP): bad.append(f"{v}%")
    return bad

# ---------- question pools ----------
ADV_CORE = [
 "how can i save more","how can i save more money","how do i save more each month",
 "where should i cut back","where can i cut spending","where should i cut to save",
 "how much can i safely invest","how much can i invest every month","how much should i save each month",
 "should i cut my shopping","should i reduce my entertainment","should i cut food spending",
 "am i overspending","am i spending too much","am i saving enough",
 "how am i doing financially","how am i doing with money","how am i doing with my finances",
 "is my income reliable","is my income stable","is my income dependable",
 "how dependent am i on my salary","how dependent am i on one income source","am i too reliant on one income",
 "what financial trends do you observe","what trends do you see","what patterns do you notice",
 "roast my spending","roast my finances","rate my financial health","rate my spending",
 "review my spending","review my budget","assess my finances",
 "what habits should i reconsider","what habits should i change",
 "can i afford a vacation","can i afford a big purchase","can i afford a new car",
 "which spending categories need strict limits","what spending needs limits","which expenses should i cap",
 "how can i improve my budget","how do i improve my finances","how can i budget better",
 "what is eating my savings","what is draining my money","what is preventing me from saving",
 "how healthy is my spending","how risky is my spending","am i financially stable",
 "give me financial advice","give me money tips","any saving tips","how reliant am i on salary",
]
ADV_SUF = ["", " please", " honestly", " these days", " overall", " right now", " for me", " be real"]
RND_CORE = [
 "recommend a good movie","recommend a restaurant","recommend a book","suggest a song to play",
 "what is the weather today","what is the weather tomorrow","will it rain today",
 "tell me a joke","tell me a story","write me a poem","sing me a song",
 "who won the world cup","who won the election","who is the president of usa",
 "how do i cook pasta","how do i make tea","give me a pizza recipe",
 "translate hello to french","what is 2 plus 2","what time is it","what day is it",
 "what is your name","who made you","what is your favorite color","do you like music",
 "should i call my friend","should i go to the gym","should i buy a dog","should i text my ex",
 "who is elon musk","what is the capital of france","how tall is mount everest",
 "play some music","open youtube","set an alarm","what is photosynthesis",
 "explain quantum physics","how far is the moon","latest news headlines","bitcoin price today",
]
RND_SUF = ["", " please", " now", " for me", " quickly", " ok", " thanks", " buddy"]
AMB_CORE = ["money?","help","hmm","ok","what now","tell me more","anything else","more",
 "go on","continue","next","why","what","huh","really","cool","so?","and?","tell me",
 "explain","details","wait","hold on","you sure","keep going","then?","right","go ahead","i see"]
AMB_SUF = ["", " please", " then", " now", " really", " ok", " come on", " hmm", " lol"]

def make(core, suf, n):
    out=[]
    for t in core:
        for s in suf:
            out.append((t+s))
    random.shuffle(out)
    return out[:n]

advisory  = [(q,"advisory")  for q in make(ADV_CORE, ADV_SUF, 250)]
randoms   = [(q,"random")    for q in make(RND_CORE, RND_SUF, 250)]
ambig     = [(q,"vague")     for q in make(AMB_CORE, AMB_SUF, 250)]
gib=[]
for i in range(250):
    if i % 5 != 0:   # 80% punctuation-only -> instant nudge (no model call), keeps the run fast
        gib.append((random.choice(["...","???","!!!","??!","--","***","###","....","?!?!",". . .","!?!?"]),"gibberish"))
    else:            # 20% lettered gibberish -> exercises the router -> unknown -> nudge
        gib.append(("".join(random.choice(string.ascii_lowercase) for _ in range(random.randint(4,9))),"gibberish"))

# 250 threads of 4: [advisory, random, gibberish, vague]
threads = list(zip(advisory, randoms, gib, ambig))
threads = threads[:int(os.getenv("VAGUE_THREADS", "250"))]   # smoke-test via VAGUE_THREADS

# ---------- run ----------
def ask(q, thread, reset):
    body=json.dumps({"question":q,"thread":thread,"reset":reset}).encode()
    req=urllib.request.Request(BASE+"/query",data=body,headers={"Content-Type":"application/json"})
    path,parts="?",[]
    with urllib.request.urlopen(req,timeout=90) as r:
        for line in r:
            line=line.strip()
            if not line: continue
            d=json.loads(line)
            if d.get("type")=="meta": path=d.get("path","?")
            elif d.get("type")=="chunk": parts.append(d.get("content",""))
    return path," ".join("".join(parts).split())

rows=[]; t0=time.time(); parrots=[]; misroutes=[]; ungr=[]
for ti,(qa) in enumerate(threads):
    tid=f"vague{ti}"
    seen={}   # answer_text -> (question, route) for SUBSTANTIVE answers in this thread
    for qi,(q,kind) in enumerate(qa):
        try:
            route,ans=ask(q,tid,reset=(qi==0))
        except Exception as e:
            route,ans=("ERR",f"<{type(e).__name__}>")
        substantive = route in ("advice","SQL")
        # parrot = this non-advisory Q reuses an earlier DIFFERENT Q's substantive answer
        parrot=False
        if substantive and ans in seen and seen[ans][0]!=q:
            parrot=True; parrots.append((tid,q,kind,route,seen[ans][0],ans[:120]))
        if substantive and ans not in seen:
            seen[ans]=(q,route)
        if kind!="advisory" and route=="advice":
            misroutes.append((tid,q,kind,ans[:100]))
        if kind=="advisory" and route=="advice":
            bad=ungrounded(ans)
            if bad: ungr.append((q,bad,ans[:120]))
        rows.append({"thread":tid,"idx":qi,"kind":kind,"route":route,"parrot":parrot,
                     "question":q,"answer":ans[:300]})
    if (ti+1)%50==0:
        print(f"  {ti+1}/250 threads ({len(rows)} q)  parrots={len(parrots)} misroutes={len(misroutes)}  [{time.time()-t0:.0f}s]")

# ---------- write csv ----------
out=os.path.join("data","qa_vague_1000_results.csv")
with open(out,"w",newline="",encoding="utf-8-sig") as f:
    w=csv.DictWriter(f,fieldnames=["thread","idx","kind","route","parrot","question","answer"])
    w.writeheader(); w.writerows(rows)

# ---------- summary ----------
import collections
print(f"\n{'='*64}\nVAGUE BATTERY: {len(rows)} questions in {time.time()-t0:.0f}s   sheet: {out}")
bykind=collections.defaultdict(lambda: collections.Counter())
for r in rows: bykind[r["kind"]][r["route"]]+=1
print("\nrouting by question kind (route counts):")
for k in ("advisory","random","gibberish","vague"):
    print(f"  {k:9s}: {dict(bykind[k])}")
adv=[r for r in rows if r["kind"]=="advisory"]
adv_ans=[r["answer"] for r in adv if r["route"]=="advice"]
print(f"\nadvisory -> route=advice: {sum(1 for r in adv if r['route']=='advice')}/{len(adv)}")
print(f"advisory answer distinctness: {len(set(adv_ans))}/{len(adv_ans)} unique")
print(f"advisory ungrounded (number not in facts): {len(ungr)}")
for q,bad,a in ungr[:8]: print(f"    ! {q} -> {bad}")
print(f"\n*** PARROT incidents (substantive answer reused for a different Q): {len(parrots)} ***")
for tid,q,kind,route,prevq,a in parrots[:12]:
    print(f"    [{tid}] {kind} '{q}' (route={route}) echoed '{prevq}'\n        -> {a}")
print(f"\nnon-advisory questions misrouted to advice: {len(misroutes)}")
for tid,q,kind,a in misroutes[:12]:
    print(f"    [{tid}] {kind} '{q}' -> {a}")
verdict = "PARROT-FREE ✓" if (not parrots and not misroutes) else "ISSUES FOUND ✗"
print(f"\nVERDICT: {verdict}  (parrots={len(parrots)}, advice-misroutes={len(misroutes)}, ungrounded={len(ungr)})")

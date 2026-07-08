# HTML templates and stylesheets for local server UI

LOGIN_PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Penny · Sign In</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Poppins:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
  :root{
    --cream:#fff8eb; --cream2:#fdf6e9; --ink:#1a1a1a; --ink2:#444;
    --lime:#84cc16; --lime2:#6aaa0e; --orange:#ff9f56; --line:#eaddc4;
    --red:#e53e3e; --green:#38a169;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%;font-family:'Poppins',system-ui,Arial}
  body{
    background:var(--cream);
    display:flex;flex-direction:column;align-items:center;justify-content:center;
    min-height:100vh;padding:24px;
  }
  .brand{text-align:center;margin-bottom:32px}
  .brand .logo{font-size:36px;font-weight:700;color:var(--ink);letter-spacing:-1px}
  .brand .logo span{color:var(--lime)}
  .brand .tagline{font-size:13px;color:var(--ink2);margin-top:4px}
  .pill{display:inline-block;background:var(--lime);color:#143;padding:2px 10px;
        border-radius:99px;font-size:11px;font-weight:600;margin-top:6px}
  .card{
    background:#fff;border:1px solid var(--line);border-radius:20px;
    padding:36px 40px;width:100%;max-width:400px;
    box-shadow:0 4px 24px rgba(0,0,0,.07);
  }
  .tabs{display:flex;gap:0;margin-bottom:28px;border:1px solid var(--line);
        border-radius:10px;overflow:hidden}
  .tab{flex:1;padding:10px;font-size:14px;font-weight:600;cursor:pointer;
       border:none;background:#fff;color:var(--ink2);transition:all .2s}
  .tab.active{background:var(--lime);color:#143}
  label{display:block;font-size:13px;font-weight:500;color:var(--ink2);margin-bottom:5px}
  input[type=text],input[type=password]{
    width:100%;padding:12px 14px;border:1.5px solid var(--line);
    border-radius:10px;font-size:15px;font-family:inherit;
    background:var(--cream);outline:none;transition:border .2s;
    margin-bottom:16px;
  }
  input:focus{border-color:var(--lime)}
  .btn{
    width:100%;padding:13px;background:var(--lime);border:none;border-radius:10px;
    font-size:15px;font-weight:700;color:#143;cursor:pointer;
    transition:background .2s,transform .1s;margin-top:4px;
  }
  .btn:hover{background:var(--lime2)}
  .btn:active{transform:scale(.98)}
  .btn:disabled{opacity:.55;cursor:default}
  .msg{margin-top:14px;font-size:13px;text-align:center;min-height:18px;font-weight:500}
  .msg.err{color:var(--red)} .msg.ok{color:var(--green)}
  .footer{margin-top:28px;font-size:12px;color:#b08a4a;text-align:center}
  @keyframes spin{to{transform:rotate(360deg)}}
  .spin{display:inline-block;width:16px;height:16px;border:2px solid #143;
        border-top-color:transparent;border-radius:50%;animation:spin .7s linear infinite;
        vertical-align:middle;margin-right:6px}
</style>
</head><body>
<div class="brand">
  <div class="logo">Penny<span>·</span></div>
  <div class="tagline">Your offline bank-statement intelligence</div>
  <span class="pill">SQL · offline · private</span>
</div>

<div class="card">
  <div class="tabs">
    <button class="tab active" id="loginTab" onclick="showTab('login')">Sign In</button>
    <button class="tab" id="signupTab" onclick="showTab('signup')">Create Account</button>
  </div>

  <!-- LOGIN FORM -->
  <div id="loginForm">
    <label for="lu">Username</label>
    <input type="text" id="lu" placeholder="your username" autocomplete="username">
    <label for="lp">Password</label>
    <input type="password" id="lp" placeholder="••••••••" autocomplete="current-password">
    <div style="display:flex;align-items:center;margin-bottom:16px;gap:8px;font-size:13px;color:var(--ink2);">
      <input type="checkbox" id="showPasswordLogin" onclick="togglePasswordVisibility('showPasswordLogin', ['lp'])" style="cursor:pointer;width:16px;height:16px;">
      <label for="showPasswordLogin" style="margin-bottom:0;cursor:pointer;user-select:none;">Show Password</label>
    </div>
    <button class="btn" id="loginBtn" onclick="doLogin()">Sign In</button>
    <div class="msg" id="loginMsg"></div>
  </div>

  <!-- SIGNUP FORM -->
  <div id="signupForm" style="display:none">
    <label for="su">Choose a username</label>
    <input type="text" id="su" placeholder="min. 3 characters" autocomplete="username">
    <label for="sp">Choose a password</label>
    <input type="password" id="sp" placeholder="min. 6 characters" autocomplete="new-password">
    <label for="sp2">Confirm password</label>
    <input type="password" id="sp2" placeholder="repeat password" autocomplete="new-password">
    <div style="display:flex;align-items:center;margin-bottom:16px;gap:8px;font-size:13px;color:var(--ink2);">
      <input type="checkbox" id="showPasswordSignup" onclick="togglePasswordVisibility('showPasswordSignup', ['sp', 'sp2'])" style="cursor:pointer;width:16px;height:16px;">
      <label for="showPasswordSignup" style="margin-bottom:0;cursor:pointer;user-select:none;">Show Password</label>
    </div>
    <button class="btn" id="signupBtn" onclick="doSignup()">Create Account</button>
    <div class="msg" id="signupMsg"></div>
  </div>
</div>

<div class="footer">Your data stays on your device. Nothing is sent to any server.</div>

<script>
function showTab(t){
  document.getElementById('loginForm').style.display = t==='login'?'':'none';
  document.getElementById('signupForm').style.display = t==='signup'?'':'none';
  document.getElementById('loginTab').className = 'tab'+(t==='login'?' active':'');
  document.getElementById('signupTab').className = 'tab'+(t==='signup'?' active':'');
}

function togglePasswordVisibility(checkboxId, inputIds){
  const show = document.getElementById(checkboxId).checked;
  inputIds.forEach(id => {
    document.getElementById(id).type = show ? 'text' : 'password';
  });
}

function setMsg(id, txt, ok){
  const el=document.getElementById(id);
  el.textContent=txt; el.className='msg '+(ok?'ok':'err');
}
function setLoading(btnId, loading){
  const b=document.getElementById(btnId);
  if(loading){ b.disabled=true; b.innerHTML='<span class="spin"></span>Please wait…'; }
  else { b.disabled=false; b.innerHTML = btnId==='loginBtn'?'Sign In':'Create Account'; }
}

async function doLogin(){
  const u=document.getElementById('lu').value.trim();
  const p=document.getElementById('lp').value;
  if(!u||!p){ setMsg('loginMsg','Please enter username and password.'); return; }
  setLoading('loginBtn',true);
  try{
    const r=await fetch('/auth/login',{method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify({username:u,password:p})});
    const j=await r.json();
    if(!r.ok){ setMsg('loginMsg', j.detail||'Login failed.'); return; }
    localStorage.setItem('penny_token', j.token);
    localStorage.setItem('penny_user', j.username);
    setMsg('loginMsg','Welcome back, '+j.username+'! Redirecting…', true);
    setTimeout(()=>location.href='/app', 700);
  }catch(e){ setMsg('loginMsg','Server error. Is Penny running?'); }
  finally{ setLoading('loginBtn',false); }
}

async function doSignup(){
  const u=document.getElementById('su').value.trim();
  const p=document.getElementById('sp').value;
  const p2=document.getElementById('sp2').value;
  if(!u||!p){ setMsg('signupMsg','Please fill in all fields.'); return; }
  if(p!==p2){ setMsg('signupMsg','Passwords do not match.'); return; }
  setLoading('signupBtn',true);
  try{
    const r=await fetch('/auth/signup',{method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify({username:u,password:p})});
    const j=await r.json();
    if(!r.ok){ setMsg('signupMsg', j.detail||'Signup failed.'); return; }
    localStorage.setItem('penny_token', j.token);
    localStorage.setItem('penny_user', j.username);
    setMsg('signupMsg','Account created! Welcome, '+j.username+'!', true);
    setTimeout(()=>location.href='/app', 700);
  }catch(e){ setMsg('signupMsg','Server error. Is Penny running?'); }
  finally{ setLoading('signupBtn',false); }
}

// If already logged in, redirect immediately
const tok=localStorage.getItem('penny_token');
if(tok){
  fetch('/auth/me',{headers:{Authorization:'Bearer '+tok}})
    .then(r=>{ if(r.ok) location.href='/app'; })
    .catch(()=>{});
}

// Enter key support
document.addEventListener('keydown', e=>{
  if(e.key==='Enter'){
    if(document.getElementById('loginForm').style.display!=='none') doLogin();
    else doSignup();
  }
});
</script>
</body></html>"""

PAGE = r"""<!doctype html><html><head><meta charset="utf-8">
<title>Penny  |  SQL layer test</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root{ --cream:#fff8eb; --cream2:#fdf6e9; --ink:#1a1a1a; --ink2:#2a2a2a;
         --lime:#84cc16; --orange:#ff9f56; --line:#eaddc4; }
  *{box-sizing:border-box} html,body{margin:0;height:100%}
  body{background:var(--cream);color:var(--ink);font:15px/1.5 'Poppins',system-ui,Arial}
  header{padding:16px 22px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:12px}
  header b{font-size:18px} .pill{background:var(--lime);color:#143;padding:2px 10px;border-radius:99px;font-size:12px;font-weight:600}
  .wrap{max-width:860px;margin:0 auto;padding:18px}
  .card{background:var(--cream2);border:1px solid var(--line);border-radius:14px;padding:16px;margin-bottom:16px}
  .drop{border:2px dashed var(--orange);border-radius:14px;padding:22px;text-align:center;cursor:pointer;background:#fffdf7}
  .drop:hover{background:#fff4dd} input[type=file]{display:none}
  .stat{display:inline-block;margin:6px 14px 0 0;font-size:13px;color:#6b5} .stat b{color:var(--ink)}
  #chat{min-height:120px}
  .msg{padding:12px 14px;border-radius:12px;margin:10px 0;max-width:90%}
  .me{background:var(--ink);color:#fff;margin-left:auto;border-bottom-right-radius:4px}
  .bot{background:#fff;border:1px solid var(--line);border-bottom-left-radius:4px}
  .bot .tag{font-size:11px;font-weight:700;letter-spacing:.04em;padding:1px 7px;border-radius:99px;margin-bottom:6px;display:inline-block}
  .tag.SQL{background:var(--lime);color:#143} .tag.RAG{background:#ffe9d0;color:#8a5a1f}
  .tag.chat{background:#eef;color:#446}
  .who{font-size:11px;color:#b08a4a;margin-left:6px}
  table{border-collapse:collapse;width:100%;margin:8px 0;font-size:13.5px}
  th,td{border:1px solid var(--line);padding:6px 9px;text-align:left} th{background:#f6fce0}
  td:nth-child(n+2){text-align:right;font-variant-numeric:tabular-nums}
  .row{display:flex;gap:10px;margin-top:8px}
  input[type=text]{flex:1;padding:12px 14px;border:1px solid var(--line);border-radius:10px;font-size:15px;background:#fff}
  button{background:var(--lime);border:0;color:#143;font-weight:700;padding:0 20px;border-radius:10px;cursor:pointer}
  button:disabled{opacity:.5;cursor:default}
  .chips{margin-top:6px} .chip{display:inline-block;background:#fff;border:1px solid var(--line);border-radius:99px;
         padding:5px 11px;margin:4px 6px 0 0;font-size:12.5px;cursor:pointer} .chip:hover{background:#f6fce0}
  .muted{color:#9a8} em{color:#8a5a1f}
  .hidden{display:none!important}
  .drop.busy{opacity:.75;pointer-events:none;border-style:solid;animation:dropglow 1.1s ease-in-out infinite}
  @keyframes dropglow{0%,100%{background:#fffdf7}50%{background:#fff1d6}}
  .thinking{display:flex;align-items:center;gap:8px}
  .typing{display:inline-flex;gap:5px;align-items:center}
  .typing i{width:7px;height:7px;border-radius:50%;background:var(--orange);display:inline-block;
            animation:penny-blink 1.2s infinite both}
  .typing i:nth-child(2){animation-delay:.18s} .typing i:nth-child(3){animation-delay:.36s}
  @keyframes penny-blink{0%,80%,100%{opacity:.25;transform:translateY(0)}
                         40%{opacity:1;transform:translateY(-4px)}}
  .user-pill{background:var(--cream2);border:1px solid var(--line);border-radius:99px;
             padding:4px 12px;font-size:12px;font-weight:600;color:var(--ink2)}
  .logout-btn{background:#fff;border:1px solid var(--line);border-radius:99px;
              padding:4px 12px;font-size:12px;font-weight:600;color:#c53030;
              cursor:pointer;margin-left:6px;transition:background .2s}
  .logout-btn:hover{background:#fff5f5}
</style></head><body>
<header><b>Penny</b><span class="pill">SQL layer  |  offline test  |  model: __MODEL__</span>
  <span class="muted" style="margin-left:auto;font-size:12px">numbers come from SQL, never the LLM</span>
  <span class="user-pill" id="userPill" style="display:none"></span>
  <button class="logout-btn" id="logoutBtn" style="display:none" onclick="doLogout()">Sign out</button>
</header>
<div class="wrap">
  <div class="card">
    <label class="drop" id="drop">
      <input type="file" id="file" accept=".pdf,.zip,application/pdf,application/zip,application/x-zip-compressed">
      <div><b>Click to upload a statement  -  PDF or ZIP</b></div>
      <div class="muted" id="dropsub">Upload a bank-statement PDF, or a ZIP containing one  -  the chat unlocks once it's parsed.</div>
    </label>
    <div id="stats"></div>
    <div class="row" style="margin-top:12px;align-items:center;gap:10px">
      <button id="plaidbtn" style="background:#fff;border:1px solid var(--line);color:var(--ink);padding:9px 14px;font-size:13px">Bank Sync from Plaid (Sandbox)</button>
      <span class="muted" id="plaidnote" style="font-size:12px;flex:1">Pull synthetic transactions from a Plaid Sandbox bank  -  replaces the loaded statement.</span>
    </div>
  </div>
  <div class="card hidden" id="chatcard">
    <div class="row" style="margin:0 0 8px 0;align-items:center">
      <b style="font-size:13px">Chat</b>
      <span class="muted" id="threadnote" style="font-size:11px;flex:1">context carries within this thread  |  tap New chat to reset</span>
      <button id="newchat" style="padding:7px 13px;font-size:12.5px;background:#fff;border:1px solid var(--line);color:var(--ink)">Reset New chat</button>
    </div>
    <div id="chat"><div class="muted">Upload a statement, then ask away.</div></div>
    <div class="row">
      <input type="text" id="q" placeholder="e.g. how much did I spend on swiggy?">
      <button id="send">Ask</button>
    </div>
    <div class="chips" id="chips"></div>
  </div>
  <div class="card hidden" id="txncard">
    <div class="row" style="margin:0 0 8px 0;align-items:center">
      <b style="font-size:13px">Transactions</b>
      <span class="muted" id="txnnote" style="font-size:11px;flex:1">search &amp; filter the parsed statement</span>
      <span class="muted" id="txnsummary" style="font-size:11.5px"></span>
    </div>
    <div class="row" style="flex-wrap:wrap;gap:8px;margin:0">
      <input type="text" id="tq" placeholder="search payee / description / category" style="flex:2;min-width:170px;padding:9px 12px">
      <select id="tdir" style="padding:9px;border:1px solid var(--line);border-radius:10px;background:#fff;font-size:13.5px">
        <option value="">All</option><option value="out">Money out</option><option value="in">Money in</option>
      </select>
      <input type="date" id="tstart" title="from date" style="padding:8px;border:1px solid var(--line);border-radius:10px;background:#fff;font-size:12.5px">
      <input type="date" id="tend" title="to date" style="padding:8px;border:1px solid var(--line);border-radius:10px;background:#fff;font-size:12.5px">
      <input type="number" id="tmin" placeholder="min" style="width:80px;flex:0;padding:9px;border:1px solid var(--line);border-radius:10px;background:#fff">
      <input type="number" id="tmax" placeholder="max" style="width:80px;flex:0;padding:9px;border:1px solid var(--line);border-radius:10px;background:#fff">
      <button id="tgo">Search</button>
    </div>
    <div id="txntable" style="max-height:430px;overflow:auto;margin-top:8px"></div>
    <div class="row" style="justify-content:center;gap:14px;margin-top:6px;align-items:center">
      <button id="tprev" style="padding:6px 12px;font-size:12.5px;background:#fff;border:1px solid var(--line);color:var(--ink)">< Prev</button>
      <span id="tpage" class="muted" style="font-size:12px"></span>
      <button id="tnext" style="padding:6px 12px;font-size:12.5px;background:#fff;border:1px solid var(--line);color:var(--ink)">Next ></button>
    </div>
  </div>
</div>
<script>
const $=s=>document.querySelector(s);
const SUG=["what is my total spending?","give me an account summary","show me spending by category",
  "how much did I spend on swiggy?","what is my biggest expense?",
  "how financially healthy am I?","what risks do you see?","what patterns do you see?",
  "what spending habits do I have?","what subscriptions do I have?",
  "which categories are growing fastest?","how can I save money?"];
$("#chips").innerHTML=SUG.map(s=>`<span class="chip">${s}</span>`).join("");
document.querySelectorAll(".chip").forEach(c=>c.onclick=()=>{$("#q").value=c.textContent;ask();});

// GATE: the chat + transactions stay hidden until a statement has been parsed.
const reveal=()=>{ $("#chatcard").classList.remove("hidden"); $("#txncard").classList.remove("hidden"); };
const gate=()=>{ $("#chatcard").classList.add("hidden"); $("#txncard").classList.add("hidden"); };
(async()=>{ try{
  const s=await (await fetch("/status")).json();
  if(s.rows>0){
    $("#stats").innerHTML=`<span class="stat"><b>${s.rows.toLocaleString()}</b> txns loaded</span>
      <span class="stat">spend <b>${s.spend}</b></span><span class="stat">income <b>${s.income}</b></span>`;
    $("#dropsub").textContent="A statement is loaded  -  ask away, or upload another (PDF/ZIP) to replace it.";
    $("#chat").innerHTML='<div class="muted">Ready. Ask a question or tap a suggestion.</div>';
    reveal(); loadTxns(true); $("#q").focus();
  } else { gate(); }
}catch(e){ gate(); } })();

function mdToHtml(md){
  const lines=md.split("\n"); let html="",tbl=[];
  const flush=()=>{ if(!tbl.length)return;
    const rows=tbl.filter(r=>!/^\s*\|?\s*-{2,}/.test(r));
    html+="<table>"+rows.map((r,i)=>{const cells=r.split("|").filter(c=>c.trim()!=="");
      const tag=i==0?"th":"td";return "<tr>"+cells.map(c=>`<${tag}>${c.trim()}</${tag}>`).join("")+"</tr>";}).join("")+"</table>";
    tbl=[]; };
  for(const ln of lines){ if(ln.trim().startsWith("|")){tbl.push(ln);continue;} flush();
    let t=ln.replace(/\*\*(.+?)\*\*/g,"<b>$1</b>").replace(/_(.+?)_/g,"<em>$1</em>");
    if(t.trim())html+=`<div>${t}</div>`; }
  flush(); return html;
}
function add(cls,html,tag){ const d=document.createElement("div"); d.className="msg "+cls;
  d.innerHTML=(tag?`<span class="tag ${tag}">${tag}</span>`:"")+html;
  $("#chat").appendChild(d); d.scrollIntoView({behavior:"smooth",block:"end"}); }

$("#file").onchange=async e=>{
  const f=e.target.files[0]; if(!f)return;
  gate();                                        // keep the chat hidden while parsing
  $("#drop").classList.add("busy");
  $("#dropsub").innerHTML="Loading... Parsing <b>"+f.name+"</b>  -  finding &amp; reading transactions...";
  $("#stats").innerHTML="";
  let j;
  try{
    const r=await fetch("/upload?name="+encodeURIComponent(f.name),{method:"POST",body:f});
    j=await r.json();
  }catch(err){ $("#drop").classList.remove("busy"); e.target.value="";
    $("#dropsub").textContent="Upload failed  -  please try again."; return; }
  $("#drop").classList.remove("busy"); e.target.value="";
  if(j.error){                                   // no statement found -> stay locked
    $("#dropsub").innerHTML="Warning:  "+j.error+' <span class="muted"> -  the chat stays locked until a statement is parsed.</span>';
    gate(); return;
  }
  const more=(j.parsed&&j.parsed.length>1)?("  |  "+j.parsed.length+" statements"):"";
  $("#dropsub").textContent=j.filename+" loaded";
  $("#stats").innerHTML=`<span class="stat"><b>${j.rows.toLocaleString()}</b> txns${more}</span>
    <span class="stat">parsed in <b>${j.seconds}s</b></span>
    <span class="stat">spend <b>${j.spend}</b></span>
    <span class="stat">income <b>${j.income}</b></span>`;
  $("#chat").innerHTML='<div class="muted">Ready. Ask a question or tap a suggestion.</div>';
  $("#q").disabled=false; $("#send").disabled=false;
  reveal(); loadTxns(true); $("#q").focus();      // unlock the chat now that it's parsed
};

// Plaid Sandbox: link a test bank + pull its transactions into the same ledger.
// A sync REPLACES the loaded statement (same as a fresh upload), then the gate reveals
// the chat + transactions cards. Every figure shown comes from /sync's SQL response.
$("#plaidbtn").onclick=async()=>{
  const btn=$("#plaidbtn"), note=$("#plaidnote");
  const setnote=t=>{ note.innerHTML=t; };
  btn.disabled=true; gate(); $("#drop").classList.add("busy"); $("#stats").innerHTML="";
  try{
    setnote("Loading... Linking a Plaid Sandbox bank...");
    let r=await fetch("/plaid/sandbox/link",{method:"POST",headers:{"Content-Type":"application/json"},body:"{}"});
    let j=await r.json().catch(()=>({}));
    if(!r.ok && r.status!==409) throw new Error(j.error||("link failed ("+r.status+")"));  // 409 = already linked, fine
    setnote("Syncing Syncing from Plaid... a fresh sandbox item can take up to ~2 minutes to generate data.");
    r=await fetch("/plaid/sandbox/sync",{method:"POST"});
    j=await r.json().catch(()=>({}));
    if(!r.ok) throw new Error(j.error||("sync failed ("+r.status+")"));
    if(!j.rows) throw new Error("Plaid returned no transactions yet  -  tap Sync again in a few seconds.");
    $("#drop").classList.remove("busy"); btn.disabled=false;
    $("#dropsub").textContent="Plaid Sandbox data loaded  -  ask away, or upload a statement to replace it.";
    setnote("Success:  Synced <b>"+j.synced.toLocaleString()+"</b> transactions from Plaid Sandbox.");
    $("#stats").innerHTML=`<span class="stat"><b>${j.rows.toLocaleString()}</b> txns (Plaid Sandbox)</span>
      <span class="stat">spend <b>${j.spend}</b></span>
      <span class="stat">income <b>${j.income}</b></span>`+
      (j.balance?`<span class="stat">balance <b>${j.balance}</b></span>`:"");
    $("#chat").innerHTML='<div class="muted">Ready. Ask a question or tap a suggestion.</div>';
    $("#q").disabled=false; $("#send").disabled=false;
    reveal(); loadTxns(true); $("#q").focus();
  }catch(err){
    $("#drop").classList.remove("busy"); btn.disabled=false;
    setnote("Warning:  "+err.message);
    try{ const s=await (await fetch("/status")).json(); if(s.rows>0) reveal(); }catch(_){}
  }
};
const TAG={SQL:"SQL",chat:"chat",advice:"RAG"};
function newBubble(path){
  const d=document.createElement("div"); d.className="msg bot";
  const tag=TAG[path]||"chat";
  d.innerHTML=`<span class="tag ${tag}">${tag}</span>`
    +(path==="advice"?`<span class="who">Penny  |  __MODEL__</span>`:"")
    +`<div class="md"></div>`;
  $("#chat").appendChild(d); d.scrollIntoView({behavior:"smooth",block:"end"});
  return d.querySelector(".md");
}

// loading indicator shown the instant you hit Enter, until the answer starts
function thinkingBubble(){
  const d=document.createElement("div"); d.className="msg bot thinking";
  d.innerHTML=`<span class="muted" style="font-size:12.5px">Penny is thinking</span>`
    +`<span class="typing"><i></i><i></i><i></i></span>`;
  $("#chat").appendChild(d); d.scrollIntoView({behavior:"smooth",block:"end"});
  return d;
}

function renderClarification(p){
  const d=document.createElement("div"); d.className="msg bot";
  let buttons = p.options.map(opt => `
    <button class="clarify-opt" onclick="sendClarification('${opt.id}', '${p.original_query.replace(/'/g, "\\'")}', this)" 
            style="text-align:left;background:#fff;border:1px solid var(--line);color:var(--ink);padding:10px;border-radius:8px;font-size:13.5px;cursor:pointer;display:block;width:100%;margin-top:6px;transition:background .2s;">
      <strong>${opt.label}</strong><br/>
      <span class="muted" style="font-size:11.5px;">${opt.sublabel}</span>
    </button>
  `).join('');
  d.innerHTML=`<span class="tag chat">clarify</span><p style="margin:6px 0;">${p.question}</p>`
    +`<div style="display:flex;flex-direction:column;gap:6px;margin-top:8px;">${buttons}</div>`;
  $("#chat").appendChild(d); d.scrollIntoView({behavior:"smooth",block:"end"});
}

async function sendClarification(selectedId, originalQuery, btn){
  btn.closest('div').querySelectorAll('button').forEach(b => b.disabled=true);
  const label = btn.querySelector('strong').textContent;
  add("me", label);
  const think=thinkingBubble();
  let cleared=false; const clearThink=()=>{ if(!cleared){cleared=true; think.remove();} };
  try{
    const r=await fetch("/query",{
      method:"POST",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify({
        clarification_response:true,
        selected_id:selectedId,
        question:originalQuery,
        thread:THREAD
      })
    });
    const reader=r.body.getReader(), dec=new TextDecoder();
    let buf="", md=null, full="";
    const queue=[]; let streamDone=false, revealing=false;
    const reveal=()=>{ revealing=true;
      if(queue.length){
        full+=queue.shift();
        md.innerHTML=mdToHtml(full);
        md.parentElement.scrollIntoView({behavior:"smooth",block:"end"});
        setTimeout(reveal,18);
      } else if(streamDone){ revealing=false; $("#send").disabled=false; }
      else setTimeout(reveal,18);
    };
    while(true){ const {done,value}=await reader.read(); if(done)break;
      buf+=dec.decode(value,{stream:true}); const lines=buf.split("\n"); buf=lines.pop();
      for(const ln of lines){ if(!ln.trim())continue; const m=JSON.parse(ln);
        if(m.type==="meta"){ clearThink(); md=newBubble(m.path); }
        else if(m.type==="chunk"){ queue.push(m.content); if(!revealing) reveal(); }
        else if(m.type==="clarification"){ clearThink(); renderClarification(m.payload); }
      }
    }
    streamDone=true; if(!revealing) $("#send").disabled=false;
  }catch(e){
    clearThink();
    const md=newBubble("chat");
    md.innerHTML="Warning:  Couldn't reach the server. Please try again.";
    $("#send").disabled=false;
  }
}
window.sendClarification = sendClarification;

// chat-thread: a STABLE id (persisted in localStorage) so a page refresh keeps the
// same thread  -  context survives reloads (and, server-side, restarts). "New chat"
// rotates to a fresh id.
const newThreadId=()=>"t"+Math.random().toString(36).slice(2)+Date.now();
let THREAD = localStorage.getItem("penny_thread") || newThreadId();
localStorage.setItem("penny_thread", THREAD);
$("#newchat").onclick=()=>{
  THREAD=newThreadId(); localStorage.setItem("penny_thread", THREAD);
  $("#chat").innerHTML='<div class="muted">New chat  -  context cleared. Ask away.</div>';
  $("#q").focus();
};

async function ask(){
  const q=$("#q").value.trim(); if(!q)return;
  add("me",q); $("#q").value=""; $("#send").disabled=true;
  const think=thinkingBubble();                     // <- loader shows immediately
  let cleared=false; const clearThink=()=>{ if(!cleared){cleared=true; think.remove();} };
  try{
    const r=await fetch("/query",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({question:q,thread:THREAD})});
    const reader=r.body.getReader(), dec=new TextDecoder();
    let buf="", md=null, full="";
    const queue=[]; let streamDone=false, revealing=false;
    const reveal=()=>{ revealing=true;
      if(queue.length){
        full+=queue.shift();
        md.innerHTML=mdToHtml(full);
        md.parentElement.scrollIntoView({behavior:"smooth",block:"end"});
        setTimeout(reveal,18);                       // ~18ms per word -> typewriter
      } else if(streamDone){ revealing=false; $("#send").disabled=false; }
      else setTimeout(reveal,18);                     // wait for more network
    };
    while(true){ const {done,value}=await reader.read(); if(done)break;
      buf+=dec.decode(value,{stream:true}); const lines=buf.split("\n"); buf=lines.pop();
      for(const ln of lines){ if(!ln.trim())continue; const m=JSON.parse(ln);
        if(m.type==="meta"){ clearThink(); md=newBubble(m.path); }   // loader -> real answer
        else if(m.type==="chunk"){ queue.push(m.content); if(!revealing) reveal(); }
        else if(m.type==="clarification"){ clearThink(); renderClarification(m.payload); }
      }
    }
    streamDone=true; if(!revealing) $("#send").disabled=false;
  }catch(e){
    clearThink();
    const md=newBubble("chat");
    md.innerHTML="Warning:  Couldn't reach the server. Please try again.";
    $("#send").disabled=false;
  }
}
$("#send").onclick=ask; $("#q").addEventListener("keydown",e=>{if(e.key==="Enter")ask();});

// ---- Authentication -------------------------------------------------------
// All API fetch calls include the JWT token automatically.
const TOKEN_KEY='penny_token', USER_KEY='penny_user';
function _authHdr(){ const t=localStorage.getItem(TOKEN_KEY); return t?{Authorization:'Bearer '+t}:{}; }

// Intercept all fetch calls to /api routes and inject the Authorization header.
// We do it by wrapping the endpoints we control (status, query, upload, transactions, etc.)
const _origFetch=window.fetch.bind(window);
window.fetch=function(url,...args){
  if(typeof url==='string' && url.startsWith('/') && !url.startsWith('/auth')){
    args[0]=args[0]||{};
    args[0].headers=Object.assign({},args[0].headers||{},_authHdr());
  }
  return _origFetch(url,...args);
};

// Show username in header + verify token on load
(async()=>{
  const tok=localStorage.getItem(TOKEN_KEY);
  const uname=localStorage.getItem(USER_KEY);
  if(!tok){ location.href='/'; return; }
  try{
    const r=await _origFetch('/auth/me',{headers:{Authorization:'Bearer '+tok}});
    if(!r.ok){ localStorage.removeItem(TOKEN_KEY); location.href='/'; return; }
    const name=(await r.json()).username||uname||'';
    const pill=$("#userPill"), btn=$("#logoutBtn");
    if(pill){ pill.textContent='User:  '+name; pill.style.display=''; }
    if(btn) btn.style.display='';
  }catch(e){ /* server offline — let them keep using it */ }
})();

function doLogout(){
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(USER_KEY);
  location.href='/';
}

// ---- Transactions: filterable table over /transactions (numbers from SQL) -----
let tOffset=0; const tLimit=50; let tTotal=0;
function tparams(){
  const p=new URLSearchParams(); p.set("offset",tOffset); p.set("limit",tLimit);
  const q=$("#tq").value.trim(); if(q)p.set("q",q);
  const dir=$("#tdir").value; if(dir)p.set("dir",dir);
  if($("#tstart").value)p.set("start",$("#tstart").value);
  if($("#tend").value)p.set("end",$("#tend").value);
  if($("#tmin").value)p.set("minamt",$("#tmin").value);
  if($("#tmax").value)p.set("maxamt",$("#tmax").value);
  return p.toString();
}
async function loadTxns(reset){
  if(reset)tOffset=0;
  let d; try{ d=await (await fetch("/transactions?"+tparams())).json(); }catch(e){ return; }
  tTotal=d.total;
  let h='<table><thead><tr><th style="text-align:left">Date</th><th style="text-align:left">Payee</th>'
      +'<th style="text-align:left">Category</th><th>Out</th><th>In</th><th>Balance</th></tr></thead><tbody>';
  for(const r of d.rows){
    const desc=(r.descr||"").replace(/"/g,"&quot;");
    h+=`<tr><td style="text-align:left">${r.date}</td>`
      +`<td style="text-align:left" title="${desc}">${r.payee||""}</td>`
      +`<td style="text-align:left">${r.category||""}</td>`
      +`<td>${r.out||""}</td><td style="color:#1f7a1f">${r["in"]||""}</td><td>${r.balance||""}</td></tr>`;
  }
  h+="</tbody></table>";
  $("#txntable").innerHTML = d.rows.length? h : '<div class="muted" style="padding:16px">No matching transactions.</div>';
  $("#txnsummary").innerHTML = tTotal? `<b>${tTotal.toLocaleString()}</b> matched  |  out <b>${d.out_total}</b>  |  in <b>${d.in_total}</b>` : "";
  $("#tpage").textContent = tTotal? `${tOffset+1}-${Math.min(tOffset+tLimit,tTotal)} of ${tTotal.toLocaleString()}` : "";
  $("#tprev").disabled = tOffset<=0; $("#tnext").disabled = tOffset+tLimit>=tTotal;
}
$("#tgo").onclick=()=>loadTxns(true);
$("#tq").addEventListener("keydown",e=>{if(e.key==="Enter")loadTxns(true);});
$("#tdir").onchange=()=>loadTxns(true);
["tstart","tend"].forEach(id=>$("#"+id).onchange=()=>loadTxns(true));
$("#tprev").onclick=()=>{tOffset=Math.max(0,tOffset-tLimit);loadTxns();};
$("#tnext").onclick=()=>{tOffset+=tLimit;loadTxns();};
// (table is loaded by reveal(), once a statement is parsed)
</script></body></html>"""

_DOC_SHELL = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
 :root{--cream:#fff8eb;--ink:#1f1b16;--mut:#6b6256;--lime:#84cc16;--line:#e8dcc2;--code:#1a1a1a;}
 *{box-sizing:border-box} body{margin:0;background:var(--cream);color:var(--ink);
   font:16px/1.65 'Poppins',-apple-system,Segoe UI,Arial}
 .wrap{max-width:880px;margin:0 auto;padding:40px 22px 80px}
 .top{font-size:13px;color:var(--mut);margin-bottom:8px}
 .top a{color:var(--lime);text-decoration:none;font-weight:600}
 h1{font-size:30px;line-height:1.2;margin:.2em 0 .4em;border-bottom:3px solid var(--lime);padding-bottom:.25em}
 h2{font-size:22px;margin:1.6em 0 .5em;border-bottom:1px solid var(--line);padding-bottom:.2em}
 h3{font-size:17px;margin:1.3em 0 .4em}
 p{margin:.7em 0} a{color:#1668c2}
 code{background:#f1e9d6;padding:.1em .4em;border-radius:5px;font:13.5px/1.5 'JetBrains Mono',Consolas,monospace}
 pre{background:var(--code);color:#eee;padding:14px 16px;border-radius:10px;overflow:auto;font-size:12.5px;line-height:1.45}
 pre code{background:none;color:#eee;padding:0}
 table{border-collapse:collapse;width:100%;margin:1em 0;font-size:14.5px}
 th,td{border:1px solid var(--line);padding:8px 11px;text-align:left;vertical-align:top}
 th{background:#f3ead6} tr:nth-child(even) td{background:#fffdf6}
 blockquote{margin:1em 0;padding:.4em 1em;border-left:4px solid var(--lime);background:#fffdf3;color:#3a352c}
 hr{border:0;border-top:1px solid var(--line);margin:2em 0}
 ul,ol{margin:.6em 0 .6em 1.2em} li{margin:.25em 0}
</style></head><body><div class="wrap">
<div class="top">Penny  |  <a href="/">app</a>  |  <a href="/roadmap">Roadmap</a>  |  <a href="/hld">HLD</a>  |  <a href="/lld">LLD</a>  |  <a href="__RAW__">raw</a></div>
__BODY__
</div></body></html>"""

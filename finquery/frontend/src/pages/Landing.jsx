import React, { useState, useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import PennyAvatar from '../components/PennyAvatar';
import { uploadDocument } from '../api';
import { formatMoney, categoryMeta } from '../format';
import './Landing.css';

// Auth header + tiny JSON GET helper — the wizard talks to the same on-device
// API the dashboard does, so every figure it shows is real, not mocked.
const authHeaders = () => {
  const token = localStorage.getItem('token') || localStorage.getItem('penny_token');
  return token ? { Authorization: `Bearer ${token}` } : {};
};
const fetchJSON = async (path) => {
  try {
    const r = await fetch(path, { headers: authHeaders() });
    if (!r.ok) return null;
    return await r.json();
  } catch { return null; }
};

// Friendly model label (mirrors the dashboard mapping).
const prettyModel = (m) => {
  const low = (m || '').toLowerCase();
  if (low.includes('llama')) return 'Llama 8B';
  if (low.includes('qwen')) return 'Qwen 3B';
  if (low.includes('gemma')) return 'Gemma 2B';
  return m || '';
};

// Map a real category name to the feed's colour class + short label.
const CAT_FEED = [
  { k: ['food', 'dining', 'grocer', 'restaurant'], cat: 'food',  cl: 'FOOD' },
  { k: ['income', 'salary'],                       cat: 'inc',   cl: 'INC' },
  { k: ['invest', 'insurance'],                    cat: 'inv',   cl: 'INV' },
  { k: ['transport', 'travel', 'fuel'],            cat: 'tr',    cl: 'TR' },
  { k: ['shop'],                                   cat: 'shop',  cl: 'SHOP' },
  { k: ['subscription', 'entertain'],              cat: 'sub',   cl: 'SUB' },
  { k: ['bill', 'utilit'],                         cat: 'bills', cl: 'BILLS' },
  { k: ['cash', 'atm'],                            cat: 'inc',   cl: 'CASH' },
  { k: ['transfer'],                               cat: 'tr',    cl: 'XFER' },
  { k: ['rent', 'housing'],                        cat: 'bills', cl: 'RENT' },
];
const feedCat = (name) => {
  const l = (name || '').toLowerCase();
  for (const c of CAT_FEED) if (c.k.some((x) => l.includes(x))) return c;
  return { cat: 'food', cl: (name || 'OTHER').toUpperCase().slice(0, 6) };
};

const ACCTS = {
  current: {
    icon: "🏦", name: "Current account", sub: "drop a statement file · CSV / PDF",
    exportSteps: ["Open your bank app or website", "Find Statements or Download transactions", "Pick last 12 months, format CSV (PDF also works)", "Save to your Mac, then drag here"],
    sampleFile: "monzo_oct.csv", sampleMeta: "14.2 KB · 1,142 rows"
  },
  credit: {
    icon: "💳", name: "Credit card", sub: "drop a statement file · CSV / PDF",
    exportSteps: ["Log into your card issuer (Amex, Barclaycard, etc.)", "Go to Statements & Activity", "Select last 12 months, choose CSV/Excel", "Drag the file here"],
    sampleFile: "amex_2024.csv", sampleMeta: "8.4 KB · 316 rows"
  },
  savings: {
    icon: "🐖", name: "Savings account", sub: "Easy-access or notice",
    exportSteps: ["Open your savings bank", "Find Statements", "Pick last 12 months", "Drag CSV or PDF here"],
    sampleFile: "savings_2024.csv", sampleMeta: "3.2 KB · 24 rows"
  },
  isa: {
    icon: "🛡️", name: "Cash ISA", sub: "Tax-free savings",
    exportSteps: ["Log into your ISA provider", "Find statements", "Export 12 months as CSV or PDF", "Drag here"],
    sampleFile: "isa.pdf", sampleMeta: "42 KB · PDF 4 pages"
  },
  stocks: {
    icon: "📈", name: "Stocks & shares", sub: "Vanguard, T212, HL",
    exportSteps: ["Log into broker (Vanguard, T212, HL)", "Find Account history", "Export 12 months as CSV", "Drag here — I'll read trades & dividends"],
    sampleFile: "t212_report.csv", sampleMeta: "6.7 KB · 89 trades"
  },
  crypto: {
    icon: "🪙", name: "Crypto wallet", sub: "Coinbase, Kraken",
    exportSteps: ["Log into exchange (Coinbase, Kraken)", "Go to Reports", "Export transactions as CSV", "Drag here"],
    sampleFile: "coinbase.csv", sampleMeta: "4.1 KB · 47 txns"
  },
  pension: {
    icon: "🏛", name: "Pension", sub: "Nest, PenFold, workplace",
    exportSteps: ["Log into your pension provider", "Download most recent statement", "PDF is fine", "Drag here"],
    sampleFile: "pension_2024.pdf", sampleMeta: "180 KB · PDF 12 pages"
  },
  property: {
    icon: "🏠", name: "Property / mortgage", sub: "Statement-based",
    exportSteps: ["Log into your mortgage provider", "Download annual statement", "Upload PDF — I track principal & equity"],
    sampleFile: "mortgage.pdf", sampleMeta: "96 KB · PDF 6 pages"
  },
  business: {
    icon: "💼", name: "Business account", sub: "Ltd co or sole trader",
    exportSteps: ["Log into business bank", "Find Statements", "Pick 12 months CSV", "Drag here"],
    sampleFile: "tide_business.csv", sampleMeta: "22.4 KB · 1,847 rows"
  },
  other: {
    icon: "+", name: "Something else", sub: "Any financial file",
    exportSteps: ["Export from wherever the money lives", "Any format works", "Drag the file here"],
    sampleFile: "statement.csv", sampleMeta: "~15 KB · ~1,000 rows"
  }
};

const sampleTxns = [
  { n: "Deliveroo", m: "oct 14 · 10:47pm", amt: "-£18.40", icon: "🍱", cat: "food", cl: "FOOD" },
  { n: "Pret a Manger", m: "oct 14 · 8:14am", amt: "-£6.80", icon: "☕", cat: "food", cl: "FOOD" },
  { n: "Salary · Acme", m: "oct 14 · 7am", amt: "+£3,820", icon: "💷", cat: "inc", cl: "INC" },
  { n: "VWRL purchase", m: "oct 13 · trade", amt: "-£500", icon: "📈", cat: "inv", cl: "INV" },
  { n: "TfL contactless", m: "oct 13 · 6:32pm", amt: "-£8.30", icon: "🚇", cat: "tr", cl: "TR" },
  { n: "ASOS", m: "oct 12 · 3:42pm", amt: "-£87.50", icon: "🛍", cat: "shop", cl: "SHOP" },
  { n: "Spotify", m: "oct 12", amt: "-£9.99", icon: "🎵", cat: "sub", cl: "SUB" },
  { n: "Dividend · VWRL", m: "oct 12 · payout", amt: "+£23.40", icon: "💰", cat: "inv", cl: "DIV" },
  { n: "Tesco Express", m: "oct 11 · 7:15pm", amt: "-£23.40", icon: "🛒", cat: "food", cl: "FOOD" },
  { n: "Uber", m: "oct 11 · 11:23pm", amt: "-£18.50", icon: "🚕", cat: "tr", cl: "TR" },
  { n: "Audible", m: "oct 10", amt: "-£7.99", icon: "🎧", cat: "sub", cl: "SUB" },
  { n: "Netflix", m: "oct 10", amt: "-£10.99", icon: "🎬", cat: "sub", cl: "SUB" },
  { n: "Octopus Energy", m: "oct 9 · DD", amt: "-£94", icon: "⚡", cat: "bills", cl: "BILLS" },
  { n: "GOOGL · sold 2", m: "oct 9 · trade", amt: "+£287.50", icon: "📈", cat: "inv", cl: "INV" },
  { n: "Council Tax", m: "oct 7 · DD", amt: "-£142", icon: "🏛", cat: "bills", cl: "BILLS" }
];

const Landing = () => {
  const [step, setStep] = useState(1);
  const [name, setName] = useState('Alex');
  const [selectedAccts, setSelectedAccts] = useState([]);
  const [currentAcctIdx, setCurrentAcctIdx] = useState(0);
  const [uploadedFiles, setUploadedFiles] = useState({});
  const [procCount, setProcCount] = useState(0);
  const [procStatus, setProcStatus] = useState('parsing locally on your Mac');
  const [feedCount, setFeedCount] = useState('0 parsed');
  const [feedList, setFeedList] = useState([]);
  const [procFiles, setProcFiles] = useState([]);
  const [modelName, setModelName] = useState('');
  const [currency, setCurrency] = useState('INR');
  const [insights, setInsights] = useState(null); // real figures for the results screen

  const navigate = useNavigate();
  const procInterval = useRef(null);
  const fileInputRef = useRef(null);
  const realFeedRef = useRef([]);   // interval reads this (closures can't see state updates)
  const targetRef = useRef(0);      // live transaction-count target
  const statusRef = useRef(null);   // status-message rotator timer
  const shownRef = useRef(0);       // eased/displayed transaction count

  const modelLabel = modelName || 'a local LLM';

  useEffect(() => {
    // Pull the real model + currency already known to the backend so even the
    // intro copy reflects this machine, not a hardcoded "Qwen 3 14B".
    (async () => {
      const s = await fetchJSON('/status');
      if (s) {
        if (s.model) setModelName(prettyModel(s.model));
        if (s.currency) setCurrency(s.currency);
      }
    })();
    return () => {
      if (procInterval.current) clearInterval(procInterval.current);
      if (statusRef.current) clearInterval(statusRef.current);
    };
  }, []);

  // Pull the real transactions detected so far into the live feed (called after
  // each file finishes parsing, so the feed fills as the parse progresses).
  const refreshFeed = async () => {
    const txns = await fetchJSON('/transactions?limit=15');
    if (txns && Array.isArray(txns.rows) && txns.rows.length) {
      const mapped = txns.rows.map((r) => {
        const fc = feedCat(r.category);
        return {
          n: r.payee || 'Transaction',
          m: r.date || '',
          amt: r.in ? `+${r.in}` : (r.out ? `-${r.out}` : ''),
          icon: categoryMeta(r.category).icon,
          cat: fc.cat, cl: fc.cl,
        };
      });
      realFeedRef.current = mapped;
      setFeedList(mapped.slice(0, 15));
    }
  };

  // Build the results-screen insights from real on-device figures once parsing is done.
  const loadInsights = async () => {
    const [st, dash] = await Promise.all([fetchJSON('/status'), fetchJSON('/dashboard')]);
    const cur = (st && st.currency) || (dash && dash.currency) || currency;
    setCurrency(cur);
    if (st && st.model) setModelName(prettyModel(st.model));
    if (dash && dash.ready) {
      const cats = dash.categories || [];
      const totals = dash.totals || {};
      setInsights({
        currency: cur,
        rows: (st && st.rows) || totals.count || 0,
        topCategory: cats.length ? { name: cats[0].name, amount: cats[0].amount } : null,
        largest: dash.largest || null,       // {date, payee, amount}
        subs: dash.subscriptions || [],
        net: totals.net,
        spend: totals.spending,
        income: totals.income,
        balance: dash.balance,
      });
    }
  };

  const goTo = (n) => {
    if (procInterval.current) {
      clearInterval(procInterval.current);
      procInterval.current = null;
    }
    setStep(n);
    if (n === 6) startProcessing();
  };

  const toggleAccountSelection = (acctKey) => {
    if (selectedAccts.includes(acctKey)) {
      setSelectedAccts(selectedAccts.filter(k => k !== acctKey));
    } else {
      setSelectedAccts([...selectedAccts, acctKey]);
    }
  };

  const startUpload = () => {
    if (selectedAccts.length === 0) return;
    setCurrentAcctIdx(0);
    const initialUploads = {};
    selectedAccts.forEach(a => { initialUploads[a] = []; });
    setUploadedFiles(initialUploads);
    goTo(5);
  };

  const handleFilesAdded = (filesList) => {
    const ak = selectedAccts[currentAcctIdx];
    if (!ak) return;
    const currentFiles = uploadedFiles[ak] || [];
    const newFiles = [...currentFiles];

    // Just COLLECT the files here — the actual upload + parse is deferred to the
    // processing screen (step 6) so the parse animation plays during real work.
    for (let i = 0; i < filesList.length; i++) {
      const file = filesList[i];
      const sizeStr = file.size > 1024 * 1024
        ? (file.size / (1024 * 1024)).toFixed(1) + ' MB'
        : (file.size / 1024).toFixed(1) + ' KB';
      newFiles.push({ name: file.name, meta: sizeStr, fileObj: file, rows: 0 });
    }

    setUploadedFiles({ ...uploadedFiles, [ak]: newFiles });
  };

  const handleFileSelect = (e) => {
    if (e.target.files && e.target.files.length > 0) {
      handleFilesAdded(e.target.files);
    }
  };

  const handleFileDrop = (e) => {
    e.preventDefault();
    if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
      handleFilesAdded(e.dataTransfer.files);
    }
  };

  const triggerFileSelect = () => {
    if (fileInputRef.current) {
      fileInputRef.current.click();
    }
  };

  const removeFile = (ak, idx) => {
    const currentFiles = uploadedFiles[ak] || [];
    const newFiles = currentFiles.filter((_, i) => i !== idx);
    setUploadedFiles({ ...uploadedFiles, [ak]: newFiles });
  };

  const nextAccount = async () => {
    // Primary check: if every selected account already has at least one file → go to step 7.
    const allDone = selectedAccts.every(ak => (uploadedFiles[ak] || []).length > 0);
    if (allDone) {
      goTo(7);
      await startProcessingDirectly();
      return;
    }

    // Otherwise find the first account (excluding current) that still has no files.
    let next = -1;
    for (let i = 0; i < selectedAccts.length; i++) {
      const ak = selectedAccts[i];
      if (i !== currentAcctIdx && (uploadedFiles[ak] || []).length === 0) {
        next = i;
        break;
      }
    }

    if (next >= 0) {
      // Still more accounts needing files — stay on step 5, switch to that account.
      setCurrentAcctIdx(next);
    } else {
      // No other empty accounts found → go to results.
      goTo(7);
      await startProcessingDirectly();
    }
  };

  const skipToProcessing = async () => {
    const finalUploads = { ...uploadedFiles };
    selectedAccts.forEach(ak => {
      if ((finalUploads[ak] || []).length === 0) {
        const info = ACCTS[ak];
        finalUploads[ak] = [{ name: info.sampleFile, meta: info.sampleMeta }];
      }
    });
    setUploadedFiles(finalUploads);
    goTo(7);
    await startProcessingDirectly();
  };

  // DEMO fallback: user hit "Skip — show demo" with no real files. Keeps the
  // illustrative timed animation with sample transactions.
  const runDemoAnimation = (allFiles) => {
    let msgIdx = 0, feedIdx = 0;
    const dynamicTarget = 2847;
    targetRef.current = dynamicTarget;
    localStorage.setItem('penny_dynamic_total_rows', dynamicTarget);
    const dur = 5400, startTime = Date.now();
    const statusMsgs = [
      { at: 0, t: "opening statements..." },
      { at: 700, t: "parsing transactions on your Mac..." },
      { at: 1400, t: `categorising with ${modelLabel} 🧠` },
      { at: 2100, t: "reading next file..." },
      { at: 2800, t: "detecting subscriptions 🔍" },
      { at: 3500, t: "merging accounts 🔗" },
      { at: 4800, t: "almost ready..." },
    ];
    procInterval.current = setInterval(() => {
      const el = Date.now() - startTime;
      const pct = Math.min(el / dur, 1);
      setProcCount(Math.floor(dynamicTarget * pct));
      setFeedCount(`${Math.floor(dynamicTarget * pct).toLocaleString()} parsed`);
      const fps = allFiles.length > 0 ? 1 / allFiles.length : 1;
      setProcFiles(allFiles.map((f, i) => {
        const s = i * fps, e = (i + 1) * fps;
        return { ...f, status: pct >= e ? 'done' : (pct >= s ? 'processing' : 'queued') };
      }));
      while (msgIdx < statusMsgs.length - 1 && el >= statusMsgs[msgIdx + 1].at) {
        msgIdx++; setProcStatus(statusMsgs[msgIdx].t);
      }
      const tf = Math.floor(pct * 40);
      if (feedIdx < tf && feedIdx < sampleTxns.length * 3) {
        setFeedList(prev => [sampleTxns[feedIdx % sampleTxns.length], ...prev].slice(0, 15));
        feedIdx++;
      }
      if (pct >= 1) {
        clearInterval(procInterval.current); procInterval.current = null;
        setProcStatus('✨ ready · in a moment...');
        setTimeout(() => setStep(7), 800);
      }
    }, 50);
  };

  const startProcessingDirectly = async () => {
    setInsights(null);
    const allFiles = [];
    selectedAccts.forEach(ak => {
      (uploadedFiles[ak] || []).forEach(f => allFiles.push({ acct: ak, file: f }));
    });

    const hasReal = allFiles.some(f => f.file && f.file.fileObj);
    if (!hasReal) {
      // Just run mock insight loader for demo data
      localStorage.setItem('penny_dynamic_total_rows', 2847);
      await loadInsights();
      return;
    }

    let totalRows = 0;
    for (let i = 0; i < allFiles.length; i++) {
      const fileObj = allFiles[i].file.fileObj;
      if (fileObj) {
        try {
          const res = await uploadDocument(fileObj);
          const rows = (res && (res.rows ?? (res.parsed && res.parsed[0] && res.parsed[0].rows))) || 0;
          totalRows += rows;
          if (res && res.currency) setCurrency(res.currency);
        } catch (e) {
          console.error('Parse failed:', e);
        }
      }
    }
    if (totalRows > 0) {
      localStorage.setItem('penny_dynamic_total_rows', totalRows);
    }
    await loadInsights();
  };

  // REAL parse: the animation is shown WHILE each file is actually uploaded and

  // parsed on-device. The screen stays up until the real parse resolves — so a
  // slow LLM-parsed PDF keeps animating instead of ending on a fake timer.
  const startProcessing = async () => {
    setFeedList([]);
    setProcCount(0);
    setInsights(null);
    realFeedRef.current = [];
    shownRef.current = 0;
    const allFiles = [];
    selectedAccts.forEach(ak => {
      (uploadedFiles[ak] || []).forEach(f => allFiles.push({ acct: ak, file: f }));
    });
    setProcFiles(allFiles.map(f => ({ ...f, status: 'queued' })));

    const hasReal = allFiles.some(f => f.file && f.file.fileObj);
    if (!hasReal) { runDemoAnimation(allFiles); return; }

    targetRef.current = 0;

    // Rotating status line + eased counter — these run for as long as the real
    // parse takes (however many seconds the backend needs).
    const statusMsgs = [
      "opening statements...",
      "parsing transactions on your Mac...",
      `categorising with ${modelLabel} 🧠`,
      "detecting subscriptions 🔍",
      "merging accounts 🔗",
      "almost there...",
    ];
    let msgIdx = 0;
    setProcStatus(statusMsgs[0]);
    statusRef.current = setInterval(() => {
      msgIdx = Math.min(msgIdx + 1, statusMsgs.length - 1);
      setProcStatus(statusMsgs[msgIdx]);
    }, 1500);
    procInterval.current = setInterval(() => {
      const tgt = targetRef.current;
      if (shownRef.current < tgt) {
        shownRef.current = Math.min(shownRef.current + Math.max(1, Math.ceil((tgt - shownRef.current) / 6)), tgt);
        setProcCount(shownRef.current);
        setFeedCount(`${shownRef.current.toLocaleString()} parsed`);
      }
    }, 60);

    // Upload + parse each file for real, one at a time — this is the slow part.
    for (let i = 0; i < allFiles.length; i++) {
      setProcFiles(prev => prev.map((pf, idx) => idx === i ? { ...pf, status: 'processing' } : pf));
      const fileObj = allFiles[i].file.fileObj;
      let rows = 0;
      if (fileObj) {
        try {
          const res = await uploadDocument(fileObj);
          rows = (res && (res.rows ?? (res.parsed && res.parsed[0] && res.parsed[0].rows))) || 0;
          if (res && res.currency) setCurrency(res.currency);
        } catch (e) {
          console.error('Parse failed:', e);
        }
      }
      targetRef.current += rows;
      setProcFiles(prev => prev.map((pf, idx) => idx === i
        ? { ...pf, status: 'done', file: { ...pf.file, meta: rows > 0 ? `${pf.file.meta} · ${rows.toLocaleString()} rows` : pf.file.meta } }
        : pf));
      await refreshFeed();   // show the real transactions detected so far
    }

    // Real parse finished — settle the counter, load insights, advance.
    clearInterval(statusRef.current); statusRef.current = null;
    clearInterval(procInterval.current); procInterval.current = null;
    if (targetRef.current > 0) localStorage.setItem('penny_dynamic_total_rows', targetRef.current);
    shownRef.current = targetRef.current;
    setProcCount(targetRef.current);
    setFeedCount(`${targetRef.current.toLocaleString()} parsed`);
    setProcStatus('categorising & finding patterns 🧠');
    await loadInsights();
    setProcStatus('✨ ready · in a moment...');
    setTimeout(() => setStep(7), 900);
  };

  const handleFinish = () => {
    navigate('/app');
  };

  return (
    <div className="desktop-wizard">
      <div className="hdr">
        <div className="brnd">
          <PennyAvatar size="xs" />
          <div className="brnd-n">penny<em>.</em></div>
        </div>
        {step < 7 && (
          <div className="prog">
            {[1, 2, 3, 4, 5, 6, 7].map((num) => (
              <div 
                key={num} 
                className={`pd ${num < step ? 'done' : ''} ${num === step ? 'on' : ''}`}
              />
            ))}
            <div className="pd-l">Step {step} of 7</div>
          </div>
        )}
        <div className="pill">running locally · M3 Mac</div>
      </div>

      {step === 1 && (
        <div className="scrn">
          <div className="s1">
            <div className="blob b1"></div>
            <div className="blob b2"></div>
            <div className="s1c">
              <div className="s1l">
                <PennyAvatar size="xl" wave={true} />
              </div>
              <div>
                <div className="tag">hi 👋 i'm penny</div>
                <div className="s1h">Your money,<br />but make it <em>fun.</em></div>
                <div className="s1p">
                  A tiny AI on your Mac. Drop in your statements and investment reports — I'll find where your money goes, banish zombie subs, and roast you when you deserve it.
                </div>
                <div className="bul">
                  <div className="bul-r"><div className="bul-i">🔒</div><div><b>Lives on your Mac.</b> Files never leave. Ever.</div></div>
                  <div className="bul-r"><div className="bul-i">📄</div><div><b>You upload files.</b> CSV, PDF, Excel — no passwords.</div></div>
                  <div className="bul-r"><div className="bul-i">⚡</div><div><b>{modelLabel}</b> on your Mac's chip. Proper reasoning.</div></div>
                </div>
                <div className="cta">
                  <button className="btn lime lg" onClick={() => goTo(2)}>Let's set up →</button>
                  <button className="btn ghost" onClick={() => navigate('/login')}>I have an account</button>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}

      {step === 2 && (
        <div className="scrn">
          <div className="s2">
            <div className="s2l">
              <div className="s2h">First — what should<br />I <em>call you?</em></div>
              <div className="s2p">I'll use your first name when I talk to you. Doesn't need to be your legal one.</div>
              <input 
                className="ni" 
                type="text" 
                value={name} 
                onChange={(e) => setName(e.target.value)}
                placeholder="Alex" 
              />
              <div className="nh">📌 stays on this Mac · never shared</div>
              <div className="na">
                <button className="skip" onClick={() => goTo(1)}>← back</button>
                <button className="btn lime" onClick={() => goTo(3)}>Nice to meet you →</button>
              </div>
            </div>
            <div className="s2r">
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
                <div className="sp">eee, a new friend! 🥹<br />what's your name?</div>
                <PennyAvatar size="lg" mood="celebrate" />
              </div>
            </div>
          </div>
        </div>
      )}

      {step === 3 && (
        <div className="scrn">
          <div className="s3">
            <div className="s3hd">
              <PennyAvatar size="md" />
              <div>
                <div className="s3h">How this <em>works</em>, in four steps</div>
                <div className="s3s">No bank logins. No passwords shared. No data leaving your Mac. Just drop files in.</div>
              </div>
            </div>
            <div className="steps">
              <div className="stc">
                <div className="stn">1</div>
                <div className="sti">🗂️</div>
                <div className="sth">Pick what to track</div>
                <div className="stp">Current accounts, credit cards, savings, investments — any account you can export from.</div>
                <div className="stt">~30 SECONDS</div>
              </div>
              <div className="stc">
                <div className="stn">2</div>
                <div className="sti">📥</div>
                <div className="sth">Drop in your files</div>
                <div className="stp"><b>CSV, PDF, Excel, or QIF/OFX.</b> Export from your bank or investment app, drag into Penny.</div>
                <div className="stt">~3 MINUTES</div>
              </div>
              <div className="stc">
                <div className="stn">3</div>
                <div className="sti">🧠</div>
                <div className="sth">I read everything locally</div>
                <div className="stp">{modelLabel} on your Mac's chip categorises, finds patterns, spots subs.</div>
                <div className="stt">~30 SECONDS</div>
              </div>
              <div className="stc">
                <div className="stn">4</div>
                <div className="sti">🔒</div>
                <div className="sth">Stays on this Mac</div>
                <div className="stp">Encrypted in <code>~/Library/Penny</code>. Wipe anytime.</div>
                <div className="stt priv">FOREVER LOCAL</div>
              </div>
            </div>
            <div className="s3f">
              <div className="s3ft">
                <PennyAvatar size="xs" />
                You re-drop fresh files when you want me to see the latest. Once a month is plenty.
              </div>
              <div style={{ display: 'flex', gap: '10px', alignItems: 'center' }}>
                <button className="skip" onClick={() => goTo(2)}>← back</button>
                <button className="btn lime" onClick={() => goTo(4)}>Got it, let's go →</button>
              </div>
            </div>
          </div>
        </div>
      )}

      {step === 4 && (
        <div className="scrn">
          <div className="s4">
            <div className="s4l">
              <div className="s4h">What accounts do we<br />want to <em>track?</em></div>
              <div className="s4s">Select all that apply. You can add or remove these later.</div>
              
              <div className="sec">SPENDING</div>
              <div className="ag">
                <div className={`ac ${selectedAccts.includes('current') ? 'sel' : ''}`} onClick={() => toggleAccountSelection('current')}>
                  <div className="ai">🏦</div>
                  <div className="an">
                    <div className="ann">Current account</div>
                    <div className="and">Day-to-day</div>
                  </div>
                </div>
                <div className={`ac ${selectedAccts.includes('credit') ? 'sel' : ''}`} onClick={() => toggleAccountSelection('credit')}>
                  <div className="ai">💳</div>
                  <div className="an">
                    <div className="ann">Credit card</div>
                    <div className="and">Visa / Mastercard / Amex</div>
                  </div>
                </div>
              </div>

              <div className="sec">SAVINGS</div>
              <div className="ag">
                <div className={`ac ${selectedAccts.includes('savings') ? 'sel' : ''}`} onClick={() => toggleAccountSelection('savings')}>
                  <div className="ai">🐖</div>
                  <div className="an">
                    <div className="ann">Savings account</div>
                    <div className="and">Easy-access or notice</div>
                  </div>
                </div>
                <div className={`ac ${selectedAccts.includes('isa') ? 'sel' : ''}`} onClick={() => toggleAccountSelection('isa')}>
                  <div className="ai">🛡️</div>
                  <div className="an">
                    <div className="ann">Cash ISA</div>
                    <div className="and">Tax-free savings</div>
                  </div>
                </div>
              </div>

              <div className="sec">INVESTMENTS</div>
              <div className="ag">
                <div className={`ac ${selectedAccts.includes('stocks') ? 'sel' : ''}`} onClick={() => toggleAccountSelection('stocks')}>
                  <div className="ai">📈</div>
                  <div className="an">
                    <div className="ann">Stocks & shares</div>
                    <div className="and">Vanguard, T212, HL</div>
                  </div>
                </div>
                <div className={`ac ${selectedAccts.includes('crypto') ? 'sel' : ''}`} onClick={() => toggleAccountSelection('crypto')}>
                  <div className="ai">🪙</div>
                  <div className="an">
                    <div className="ann">Crypto wallet</div>
                    <div className="and">Coinbase, Kraken</div>
                  </div>
                </div>
                <div className={`ac ${selectedAccts.includes('pension') ? 'sel' : ''}`} onClick={() => toggleAccountSelection('pension')}>
                  <div className="ai">🏛</div>
                  <div className="an">
                    <div className="ann">Pension</div>
                    <div className="and">Nest, PenFold, workplace</div>
                  </div>
                </div>
                <div className={`ac ${selectedAccts.includes('property') ? 'sel' : ''}`} onClick={() => toggleAccountSelection('property')}>
                  <div className="ai">🏠</div>
                  <div className="an">
                    <div className="ann">Property / mortgage</div>
                    <div className="and">Statement-based</div>
                  </div>
                </div>
              </div>

              <div className="sec">OTHER</div>
              <div className="ag">
                <div className={`ac ${selectedAccts.includes('business') ? 'sel' : ''}`} onClick={() => toggleAccountSelection('business')}>
                  <div className="ai">💼</div>
                  <div className="an">
                    <div className="ann">Business account</div>
                    <div className="and">Ltd co or sole trader</div>
                  </div>
                </div>
                <div className={`ac ${selectedAccts.includes('other') ? 'sel' : ''}`} onClick={() => toggleAccountSelection('other')}>
                  <div className="ai">+</div>
                  <div className="an">
                    <div className="ann">Something else</div>
                    <div className="and">Any financial file</div>
                  </div>
                </div>
              </div>
            </div>
            <div className="s4r">
              <div>
                <div className="s4rh">
                  <PennyAvatar size="sm" />
                  What I read
                </div>
                <div className="s4i">
                  <div className="s4ih">File formats I understand:</div>
                  <ul className="s4ul">
                    <li><b>CSV</b> — most common, fastest</li>
                    <li><b>PDF</b> — statements, broker reports</li>
                    <li><b>Excel</b> — XLS, XLSX</li>
                  </ul>
                </div>
                <div className="s4i" style={{ background: 'var(--lime-s)', borderColor: 'var(--lime-d)' }}>
                  <div className="s4ih">What stays private:</div>
                  <ul className="s4ul">
                    <li>Files <b>never upload</b></li>
                    <li>Processed on your Mac's chip</li>
                    <li>Encrypted at rest locally</li>
                  </ul>
                </div>
              </div>
              <div>
                <div className="s4cnt"><b>{selectedAccts.length}</b> accounts selected</div>
                <button 
                  className="btn lime" 
                  style={{ width: '100%', marginBottom: '7px' }} 
                  onClick={startUpload}
                  disabled={selectedAccts.length === 0}
                >
                  Continue to upload →
                </button>
                <button className="skip" style={{ width: '100%' }} onClick={() => goTo(3)}>← back</button>
              </div>
            </div>
          </div>
        </div>
      )}

      {step === 5 && (
        <div className="scrn">
          <div className="s5">
            <div className="s5l">
              <div className="s5lh">Your accounts</div>
              <div className="s5ls">Drop in files for each. No rush — finish in your own time.</div>
              <div id="acctList">
                {selectedAccts.map((ak, i) => {
                  const info = ACCTS[ak];
                  const done = (uploadedFiles[ak] || []).length > 0;
                  const active = i === currentAcctIdx;
                  return (
                    <div 
                      key={ak} 
                      className={`atab ${done ? 'done' : ''} ${active ? 'on' : ''}`}
                      onClick={() => setCurrentAcctIdx(i)}
                    >
                      <div className="ati">{info.icon}</div>
                      <div className="atif">
                        <div className="atn">{info.name}</div>
                        <div className="ats">
                          {done ? `${uploadedFiles[ak].length} FILE${uploadedFiles[ak].length > 1 ? 'S' : ''}` : (active ? 'CURRENT' : 'WAITING')}
                        </div>
                      </div>
                      <div className="atc">✓</div>
                    </div>
                  );
                })}
              </div>
              <div style={{ marginTop: 'auto', paddingTop: '12px', borderTop: '1px dashed var(--line)' }}>
                <div style={{ fontFamily: 'Caveat, cursive', fontSize: '13px', color: 'var(--ink2)', fontWeight: '700', lineHeight: 1.4 }}>
                  Penny remembers progress — close anytime.
                </div>
              </div>
            </div>
            <div className="s5r">
              <div className="s5h"><em>{ACCTS[selectedAccts[currentAcctIdx]]?.name}</em></div>
              <div className="s5acs">{ACCTS[selectedAccts[currentAcctIdx]]?.sub}</div>
              <div 
                className="uz" 
                onClick={triggerFileSelect}
                onDragOver={(e) => e.preventDefault()}
                onDrop={handleFileDrop}
              >
                <input
                  type="file"
                  ref={fileInputRef}
                  style={{ display: 'none' }}
                  onChange={handleFileSelect}
                  multiple
                />
                <div className="uzi">📥</div>
                <div className="uzh">Drag files here</div>
                <div className="uzp">Or click to browse. <b>I process them locally — never uploaded.</b></div>
                <div className="fmts">
                  <div className="fmt">.CSV</div><div className="fmt">.PDF</div><div className="fmt">.XLSX</div>
                </div>
              </div>

              {(uploadedFiles[selectedAccts[currentAcctIdx]] || []).length > 0 && (
                <div className="uf">
                  <div style={{ fontFamily: 'JetBrains Mono, monospace', fontSize: '9.5px', color: 'var(--dim)', fontWeight: 700, letterSpacing: '0.12em', textTransform: 'uppercase', marginBottom: '7px' }}>
                    FILES READY
                  </div>
                  <div className="ufl">
                    {(uploadedFiles[selectedAccts[currentAcctIdx]] || []).map((f, i) => (
                      <div className="uff" key={i}>
                        <div className="uffi">📄</div>
                        <div style={{ flex: 1, minWidth: 0 }}>
                          <div className="uffn">{f.name}</div>
                          <div className="uffm">{f.meta}</div>
                        </div>
                        <div className="uffs">READY ✓</div>
                        <button className="uffr" onClick={() => removeFile(selectedAccts[currentAcctIdx], i)}>×</button>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              <div className="eh">
                <div className="ehh">💡 How to export</div>
                <div id="exSteps">
                  {(ACCTS[selectedAccts[currentAcctIdx]]?.exportSteps || []).map((s, i) => (
                    <div className="es" key={i}>
                      <div className="esn">{i + 1}</div>
                      <div className="est" dangerouslySetInnerHTML={{ __html: s }}></div>
                    </div>
                  ))}
                </div>
              </div>

              <div className="s5f">
                <button className="skip" onClick={() => goTo(4)}>← back</button>
                <div style={{ display: 'flex', gap: '9px', alignItems: 'center' }}>
                  <button className="btn ghost" onClick={skipToProcessing} style={{ fontSize: '12.5px' }}>
                    Skip — show demo
                  </button>
                  {((uploadedFiles[selectedAccts[currentAcctIdx]] || []).length > 0) && (
                    <button className="btn lime" onClick={nextAccount}>
                      Next →
                    </button>
                  )}
                </div>
              </div>
            </div>
          </div>
        </div>
      )}

      {step === 6 && (
        <div className="scrn">
          <div className="s6">
            <div className="s6l">
              <div className="s6ps">
                <PennyAvatar size="md" mood="thinking" />
                <div>
                  <div className="s6h">Reading your <em>files</em>...</div>
                  <div className="s6st">{procStatus}</div>
                </div>
              </div>
              <div className="fl">
                {procFiles.map((pf, i) => (
                  <div className={`fi ${pf.status}`} key={i}>
                    <div className="fii">{ACCTS[pf.acct]?.icon}</div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div className="fin">{pf.file.name}</div>
                      <div className="fim">{pf.file.meta}</div>
                    </div>
                    <div className={`fis ${pf.status === 'processing' ? 'fsp' : (pf.status === 'done' ? 'fsd' : 'fsw')}`}>
                      {pf.status === 'processing' ? 'processing' : (pf.status === 'done' ? 'done ✓' : 'queued')}
                    </div>
                  </div>
                ))}
              </div>
              <div className="s6cnl">TRANSACTIONS PARSED</div>
              <div className="s6cn">{procCount.toLocaleString()}</div>
              <div className="s6pb">
                <div className="s6pi">🔒</div>
                <div>
                  <div className="s6ph">Where your files live</div>
                  <div className="s6pp">Stored encrypted in <code>~/Library/Penny/data</code>. <b>Never uploaded.</b></div>
                </div>
              </div>
            </div>
            <div className="s6r">
              <div className="fdh">
                <span>LIVE FEED · DETECTED ACTIVITY</span>
                <span className="c">{feedCount}</span>
              </div>
              <div className="fd">
                {feedList.map((t, idx) => (
                  <div className="ft" key={idx}>
                    <div className="fti">{t.icon}</div>
                    <div className="ftb">
                      <div className="ftn">{t.n}</div>
                      <div className="ftm">{t.m}</div>
                    </div>
                    <div className={`ftc cat-${t.cat}`}>{t.cl}</div>
                    <div className={`fta ${t.amt.startsWith('+') ? 'gd' : ''}`}>{t.amt}</div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      )}

      {step === 7 && (
        <div className="scrn">
          <div className="s7">
            <div className="s7c">
              {insights ? (() => {
                const cur = insights.currency || currency;
                const { largest, topCategory: top } = insights;
                const subs = insights.subs || [];
                const rows = insights.rows || parseInt(localStorage.getItem('penny_dynamic_total_rows')) || 0;
                return (
                  <>
                    <div className="s7l">
                      {largest && <div className="th1">hmm, <b>{formatMoney(largest.amount, cur)}</b> at {largest.payee}? 👀</div>}
                      {subs.length > 0 && <div className="th2">{subs.length} recurring sub{subs.length > 1 ? 's' : ''} spotted 🧟</div>}
                      {insights.net != null && <div className="th3">net <b>{formatMoney(insights.net, cur)}</b> this period ✨</div>}
                      <PennyAvatar size="lg" mood="thinking" />
                    </div>
                    <div>
                      <div className="s7h">Let me have a quick<br /><em>look at this...</em></div>
                      <div className="s7p">{rows.toLocaleString()} transactions read across your statements — already spotted a few things.</div>
                      <div className="ins">
                        {top && (
                          <div className="in">
                            <div className="ini">{categoryMeta(top.name).icon}</div>
                            <div>
                              <div className="int"><b>{top.name}</b> is your top spend</div>
                              <div className="ind">{formatMoney(top.amount, cur)} across your statements</div>
                            </div>
                          </div>
                        )}
                        {largest && (
                          <div className="in">
                            <div className="ini">💸</div>
                            <div>
                              <div className="int">Largest single payment</div>
                              <div className="ind">{formatMoney(largest.amount, cur)} · {largest.payee}{largest.date ? ` on ${largest.date}` : ''}</div>
                            </div>
                          </div>
                        )}
                        {subs.length > 0 ? (
                          <div className="in">
                            <div className="ini">👻</div>
                            <div>
                              <div className="int">Found <b>{subs.length} recurring sub{subs.length > 1 ? 's' : ''}</b></div>
                              <div className="ind">{subs.map(s => s.name).join(' · ')}</div>
                            </div>
                          </div>
                        ) : (
                          <div className="in">
                            <div className="ini">📊</div>
                            <div>
                              <div className="int">Money in vs out</div>
                              <div className="ind">in {formatMoney(insights.income, cur)} · out {formatMoney(insights.spend, cur)}</div>
                            </div>
                          </div>
                        )}
                      </div>
                      <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
                        <button className="btn lime lg" onClick={handleFinish}>Take me to Penny →</button>
                      </div>
                    </div>
                  </>
                );
              })() : (
                <>
                  <div className="s7l">
                    <div className="th1">hmm, <b>£187</b> on Deliveroo? 👀</div>
                    <div className="th2">3 zombie subs spotted 🧟</div>
                    <div className="th3">your <b>portfolio</b> is up 8% ✨</div>
                    <PennyAvatar size="lg" mood="thinking" />
                  </div>
                  <div>
                    <div className="s7h">Let me have a quick<br /><em>look at this...</em></div>
                    <div className="s7p">Demo preview — upload real statements to see your own numbers here.</div>
                    <div className="ins">
                      <div className="in">
                        <div className="ini">🍔</div>
                        <div>
                          <div className="int">Takeaways up <b>34%</b> this month</div>
                          <div className="ind">£187 on Deliveroo · mostly late-night</div>
                        </div>
                      </div>
                      <div className="in">
                        <div className="ini">👻</div>
                        <div>
                          <div className="int">Found <b>3 zombie subs</b> wasting £34/mo</div>
                          <div className="ind">Audible · FitnessPal · Times+ · all unused</div>
                        </div>
                      </div>
                      <div className="in">
                        <div className="ini">📈</div>
                        <div>
                          <div className="int">Portfolio <span className="gd">+8.2%</span> YTD</div>
                          <div className="ind">VWRL up, GOOGL down, net £1,420 gain</div>
                        </div>
                      </div>
                    </div>
                    <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
                      <button className="btn lime lg" onClick={handleFinish}>Take me to Penny →</button>
                    </div>
                  </div>
                </>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default Landing;

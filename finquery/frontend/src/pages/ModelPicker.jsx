import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import './ModelPicker.css';

const authHeaders = () => {
  const t = localStorage.getItem('token') || localStorage.getItem('penny_token');
  return t ? { Authorization: `Bearer ${t}` } : {};
};

function ModelPicker() {
  const [active, setActive] = useState('');
  const [models, setModels] = useState([]);
  const [busy, setBusy] = useState(null);        // model id currently downloading
  const [progress, setProgress] = useState(0);   // 0..100 for the busy model
  const [status, setStatus] = useState('');      // status line for the busy model
  const [msg, setMsg] = useState('');
  const navigate = useNavigate();

  const [allInstalled, setAllInstalled] = useState(false);

  const load = async () => {
    try {
      const r = await fetch('/api/models', { headers: authHeaders() });
      const d = await r.json();
      setActive(d.active || '');
      setModels(d.recommended || []);
      // If all models are installed, this is a non-Mac platform using Groq
      const recs = d.recommended || [];
      setAllInstalled(recs.length > 0 && recs.every(m => m.installed));
    } catch {
      setMsg('Could not reach the local server.');
    }
  };
  useEffect(() => { load(); }, []);

  const useModel = async (id) => {
    setMsg('');
    try {
      const r = await fetch('/api/models/select', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders() },
        body: JSON.stringify({ name: id }),
      });
      const d = await r.json();
      if (!r.ok) { setMsg(d.error || 'Could not switch model.'); return; }
      setActive(d.active);
      // Choosing a model is a required step — record it, then continue the flow: into the
      // onboarding wizard if the user came from "Let's set up", otherwise straight to the app.
      sessionStorage.setItem('penny_model_confirmed', d.active);
      if (sessionStorage.getItem('penny_setup')) {
        sessionStorage.removeItem('penny_setup');
        navigate('/?step=2');
      } else {
        navigate('/app');
      }
    } catch {
      setMsg('Could not switch model.');
    }
  };

  const download = async (id) => {
    setBusy(id); setProgress(0); setStatus('starting download…'); setMsg('');
    try {
      const res = await fetch('/api/models/pull', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders() },
        body: JSON.stringify({ name: id }),
      });
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = '';
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        const lines = buf.split('\n');
        buf = lines.pop();
        for (const line of lines) {
          if (!line.trim()) continue;
          let ev; try { ev = JSON.parse(line); } catch { continue; }
          if (ev.error) { setMsg(`Download failed: ${ev.error}`); }
          if (ev.status) setStatus(ev.status);
          if (ev.total && ev.completed != null) {
            setProgress(Math.min(100, Math.round((ev.completed / ev.total) * 100)));
          }
          if (ev.status === 'success') setProgress(100);
        }
      }
      await load();
      setStatus('installed ✓');
      setMsg(`${id} downloaded. Tap "Use" to switch to it.`);
    } catch {
      setMsg('Download failed — is Ollama running?');
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="mp-wrap">
      <div className="mp-head">
        <div>
          <div className="mp-title">Choose your AI model<em>.</em></div>
          <div className="mp-sub">
            A required first step — pick the model that powers Penny.{' '}
            {allInstalled
              ? <>Running on <b>Windows</b> — models are served via the <b>Groq cloud API</b>. No download needed. Tap a model to select it.</>
              : <>Everything runs <b>fully offline</b> on your Mac via MLX. Download a model, then tap <b>Use this model</b> to continue.</>
            }
          </div>
        </div>
      </div>

      {active && <div className="mp-active">Active model: <b>{active}</b> — tap "In use ✓ · Continue" to proceed.</div>}

      <div className="mp-grid">
        {models.map((m) => {
          const isActive = active === m.id;
          const downloading = busy === m.id;
          return (
            <div className={`mp-card ${isActive ? 'on' : ''}`} key={m.id}>
              <div className="mp-name">
                {m.name}
                {allInstalled && <span style={{fontSize:'0.65rem', marginLeft:'6px', background:'#6366f1', color:'#fff', borderRadius:'4px', padding:'1px 6px', verticalAlign:'middle'}}>☁ Groq</span>}
              </div>
              <div className="mp-id">{m.id}</div>
              <div className="mp-meta"><span className="mp-size">{m.size}</span><span className="mp-note">{m.note}</span></div>

              {downloading ? (
                <div className="mp-prog">
                  <div className="mp-bar"><div className="mp-fill" style={{ width: `${progress}%` }} /></div>
                  <div className="mp-status">{status} {progress}%</div>
                </div>
              ) : isActive ? (
                <button className="mp-btn on" onClick={() => useModel(m.id)}>In use ✓ · Continue →</button>
              ) : allInstalled ? (
                <button className="mp-btn use" onClick={() => useModel(m.id)}>Select</button>
              ) : m.installed ? (
                <button className="mp-btn use" onClick={() => useModel(m.id)}>Use this model</button>
              ) : (
                <button className="mp-btn dl" disabled={!!busy} onClick={() => download(m.id)}>Download</button>
              )}
            </div>
          );
        })}
      </div>

      {msg && <div className="mp-msg">{msg}</div>}

      <div className="mp-foot">
        <button className="mp-ghost" onClick={() => navigate('/')}>← back to start</button>
        <span className="mp-hint">You must choose a model before opening the app.</span>
      </div>
    </div>
  );
}

export default ModelPicker;

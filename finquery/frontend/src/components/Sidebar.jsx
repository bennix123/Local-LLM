import React, { useState } from 'react';
import PennyAvatar from './PennyAvatar';

const Sidebar = ({ 
  user, 
  onLogout, 
  modelName = 'llama3.1:8b', 
  transactionCount = 2847, 
  runFlow,
  documents = [],
  activeDoc,
  onSelectDoc
}) => {
  const [netOnline, setNetOnline] = useState(false);

  const toggleNet = () => {
    setNetOnline(!netOnline);
  };

  return (
    <aside className="sb">
      <div className="sbb">
        <PennyAvatar size="sm" />
        <div className="sbbn">penny<em>.</em></div>
      </div>

      <div className="sbs">
        <div className="sbh">conversations</div>
        <div className="sbi on">
          <div className="sbic">💬</div>Today's chat
        </div>
        <div className="sbi" onClick={() => onLogout()}>
          <div className="sbic">🚪</div>Sign Out
        </div>
      </div>

      <div className="sbs">
        <div className="sbh">jump to</div>
        <div className="sbi" onClick={() => runFlow('roast')}><div class="sbic">🔥</div>Roast me</div>
        <div className="sbi" onClick={() => runFlow('ghosts')}><div class="sbic">👻</div>Ghosts<span class="sbb-badge">3</span></div>
        <div className="sbi" onClick={() => runFlow('patterns')}><div class="sbic">⚡</div>Patterns<span class="sbb-badge">3</span></div>
        <div className="sbi" onClick={() => runFlow('forecast')}><div class="sbic">⛅</div>Forecast</div>
        <div className="sbi" onClick={() => runFlow('compound')}><div class="sbic">📈</div>Compound math</div>
        <div className="sbi" onClick={() => runFlow('reports')}><div class="sbic">📊</div>Reports</div>
        <div className="sbi" onClick={() => runFlow('splurge')}><div class="sbic">💸</div>Can I splurge?</div>
      </div>

      {documents.length > 0 && (
        <div className="sbs">
          <div className="sbh">statements</div>
          <div className="acls">
            {documents.map((doc, idx) => (
              <div 
                key={idx} 
                className={`acrow ${activeDoc === doc ? 'on' : ''}`}
                onClick={() => onSelectDoc(doc)}
                style={{ background: activeDoc === doc ? 'rgba(0,0,0,0.1)' : '' }}
              >
                <div className="acri">📄</div>
                <div className="acrn" style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                  {doc}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className={`net ${netOnline ? 'online' : 'offline'}`} id="netPanel" style={{ marginTop: 'auto' }}>
        <div className="neth">
          <div className="netl">
            <span className="dot"></span>
            <span id="netLabel">{netOnline ? 'Online when needed' : 'Offline mode'}</span>
          </div>
          <div className={`tgl ${netOnline ? 'on' : ''}`} id="netToggle" onClick={toggleNet}></div>
        </div>
        <div className="netd" id="netDesc">
          {netOnline 
            ? 'Penny stays local, but can fetch public numbers (like stock prices) when a question needs them. Your data never goes out — only anonymous lookups.'
            : 'Penny is fully offline. She\'ll never reach the internet. Some live answers (stock prices) won\'t be available.'}
        </div>
      </div>

      <div className="bp" style={{ marginTop: '12px' }}>
        <div className="bph">PENNY'S BRAIN</div>
        <div className="bpm" style={{ textTransform: 'uppercase' }}>{modelName}</div>
        <div className="bps"><span>RAM in use</span><b>8.2 GB</b></div>
        <div className="bps"><span>Context</span><b>32K tokens</b></div>
        <div className="bps"><span>Transactions</span><b>{transactionCount.toLocaleString()}</b></div>
        <div className="bps"><span>Data sent out</span><b style={{ color: 'var(--lime-d)' }}>0 bytes</b></div>
      </div>
    </aside>
  );
};

export default Sidebar;
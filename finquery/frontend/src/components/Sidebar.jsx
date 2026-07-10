import React, { useState, useRef } from 'react';
import PennyAvatar from './PennyAvatar';
import { uploadDocument } from '../api';
import toast from 'react-hot-toast';

const Sidebar = ({ 
  user, 
  onLogout, 
  modelName = 'Qwen 3 14B', 
  transactionCount = 2847, 
  runFlow,
  documents = [],
  selectedDocs = [],
  onSelectDoc,
  onRefreshDocs
}) => {
  const [netOnline, setNetOnline] = useState(false);
  const [isUploading, setIsUploading] = useState(false);
  const fileInputRef = useRef(null);

  const toggleNet = () => {
    setNetOnline(!netOnline);
  };

  const handleUploadClick = () => {
    if (fileInputRef.current) {
      fileInputRef.current.click();
    }
  };

  const handleFileChange = async (e) => {
    if (e.target.files && e.target.files.length > 0) {
      const file = e.target.files[0];
      setIsUploading(true);
      const uploadToast = toast.loading(`Uploading ${file.name}...`);
      try {
        await uploadDocument(file);
        toast.success(`${file.name} uploaded successfully!`, { id: uploadToast });
        if (onRefreshDocs) {
          onRefreshDocs();
        }
      } catch (error) {
        console.error('Upload failed:', error);
        toast.error(`Failed to upload ${file.name}`, { id: uploadToast });
      } finally {
        setIsUploading(false);
        e.target.value = ''; // Reset input
      }
    }
  };

  // Helper to get matching icon based on document name
  const getDocIcon = (doc) => {
    const name = doc?.doc_name || doc?.bank_name || (typeof doc === 'string' ? doc : '');
    const n = name.toLowerCase();
    if (n.includes('amex') || n.includes('credit') || n.includes('card')) return '💳';
    if (n.includes('vanguard') || n.includes('stock') || n.includes('t212') || n.includes('trade')) return '📈';
    if (n.includes('pension') || n.includes('nest')) return '🏛';
    if (n.includes('crypto') || n.includes('coinbase')) return '🪙';
    return '🏦';
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
        <div className="sbi" onClick={() => {
          if (confirm("Are you sure you want to Sign Out?")) {
            onLogout();
          }
        }}>
          <div className="sbic">🚪</div>Sign Out
        </div>
      </div>

      <div className="sbs">
        <div className="sbh">jump to</div>
        <div className="sbi" onClick={() => runFlow('roast')}><div className="sbic">🔥</div>Roast me</div>
        <div className="sbi" onClick={() => runFlow('ghosts')}><div className="sbic">👻</div>Ghosts<span className="sbb-badge">3</span></div>
        <div className="sbi" onClick={() => runFlow('patterns')}><div className="sbic">⚡</div>Patterns<span className="sbb-badge">3</span></div>
        <div className="sbi" onClick={() => runFlow('forecast')}><div className="sbic">⛅</div>Forecast</div>
        <div className="sbi" onClick={() => runFlow('compound')}><div className="sbic">📈</div>Compound math</div>
        <div className="sbi" onClick={() => runFlow('reports')}><div className="sbic">📊</div>Reports</div>
        <div className="sbi" onClick={() => runFlow('splurge')}><div className="sbic">💸</div>Can I splurge?</div>
      </div>

      <div className="sbs">
        <div className="sbh">accounts</div>
        <div className="acls">
          {documents.map((doc, idx) => {
            const docName = doc?.doc_name || (typeof doc === 'string' ? doc : `Statement ${idx}`);
            const isSelected = selectedDocs.includes(docName);
            return (
              <div 
                key={idx} 
                className={`acrow ${isSelected ? 'on' : ''}`}
                onClick={() => onSelectDoc(docName)}
                style={{ background: isSelected ? 'rgba(0,0,0,0.1)' : '' }}
              >
                <div className="acri">{getDocIcon(doc)}</div>
                <div className="acrn" style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                  {docName}
                </div>
              </div>
            );
          })}
          <div 
            className="acrow" 
            style={{ color: 'var(--dim)', justifyContent: 'center', fontSize: '10.5px', paddingTop: '6px', cursor: isUploading ? 'not-allowed' : 'pointer' }}
            onClick={handleUploadClick}
          >
            {isUploading ? 'Uploading...' : '+ upload more'}
          </div>
          <input 
            type="file" 
            ref={fileInputRef} 
            style={{ display: 'none' }} 
            onChange={handleFileChange}
            accept=".csv,.pdf,.xlsx,.xls"
          />
        </div>
      </div>

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
        <div className="bps"><span>RAM in use</span><b>14.2 GB</b></div>
        <div className="bps"><span>Context</span><b>32K tokens</b></div>
        <div className="bps"><span>Transactions</span><b>{transactionCount.toLocaleString()}</b></div>
        <div className="bps"><span>Data sent out</span><b style={{ color: 'var(--lime-d)' }}>0 bytes</b></div>
      </div>
    </aside>
  );
};

export default Sidebar;
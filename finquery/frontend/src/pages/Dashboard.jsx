import React, { useState, useEffect } from 'react';
import './Dashboard.css';
import toast from 'react-hot-toast';
import Sidebar from '../components/Sidebar';
import ChatArea from '../components/ChatArea';
import InputBar from '../components/InputBar';
import ContextPanel from '../components/ContextPanel';
import { listDocuments, queryDocumentsStream } from '../api';
import { useAuth } from '../context/AuthContext';
import { Navigate, useNavigate } from 'react-router-dom';

function Dashboard() {
  const [documents, setDocuments] = useState([]);
  const [selectedDocs, setSelectedDocs] = useState([]);
  const [messages, setMessages] = useState([]);
  const [isLoading, setIsLoading] = useState(false);
  const [overview, setOverview] = useState({ rows: 0, spend: '—', income: '—', ghosts_count: 0, patterns_count: 0 });
  const [ctx, setCtx] = useState({
    ready: false, currency: 'INR', balance: null,
    spentThisMonth: null, net: null, txnCount: 0, categories: [],
  });
  const { user, logout } = useAuth();
  const navigate = useNavigate();

  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [panelOpen, setPanelOpen] = useState(false);
  const [modelName, setModelName] = useState('local model');
  const [brainStats, setBrainStats] = useState(null);

  const [chips, setChips] = useState([
    { label: '🔥 Roast my spending', action: 'roast' },
    { label: '👻 Banish zombie subs', action: 'ghosts' },
    { label: '⛅ Forecast savings', action: 'forecast' },
    { label: '📈 Compound math', action: 'compound' }
  ]);

  useEffect(() => {
    fetchDocuments();
    fetchStatus();
    fetchDashboard();
  }, []);

  const authHeaders = () => {
    const token = localStorage.getItem('token') || localStorage.getItem('penny_token');
    return token ? { Authorization: `Bearer ${token}` } : {};
  };

  // Rich, currency-aware figures for the Today panel — every number is computed
  // in SQL on-device, so nothing here can be hallucinated.
  const fetchDashboard = async () => {
    try {
      const res = await fetch('/dashboard', { headers: authHeaders() });
      if (!res.ok) return;
      const d = await res.json();
      if (!d.ready) {
        setCtx((c) => ({ ...c, ready: false }));
        return;
      }
      const months = d.months || [];
      const spentThisMonth = months.length
        ? months[months.length - 1].spending
        : (d.totals ? d.totals.spending : null);
      setCtx({
        ready: true,
        currency: d.currency || 'INR',
        balance: d.balance != null ? d.balance : null,
        spentThisMonth,
        net: d.totals ? d.totals.net : null,
        txnCount: d.totals ? d.totals.count : 0,
        categories: (d.categories || []).map((c) => ({ name: c.name, amount: c.amount })),
      });
    } catch (error) {
      console.error('Error fetching dashboard:', error);
    }
  };

  const fetchDocuments = async () => {
    try {
      const data = await listDocuments();
      setDocuments(data.documents || []);
      if (data.active_doc_name) {
        if (Array.isArray(data.active_doc_name)) {
          setSelectedDocs(data.active_doc_name);
        } else {
          setSelectedDocs([data.active_doc_name]);
        }
      }
      fetchDashboard();
      fetchStatus();
    } catch (error) {
      console.error('Error fetching documents:', error);
    }
  };

  const fetchStatus = async () => {
    try {
      const response = await fetch('/status', { headers: authHeaders() });
      const storedTotal = parseInt(localStorage.getItem('penny_dynamic_total_rows')) || 0;
      if (response.ok) {
        const data = await response.json();
        setOverview({
          rows: data.rows || storedTotal,
          spend: data.spend || '—',
          income: data.income || '—',
          ghosts_count: data.ghosts_count != null ? data.ghosts_count : 0,
          patterns_count: data.patterns_count != null ? data.patterns_count : 0,
        });
        if (data.brain_stats) {
          setBrainStats(data.brain_stats);
        }
        if (data.model) {
          let displayName = data.model;
          if (data.model.toLowerCase().includes('llama3.1:8b') || data.model.toLowerCase().includes('llama')) {
            displayName = 'Llama 8B';
          } else if (data.model.toLowerCase().includes('qwen2.5-coder:3b') || data.model.toLowerCase().includes('qwen')) {
            displayName = 'Qwen 3B';
          }
          setModelName(displayName);
        }
      } else {
        setOverview(prev => ({ ...prev, rows: storedTotal }));
      }
    } catch (error) {
      console.error('Error fetching status:', error);
      const storedTotal = parseInt(localStorage.getItem('penny_dynamic_total_rows')) || 0;
      setOverview(prev => ({ ...prev, rows: storedTotal }));
    }
  };

  const handleSelectDoc = async (docName) => {
    try {
      const res = await fetch('/chat/select_bank', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...authHeaders(),
        },
        body: JSON.stringify({ doc_name: docName, thread: 'default' }),
      });
      if (res.ok) {
        const data = await res.json();
        const active = data.active_doc_name;
        let isSelected = false;
        if (Array.isArray(active)) {
          setSelectedDocs(active);
          isSelected = active.includes(docName);
        } else if (active) {
          setSelectedDocs([active]);
          isSelected = active === docName;
        } else {
          setSelectedDocs([]);
          isSelected = false;
        }
        toast.success(isSelected ? `Selected: ${docName}` : `Deselected: ${docName}`);
        fetchDashboard();
        fetchStatus();
      }
    } catch (error) {
      console.error('Error selecting bank:', error);
      toast.error('Failed to select bank');
    }
  };

  const handleSendMessage = async (question, forceLLM = false) => {
    const userMessage = { role: 'user', content: question };
    setMessages((prev) => [...prev, userMessage]);

    const assistantMessage = { role: 'assistant', content: '', sources: [] };
    setMessages((prev) => [...prev, assistantMessage]);
    setIsLoading(true);

    try {
      const docNameParam = selectedDocs.length > 0 ? selectedDocs : null;

      await queryDocumentsStream(
        question,
        docNameParam,
        (token) => {
          setMessages((prev) => {
            const lastMsg = prev[prev.length - 1];
            return [
              ...prev.slice(0, -1),
              { ...lastMsg, content: lastMsg.content + token }
            ];
          });
        },
        (sources) => {
          setMessages((prev) => {
            const lastMsg = prev[prev.length - 1];
            return [
              ...prev.slice(0, -1),
              { ...lastMsg, sources }
            ];
          });
        },
        null, // error callback
        (meta) => {
          setMessages((prev) => {
            const lastMsg = prev[prev.length - 1];
            return [
              ...prev.slice(0, -1),
              { ...lastMsg, path: meta.path }
            ];
          });
        },
        forceLLM
      );
    } catch (error) {
      console.error('Error querying documents:', error);
      setMessages((prev) => {
        const updated = [...prev];
        const lastMsg = updated[updated.length - 1];
        if (!lastMsg.content) {
          lastMsg.content = 'Sorry, I couldn\'t process that question. Please try again.';
        }
        return [...updated];
      });
      toast.error('Failed to get response');
    } finally {
      setIsLoading(false);
      fetchDashboard();   // figures may have changed (new upload / scope switch)
    }
  };

  const handleEditMessage = async (idx, newText) => {
    const baseMessages = messages.slice(0, idx);
    setMessages(baseMessages);
    await handleSendMessage(newText, false);
  };

  const handleRegenerateMessage = async (idx) => {
    const userMsg = messages[idx - 1];
    if (!userMsg || userMsg.role !== 'user') return;
    const baseMessages = messages.slice(0, idx - 1);
    setMessages(baseMessages);
    await handleSendMessage(userMsg.content, true);
  };

  const runFlow = (flowName) => {
    let question = '';
    if (flowName === 'roast') {
      question = 'roast my spending';
    } else if (flowName === 'ghosts') {
      question = 'banish zombie subs';
    } else if (flowName === 'patterns') {
      question = 'key insights';
    } else if (flowName === 'forecast') {
      question = 'forecast my portfolio';
    } else if (flowName === 'compound') {
      question = 'compound my leaks';
    } else if (flowName === 'reports') {
      question = 'show my categorised spending';
    } else if (flowName === 'splurge') {
      question = 'can i splurge?';
    }
    if (question) handleSendMessage(question);
    setSidebarOpen(false); // Close drawer after trigger
  };

  const handleLogout = () => {
    logout();                       // clear token + user
    toast.success('Logged out successfully');
    navigate('/login', { replace: true });   // actually leave the dashboard
  };

  // Choosing an AI model is a mandatory step — you can't use the app without it.
  if (!sessionStorage.getItem('penny_model_confirmed')) {
    return <Navigate to="/models" replace />;
  }

  return (
    <div className="desktop">
      {/* Mobile Backdrop */}
      {(sidebarOpen || panelOpen) && (
        <div 
          className="mobile-backdrop" 
          onClick={() => {
            setSidebarOpen(false);
            setPanelOpen(false);
          }}
        />
      )}

      {/* Sidebar Wrapper */}
      <div className={`sb-wrapper ${sidebarOpen ? 'open' : ''}`}>
        <Sidebar
          documents={documents}
          selectedDocs={selectedDocs}
          onSelectDoc={handleSelectDoc}
          user={user}
          onLogout={handleLogout}
          transactionCount={overview.rows}
          ghostsCount={overview.ghosts_count}
          patternsCount={overview.patterns_count}
          runFlow={runFlow}
          onRefreshDocs={fetchDocuments}
          modelName={modelName}
          brainStats={brainStats}
        />
      </div>

      <div className="cm">
        <div className="ct">
          {/* Mobile Hamburger menu */}
          <button 
            className="mobile-toggle-btn burger" 
            onClick={() => {
              setSidebarOpen(!sidebarOpen);
              setPanelOpen(false);
            }}
          >
            ☰
          </button>
          
          <div className="cti" style={{ display: 'flex', flexDirection: 'column' }}>
            <div className="ctn">penny<em style={{ fontStyle: 'normal', color: 'var(--lime-d)' }}>.</em></div>
            <div className="cts">running locally · ready · {modelName}</div>
          </div>
          
          <div className="cttl" style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
            <button className="ctt" title="New chat" onClick={() => setMessages([])}>+</button>
            {/* Mobile Context Panel toggle */}
            <button 
              className="mobile-toggle-btn stats" 
              onClick={() => {
                setPanelOpen(!panelOpen);
                setSidebarOpen(false);
              }}
            >
              📊
            </button>
          </div>
        </div>

        <ChatArea 
          messages={messages} 
          isLoading={isLoading} 
          runFlow={runFlow} 
          onEdit={handleEditMessage}
          onRegenerate={handleRegenerateMessage}
        />

        <InputBar 
          onSendMessage={handleSendMessage} 
          disabled={isLoading} 
          chips={messages.length > 0 ? [] : chips}
          onChipClick={runFlow}
        />
      </div>

      {/* Context Panel Wrapper */}
      <div className={`cp-wrapper ${panelOpen ? 'open' : ''}`}>
        <ContextPanel
          currency={ctx.currency}
          ready={ctx.ready}
          balance={ctx.balance}
          spentThisMonth={ctx.spentThisMonth}
          net={ctx.net}
          txnCount={ctx.txnCount || overview.rows}
          categories={ctx.categories}
        />
      </div>
    </div>
  );
}

export default Dashboard;
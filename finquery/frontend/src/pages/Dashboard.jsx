import React, { useState, useEffect } from 'react';
import toast from 'react-hot-toast';
import Sidebar from '../components/Sidebar';
import ChatArea from '../components/ChatArea';
import InputBar from '../components/InputBar';
import ContextPanel from '../components/ContextPanel';
import { listDocuments, queryDocumentsStream } from '../api';
import { useAuth } from '../context/AuthContext';

function Dashboard() {
  const [documents, setDocuments] = useState([]);
  const [activeDoc, setActiveDoc] = useState(null);
  const [messages, setMessages] = useState([]);
  const [isLoading, setIsLoading] = useState(false);
  const [overview, setOverview] = useState({ rows: 2847, spend: '£2,148', income: '£3,820' });
  const { user, logout } = useAuth();

  const [chips, setChips] = useState([
    { label: '🔥 Roast my spending', action: 'roast' },
    { label: '👻 Banish zombie subs', action: 'ghosts' },
    { label: '⛅ Forecast savings', action: 'forecast' },
    { label: '📈 Compound math', action: 'compound' }
  ]);

  useEffect(() => {
    fetchDocuments();
    fetchStatus();
  }, []);

  const fetchDocuments = async () => {
    try {
      const data = await listDocuments();
      setDocuments(data.documents || []);
      if (data.active_doc_name) {
        setActiveDoc(data.active_doc_name);
      }
    } catch (error) {
      console.error('Error fetching documents:', error);
    }
  };

  const fetchStatus = async () => {
    try {
      const token = localStorage.getItem('token') || localStorage.getItem('penny_token');
      const response = await fetch('/status', {
        headers: { 'Authorization': `Bearer ${token}` }
      });
      if (response.ok) {
        const data = await response.json();
        setOverview({
          rows: data.rows || 2847,
          spend: data.spend || '£2,148',
          income: data.income || '£3,820'
        });
      }
    } catch (error) {
      console.error('Error fetching status:', error);
    }
  };

  const handleSelectDoc = async (docName) => {
    try {
      const token = localStorage.getItem('token') || localStorage.getItem('penny_token');
      const response = await fetch('/chat/select_bank', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}`
        },
        body: JSON.stringify({ doc_name: docName })
      });
      if (response.ok) {
        setActiveDoc(docName);
        toast.success(`Active statement: ${docName}`);
      }
    } catch (error) {
      console.error('Error selecting document:', error);
    }
  };

  const handleSendMessage = async (question) => {
    const userMessage = { role: 'user', content: question };
    setMessages((prev) => [...prev, userMessage]);

    const assistantMessage = { role: 'assistant', content: '', sources: [] };
    setMessages((prev) => [...prev, assistantMessage]);
    setIsLoading(true);

    try {
      const docNameParam = activeDoc ? [activeDoc] : null;

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
        }
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
    }
  };

  const runFlow = (flowName) => {
    let question = '';
    if (flowName === 'roast') {
      question = 'roast my spending';
    } else if (flowName === 'ghosts') {
      question = 'banish zombie subs';
    } else if (flowName === 'forecast') {
      question = 'give me a spending forecast';
    } else if (flowName === 'compound') {
      question = 'calculate compound savings if I cut back';
    } else if (flowName === 'reports') {
      question = 'show my category report';
    } else if (flowName === 'splurge') {
      question = 'can I splurge this month?';
    } else {
      question = flowName;
    }
    handleSendMessage(question);
  };

  const handleLogout = () => {
    logout();
    toast.success('Logged out successfully');
  };

  return (
    <div className="desktop">
      <Sidebar
        documents={documents}
        activeDoc={activeDoc}
        onSelectDoc={handleSelectDoc}
        user={user}
        onLogout={handleLogout}
        transactionCount={overview.rows}
        runFlow={runFlow}
      />
      <div className="cm">
        <div className="ct">
          <div className="cti">
            <div className="ctn">penny<em style={{ fontStyle: 'normal', color: 'var(--lime-d)' }}>.</em></div>
            <div className="cts">running locally · ready · Llama 8B</div>
          </div>
          <div className="cttl">
            <button className="ctt" title="New chat" onClick={() => setMessages([])}>+</button>
          </div>
        </div>

        <ChatArea 
          messages={messages} 
          isLoading={isLoading} 
          runFlow={runFlow} 
        />

        <InputBar 
          onSendMessage={handleSendMessage} 
          disabled={isLoading} 
          chips={messages.length > 0 ? [] : chips}
          onChipClick={runFlow}
        />
      </div>
      <ContextPanel 
        balance={overview.income ? 8432 : 0} 
        spentThisMonth={2148}
        portfolio={18742}
      />
    </div>
  );
}

export default Dashboard;
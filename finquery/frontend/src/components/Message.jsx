import React from 'react';
import PennyAvatar from './PennyAvatar';

const mdToHtml = (md) => {
  if (!md) return '';
  let t = md;
  
  // Escape HTML
  t = t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  
  // Tables
  const lines = t.split('\n');
  let inTable = false;
  let tableRows = [];
  const processedLines = [];
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.includes('|') && i + 1 < lines.length && lines[i+1].includes('|') && lines[i+1].replace(/[\s:|:-]/g, '') === '') {
      inTable = true;
      const headers = line.split('|').map(c => c.trim()).filter(Boolean);
      tableRows.push(`<thead><tr>${headers.map(h => `<th>${h}</th>`).join('')}</tr></thead><tbody>`);
      i++; // skip separator
      continue;
    }
    
    if (inTable) {
      if (line.includes('|')) {
        const cells = line.split('|').map(c => c.trim()).filter(Boolean);
        tableRows.push(`<tr>${cells.map(c => `<td>${c}</td>`).join('')}</tr>`);
      } else {
        inTable = false;
        tableRows.push('</tbody>');
        processedLines.push(`<table>${tableRows.join('')}</table>`);
        tableRows = [];
        processedLines.push(line);
      }
    } else {
      processedLines.push(line);
    }
  }
  
  if (inTable) {
    tableRows.push('</tbody>');
    processedLines.push(`<table>${tableRows.join('')}</table>`);
  }
  
  t = processedLines.join('\n');
  
  // Bold, italic, inline code
  t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  t = t.replace(/(?<!\*)\*([^*\s][^*]*)\*(?!\*)/g, '<em>$1</em>');
  t = t.replace(/`([^`]+)`/g, '<code>$1</code>');
  t = t.replace(/\n/g, '<br />');
  
  return t;
};

const Message = ({ index, message, onEditMessage, onRegenerate, onFeedback }) => {
  const isUser = message.role === 'user';
  const [isEditing, setIsEditing] = React.useState(false);
  const [editText, setEditText] = React.useState(message.content);
  const [vote, setVote] = React.useState(null);
  const [animateType, setAnimateType] = React.useState(null);

  const triggerPop = (type) => {
    setAnimateType(type);
    setTimeout(() => setAnimateType(null), 300);
  };

  React.useEffect(() => {
    setEditText(message.content);
  }, [message.content]);

  const handleSave = () => {
    if (editText.trim() && editText !== message.content) {
      onEditMessage(index, editText);
    }
    setIsEditing(false);
  };

  const handleCancel = () => {
    setEditText(message.content);
    setIsEditing(false);
  };
  
  return (
    <div className={`msg ${isUser ? 'us' : 'ai'}`}>
      {!isUser && <PennyAvatar size="sm" mood={message.mood || 'happy'} />}
      <div className="bw" style={{ width: isEditing ? '100%' : 'auto' }}>
        {!isUser && message.path && (
          <span style={{
            fontSize: '9px',
            textTransform: 'uppercase',
            letterSpacing: '0.06em',
            background: message.path.toUpperCase() === 'SQL' ? 'var(--lime-s)' : 
                       (message.path.toUpperCase() === 'ML' ? '#ffe2e2' : '#f0f3ff'),
            border: message.path.toUpperCase() === 'SQL' ? '2px solid var(--lime-d)' : 
                    (message.path.toUpperCase() === 'ML' ? '2px solid #ff9b9b' : '2px solid #b8c8ff'),
            color: 'var(--ink)',
            padding: '2px 8px',
            borderRadius: '10px',
            fontWeight: '800',
            display: 'inline-block',
            marginBottom: '6px',
            fontFamily: 'Courier New, monospace'
          }}>
            ⚡ {message.path.toUpperCase()} ENGINE
          </span>
        )}
        
        {isEditing ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '8px', minWidth: '240px', padding: '10px 14px', borderRadius: '15px', background: 'var(--cream2)', border: '1px solid var(--line)' }}>
            <textarea
              value={editText}
              onChange={(e) => setEditText(e.target.value)}
              style={{
                width: '100%',
                minHeight: '60px',
                padding: '8px',
                borderRadius: '8px',
                border: '1px solid var(--line)',
                fontSize: '13px',
                fontFamily: 'inherit',
                resize: 'vertical',
                background: '#fff',
                color: 'var(--ink)'
              }}
              autoFocus
            />
            <div style={{ display: 'flex', gap: '6px', justifyContent: 'flex-end' }}>
              <button
                onClick={handleCancel}
                style={{
                  padding: '4px 10px',
                  fontSize: '11px',
                  borderRadius: '6px',
                  border: '1px solid var(--line)',
                  background: '#fff',
                  cursor: 'pointer',
                  fontWeight: '600'
                }}
              >
                Cancel
              </button>
              <button
                onClick={handleSave}
                style={{
                  padding: '4px 10px',
                  fontSize: '11px',
                  borderRadius: '6px',
                  border: 'none',
                  background: 'var(--lime-d)',
                  color: '#000',
                  fontWeight: '700',
                  cursor: 'pointer'
                }}
              >
                Save & Resubmit
              </button>
            </div>
          </div>
        ) : (
          <div 
            className="bb" 
            dangerouslySetInnerHTML={{ __html: mdToHtml(message.content) }} 
          />
        )}

        {isUser && onEditMessage && !isEditing && (
          <div className="msg-actions" style={{ display: 'flex', justifyContent: 'flex-end', marginTop: '2px', opacity: 0.7 }}>
            <span 
              onClick={() => setIsEditing(true)} 
              style={{ fontSize: '11px', cursor: 'pointer', padding: '2px 4px' }}
              title="Edit query"
            >
              ✏️
            </span>
          </div>
        )}

        {!isUser && onFeedback && (
          <div className="msg-actions" style={{ display: 'flex', gap: '8px', marginTop: '4px', opacity: 0.7 }}>
            <span 
              onClick={() => {
                const newVote = vote === 'like' ? null : 'like';
                setVote(newVote);
                onFeedback(index, newVote);
                triggerPop('like');
              }} 
              style={{ 
                fontSize: '13px', 
                cursor: 'pointer', 
                padding: '2px 4px',
                background: vote === 'like' ? '#dcfce7' : 'transparent',
                borderRadius: '4px',
                border: vote === 'like' ? '1px solid #22c55e' : 'none',
                transform: animateType === 'like' ? 'scale(1.3)' : 'scale(1)',
                transition: 'transform 0.15s ease-in-out',
                display: 'inline-block'
              }}
              title="Like response"
            >
              👍
            </span>
            <span 
              onClick={() => {
                const newVote = vote === 'dislike' ? null : 'dislike';
                setVote(newVote);
                onFeedback(index, newVote);
                triggerPop('dislike');
              }} 
              style={{ 
                fontSize: '13px', 
                cursor: 'pointer', 
                padding: '2px 4px',
                background: vote === 'dislike' ? '#fee2e2' : 'transparent',
                borderRadius: '4px',
                border: vote === 'dislike' ? '1px solid #ef4444' : 'none',
                transform: animateType === 'dislike' ? 'scale(1.3)' : 'scale(1)',
                transition: 'transform 0.15s ease-in-out',
                display: 'inline-block'
              }}
              title="Dislike response"
            >
              👎
            </span>
            {onRegenerate && (
              <span 
                onClick={() => {
                  onRegenerate(index);
                  triggerPop('regenerate');
                }} 
                style={{ 
                  fontSize: '13px', 
                  cursor: 'pointer', 
                  padding: '2px 4px',
                  transform: animateType === 'regenerate' ? 'scale(1.3)' : 'scale(1)',
                  transition: 'transform 0.15s ease-in-out',
                  display: 'inline-block'
                }}
                title="Regenerate response"
              >
                🔄
              </span>
            )}
          </div>
        )}

        {message.meta && <div className="mm">{message.meta}</div>}
      </div>
    </div>
  );
};

export default Message;
export { mdToHtml };
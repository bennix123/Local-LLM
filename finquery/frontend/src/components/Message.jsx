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

const Message = ({ message, index, onEdit, onRegenerate }) => {
  const isUser = message.role === 'user';
  const [isEditing, setIsEditing] = React.useState(false);
  const [editVal, setEditVal] = React.useState(message.content);
  const [liked, setLiked] = React.useState(message.liked || false);
  const [disliked, setDisliked] = React.useState(message.disliked || false);

  const handleSave = () => {
    if (editVal.trim() && editVal !== message.content) {
      onEdit(index, editVal.trim());
    }
    setIsEditing(false);
  };

  const handleLike = () => {
    const newLiked = !liked;
    setLiked(newLiked);
    if (newLiked) setDisliked(false);
    message.liked = newLiked;
    if (newLiked) message.disliked = false;
  };

  const handleDislike = () => {
    const newDisliked = !disliked;
    setDisliked(newDisliked);
    if (newDisliked) setLiked(false);
    message.disliked = newDisliked;
    if (newDisliked) message.liked = false;
  };

  return (
    <div className={`msg ${isUser ? 'us' : 'ai'}`} style={{ position: 'relative' }}>
      {!isUser && <PennyAvatar size="sm" mood={message.mood || 'happy'} />}
      <div className="bw" style={{ width: '100%' }}>
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
          <div style={{ display: 'flex', flexDirection: 'column', gap: '8px', width: '100%' }}>
            <textarea
              className="chat-edit-input"
              value={editVal}
              onChange={(e) => setEditVal(e.target.value)}
              style={{
                width: '100%',
                background: 'var(--bg)',
                border: '1px solid var(--line)',
                color: 'var(--ink)',
                borderRadius: '8px',
                padding: '8px',
                minHeight: '60px',
                resize: 'vertical',
                fontFamily: 'inherit',
                fontSize: 'inherit'
              }}
            />
            <div style={{ display: 'flex', gap: '6px', justifyContent: 'flex-end' }}>
              <button 
                className="btn text-btn" 
                onClick={() => { setIsEditing(false); setEditVal(message.content); }}
                style={{ fontSize: '11px', padding: '4px 8px', background: 'transparent', border: '1px solid var(--line)', color: 'var(--ink)', borderRadius: '6px', cursor: 'pointer' }}
              >
                Cancel
              </button>
              <button 
                className="btn lime" 
                onClick={handleSave}
                style={{ fontSize: '11px', padding: '4px 8px', border: 'none', borderRadius: '6px', cursor: 'pointer' }}
              >
                Save & Resend
              </button>
            </div>
          </div>
        ) : (
          <div 
            className="bb" 
            dangerouslySetInnerHTML={{ __html: mdToHtml(message.content) }} 
          />
        )}

        {message.meta && <div className="mm">{message.meta}</div>}

        {/* Action icons container */}
        <div style={{ display: 'flex', gap: '8px', marginTop: '6px', alignItems: 'center', minHeight: '20px' }}>
          {isUser && !isEditing && (
            <button 
              onClick={() => setIsEditing(true)}
              style={{
                background: 'transparent',
                border: 'none',
                color: 'var(--dim)',
                fontSize: '11px',
                cursor: 'pointer',
                padding: '2px 4px',
                borderRadius: '4px',
                opacity: 0.6
              }}
              onMouseOver={(e) => e.target.style.opacity = 1}
              onMouseOut={(e) => e.target.style.opacity = 0.6}
            >
              ✏️ Edit
            </button>
          )}

          {!isUser && message.content && (
            <div style={{ display: 'flex', gap: '4px' }}>
              <button 
                onClick={handleLike}
                style={{
                  background: liked ? 'rgba(132, 204, 22, 0.15)' : 'transparent',
                  border: 'none',
                  fontSize: '12px',
                  cursor: 'pointer',
                  padding: '2px 6px',
                  borderRadius: '6px',
                  color: liked ? 'var(--lime-d)' : 'var(--dim)',
                  transition: 'all 0.2s'
                }}
              >
                👍
              </button>
              <button 
                onClick={handleDislike}
                style={{
                  background: disliked ? 'rgba(239, 68, 68, 0.15)' : 'transparent',
                  border: 'none',
                  fontSize: '12px',
                  cursor: 'pointer',
                  padding: '2px 6px',
                  borderRadius: '6px',
                  color: disliked ? '#ef4444' : 'var(--dim)',
                  transition: 'all 0.2s'
                }}
              >
                👎
              </button>
              <button 
                onClick={() => onRegenerate(index)}
                style={{
                  background: 'transparent',
                  border: 'none',
                  fontSize: '12px',
                  cursor: 'pointer',
                  padding: '2px 6px',
                  borderRadius: '6px',
                  color: 'var(--dim)',
                  transition: 'all 0.2s'
                }}
                title="Regenerate with LLM"
                onMouseOver={(e) => e.target.style.transform = 'rotate(180deg)'}
                onMouseOut={(e) => e.target.style.transform = 'none'}
              >
                🔄
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};

export default Message;
export { mdToHtml };
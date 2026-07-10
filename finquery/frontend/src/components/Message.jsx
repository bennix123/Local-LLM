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

const Message = ({ message }) => {
  const isUser = message.role === 'user';
  
  return (
    <div className={`msg ${isUser ? 'us' : 'ai'}`}>
      {!isUser && <PennyAvatar size="sm" mood={message.mood || 'happy'} />}
      <div className="bw">
        <div 
          className="bb" 
          dangerouslySetInnerHTML={{ __html: mdToHtml(message.content) }} 
        />
        {message.meta && <div className="mm">{message.meta}</div>}
      </div>
    </div>
  );
};

export default Message;
export { mdToHtml };
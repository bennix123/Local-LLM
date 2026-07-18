import React, { useRef, useEffect } from 'react';
import Message from './Message';

const ChatArea = ({ messages, isLoading, runFlow, onEdit, onRegenerate }) => {
  const messagesEndRef = useRef(null);

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  useEffect(() => {
    scrollToBottom();
  }, [messages]);

  return (
    <div className="cb" style={{ flex: 1, display: 'flex', flexDirection: 'column', overflowY: 'auto' }}>
      {messages.length === 0 ? (
        <div id="qsg" className="qsg" style={{ marginTop: 'auto', marginBottom: 'auto' }}>
          <div className="qs roast" onClick={() => runFlow('roast')}>
            <div className="qse">🔥</div>
            <div className="qsh">Roast me</div>
            <div className="qsp">Brutal honesty about your spending.</div>
          </div>
          <div className="qs ghosts" onClick={() => runFlow('ghosts')}>
            <div className="qse">👻</div>
            <div className="qsh">Banish zombie subs</div>
            <div className="qsp">Find recurring subs you forgot you had.</div>
          </div>
          <div className="qs forecast" onClick={() => runFlow('forecast')}>
            <div className="qse">📊</div>
            <div className="qsh">Portfolio right now</div>
            <div className="qsp">Live value · needs a price check.</div>
          </div>
          <div className="qs compound" onClick={() => runFlow('compound')}>
            <div className="qse">📈</div>
            <div className="qsh">Compound my savings</div>
            <div className="qsp">If I fix the leaks, what's it worth?</div>
          </div>
        </div>
      ) : (
        <>
          {messages.map((message, index) => (
            <Message 
              key={index} 
              index={index}
              message={message} 
              onEdit={onEdit}
              onRegenerate={onRegenerate}
            />
          ))}
          {isLoading && (
            <div className="typ">
              <div className="typb">
                <span></span>
                <span></span>
                <span></span>
              </div>
            </div>
          )}
        </>
      )}
      <div ref={messagesEndRef} />
    </div>
  );
};

export default ChatArea;
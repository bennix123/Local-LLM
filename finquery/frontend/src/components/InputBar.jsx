import React, { useState } from 'react';

const InputBar = ({ onSendMessage, disabled, chips = [], onChipClick }) => {
  const [input, setInput] = useState('');

  const handleSubmit = (e) => {
    e.preventDefault();
    if (input.trim() && !disabled) {
      onSendMessage(input);
      setInput('');
    }
  };

  const handleKeyDown = (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      handleSubmit(e);
    }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column' }}>
      {chips.length > 0 && (
        <div className="chips">
          {chips.map((chip, idx) => (
            <button 
              key={idx} 
              className="chip"
              onClick={() => onChipClick(chip.action || chip.label)}
            >
              {chip.label}
            </button>
          ))}
        </div>
      )}
      <div className="ciw">
        <form onSubmit={handleSubmit} className="ci">
          <input
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="ask penny anything... e.g. why am i broke?"
            disabled={disabled}
            autoComplete="off"
          />
          <button 
            type="submit" 
            className="sb-btn"
            disabled={disabled || !input.trim()}
          >
            →
          </button>
        </form>
      </div>
    </div>
  );
};

export default InputBar;
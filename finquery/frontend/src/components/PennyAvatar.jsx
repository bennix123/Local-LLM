import React from 'react';

const PennyAvatar = ({ size = 'sm', mood = 'happy', wave = false }) => {
  const sizeClass = `p ${size}`;
  const moodClass = mood !== 'happy' ? mood : '';
  const waveEl = (size === 'xl' || wave) ? <div className="h">👋</div> : null;

  return (
    <div className={`${sizeClass} ${moodClass}`}>
      <div className="body"></div>
      <div className="eye l"></div>
      <div className="eye r"></div>
      <div className="ck l"></div>
      <div className="ck r"></div>
      <div className="m"></div>
      {waveEl}
    </div>
  );
};

export default PennyAvatar;

import React from 'react';

const ContextPanel = ({ 
  balance = 8432, 
  spentThisMonth = 2148, 
  portfolio = 18742,
  spendCategories = [
    { name: 'Food & Dining', icon: '🍔', pct: 45, amt: '£966', fill: 'var(--coral)' },
    { name: 'Bills & Utilities', icon: '⚡', pct: 28, amt: '£601', fill: 'var(--sky)' },
    { name: 'Shopping', icon: '🛍', pct: 15, amt: '£322', fill: 'var(--peach)' },
    { name: 'Travel', icon: '🚇', pct: 8, amt: '£171', fill: 'var(--plum)' },
    { name: 'Subscriptions', icon: '🎵', pct: 4, amt: '£88', fill: 'var(--lime)' }
  ]
}) => {
  return (
    <aside className="cp">
      <div className="cpt">
        <div>
          <div className="cptt">Today</div>
          <div className="cptm">2,847 transactions · on-device</div>
        </div>
      </div>
      <div className="cpb">
        <div className="cpc">
          <div className="cpsl">total balance</div>
          <div className="cpsv">£{balance.toLocaleString()}</div>
          <div className="cpsx">across all accounts</div>
        </div>
        <div className="cpc">
          <div className="cpsl">spent · this month</div>
          <div className="cpsv warn">£{spentThisMonth.toLocaleString()}</div>
          <div className="cpsx">on-device parsed</div>
        </div>
        <div className="cpc">
          <div className="cpsl">portfolio</div>
          <div className="cpsv gd">£{portfolio.toLocaleString()}</div>
          <div className="cpsx">+8.2% YTD · £1,420 gain</div>
        </div>

        <div className="cpc">
          <div className="cph">spending by category</div>
          {spendCategories.map((cat, idx) => (
            <div className="cpbar" key={idx}>
              <div className="cpbi">{cat.icon}</div>
              <div className="cpbn">{cat.name}</div>
              <div className="cpbb">
                <div className="cpbf" style={{ width: `${cat.pct}%`, backgroundColor: cat.fill }}></div>
              </div>
              <div className="cpba">{cat.amt}</div>
            </div>
          ))}
        </div>
      </div>
    </aside>
  );
};

export default ContextPanel;

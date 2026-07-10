import React from 'react';
import { formatMoney, categoryMeta } from '../format';

// Right-hand "Today" panel. Every figure is driven by the /dashboard endpoint
// (all numbers computed in SQL on-device) and formatted in the statement's own
// currency — nothing here is hardcoded to £ or a fixed set of categories.
const ContextPanel = ({
  currency = 'INR',
  ready = false,
  balance = null,
  spentThisMonth = null,
  net = null,
  txnCount = 0,
  categories = [],   // [{ name, amount }] — amount is spend (positive) per category
}) => {
  const spendCats = categories.filter((c) => Math.abs(c.amount || 0) > 0);
  const total = spendCats.reduce((s, c) => s + Math.abs(c.amount || 0), 0);
  const bars = spendCats.slice(0, 6).map((c) => {
    const amt = Math.abs(c.amount || 0);
    const meta = categoryMeta(c.name);
    return {
      name: c.name,
      icon: meta.icon,
      fill: meta.fill,
      pct: total > 0 ? Math.round((amt / total) * 100) : 0,
      amt: formatMoney(amt, currency),
    };
  });

  const money = (v) => (ready && v != null ? formatMoney(v, currency) : '—');

  return (
    <aside className="cp">
      <div className="cpt">
        <div>
          <div className="cptt">Today</div>
          <div className="cptm">
            {ready
              ? `${(txnCount || 0).toLocaleString()} transactions · on-device`
              : 'on-device · upload a statement to begin'}
          </div>
        </div>
      </div>
      <div className="cpb">
        <div className="cpc">
          <div className="cpsl">total balance</div>
          <div className="cpsv">{money(balance)}</div>
          <div className="cpsx">latest statement balance</div>
        </div>
        <div className="cpc">
          <div className="cpsl">spent · this month</div>
          <div className="cpsv warn">{money(spentThisMonth)}</div>
          <div className="cpsx">on-device parsed</div>
        </div>
        <div className="cpc">
          <div className="cpsl">net · income − spend</div>
          <div className={`cpsv ${net != null && net < 0 ? 'warn' : 'gd'}`}>{money(net)}</div>
          <div className="cpsx">across loaded statements</div>
        </div>

        {bars.length > 0 && (
          <div className="cpc">
            <div className="cph">spending by category</div>
            {bars.map((cat, idx) => (
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
        )}
      </div>
    </aside>
  );
};

export default ContextPanel;

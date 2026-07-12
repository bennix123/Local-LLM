// Currency-aware formatting for the UI.
//
// This mirrors the backend money formatter in
//   backend/src/services/txn_store/formatters.py :: format_money()
// so the frontend NEVER hardcodes a currency symbol or a fixed number of
// decimals. The active currency is detected from the uploaded statement on the
// backend (GBP £, INR ₹, USD $, EUR €, Gulf 3-decimal currencies, ...) and sent
// to the client, which formats every figure the same way the server would.

const CURRENCY_SYMBOL = {
  INR: '₹', GBP: '£', USD: '$', EUR: '€',
  OMR: 'OMR ', KWD: 'KWD ', BHD: 'BHD ', JOD: 'JOD ', IQD: 'IQD ',
  '': '',
};

// Gulf currencies quote 3 decimals (fils); everyone else uses 2.
const THREE_DECIMALS = new Set(['OMR', 'KWD', 'BHD', 'JOD', 'IQD']);

export function currencySymbol(cur) {
  const c = (cur || '').toUpperCase();
  return CURRENCY_SYMBOL[c] !== undefined ? CURRENCY_SYMBOL[c] : (c ? c + ' ' : '');
}

// Indian lakh/crore grouping: 12,34,567  (mirrors _group_indian in Python).
function groupIndian(intPart) {
  if (intPart.length <= 3) return intPart;
  const tail = intPart.slice(-3);
  let head = intPart.slice(0, -3);
  const groups = [];
  while (head.length > 2) {
    groups.unshift(head.slice(-2));
    head = head.slice(0, -2);
  }
  if (head) groups.unshift(head);
  return groups.join(',') + ',' + tail;
}

// Format a raw number in a SPECIFIC currency. Undefined/NaN -> em dash, so a
// missing figure never renders as "£NaN".
export function formatMoney(n, cur) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '—';
  const currency = (cur || '').toUpperCase();
  const neg = Number(n) < 0;
  const decPlaces = THREE_DECIMALS.has(currency) ? 3 : 2;
  const [intPart, dec] = Math.abs(Number(n)).toFixed(decPlaces).split('.');
  const grouped = currency === 'INR' ? groupIndian(intPart)
                                     : Number(intPart).toLocaleString('en-US');
  return (neg ? '-' : '') + currencySymbol(currency) + grouped + '.' + dec;
}

// Icon + bar colour for a spending category. Keyed by substring so it survives
// whatever exact label the categorizer produces (e.g. "Food & Dining",
// "Investment & Insurance", "Bills & Utilities").
const CATEGORY_META = [
  { keys: ['food', 'dining', 'restaurant'], icon: '🍔', fill: 'var(--coral)' },
  { keys: ['grocer'],                       icon: '🛒', fill: 'var(--lime)'  },
  { keys: ['bill', 'utilit'],               icon: '⚡', fill: 'var(--sky)'   },
  { keys: ['shop'],                         icon: '🛍', fill: 'var(--peach)' },
  { keys: ['transport', 'travel', 'fuel'],  icon: '🚇', fill: 'var(--plum)'  },
  { keys: ['subscription', 'entertain'],    icon: '🎵', fill: 'var(--lime)'  },
  { keys: ['health', 'medical', 'pharma'],  icon: '💊', fill: 'var(--coral)' },
  { keys: ['invest', 'insurance'],          icon: '📈', fill: 'var(--sky)'   },
  { keys: ['income', 'salary'],             icon: '💰', fill: 'var(--lime)'  },
  { keys: ['transfer'],                     icon: '🔄', fill: 'var(--plum)'  },
  { keys: ['cash', 'atm'],                  icon: '💵', fill: 'var(--lime)'  },
  { keys: ['rent', 'housing'],              icon: '🏠', fill: 'var(--peach)' },
];
const CATEGORY_FALLBACK = { icon: '💳', fill: 'var(--peach)' };

export function categoryMeta(name) {
  const low = (name || '').toLowerCase();
  for (const m of CATEGORY_META) {
    if (m.keys.some((k) => low.includes(k))) return { icon: m.icon, fill: m.fill };
  }
  return CATEGORY_FALLBACK;
}

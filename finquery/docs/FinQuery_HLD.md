# FinQuery — How It Works

*A walkthrough of what we're building and the thinking behind it. Written to be
readable whether or not you're technical — the plain-English explanation comes first,
and a few "under the hood" boxes go a layer deeper for anyone who wants it.*

---

## The gist

FinQuery is a private assistant for your bank statements. You hand it a statement,
then ask questions the way you'd ask a person:

> *"How much did I spend on groceries in July?"*
> *"Which merchant did most of my money go to last year?"*
> *"How many times did I pay Netflix?"*

It answers in seconds, with the exact figure, laid out cleanly.

What makes it different from a regular chatbot comes down to one rule we built the
whole thing around: **the AI is allowed to understand your question, but it is never
allowed to make up a number.** Every amount it shows you is calculated straight from
your own data. We'll come back to *why* that matters and *how* we guarantee it,
because it's really the centre of the design.

And it runs on your own device. Your statements don't get uploaded to anyone's
servers.

---

## Why we built it this way

By now everyone's used an AI chatbot, and they're impressive. But they share a
well-known flaw: when one doesn't actually know something, it tends to *guess*, and it
says the guess with complete confidence. The industry word for this is
"hallucination."

For casual chat, a confident wrong answer is no big deal. For money, it's a
non-starter. Picture asking "how much did I spend last year?" and getting a number
that's quietly off by a lakh, delivered so smoothly you'd never think to double-check.
That one risk is what keeps most people from trusting AI with their finances, and
honestly they're right to be cautious.

So we drew a hard line early on: **the AI does the listening. It never does the
maths.**

---

## The core idea, in one picture

The simplest way to picture FinQuery is a **calculator with a friendly voice on top.**

```
   You ask, in plain English        The assistant figures out
   "How much on groceries     ──▶   WHAT you're actually asking
    in July?"                                  │
                                               ▼
                                    It hands the real sum to a
                                    calculator that reads your
                                    actual statement
                                               │
                                               ▼
                                    Out comes the EXACT figure
                                    ₹12,19,322.34
```

The "voice" is the clever part that copes with messy, everyday questions: typos, short
follow-ups, even a mix of Hindi and English. The "calculator" is a plain, reliable
lookup into your real data. The two never swap jobs. The voice can't invent a number,
and the calculator doesn't need to understand language.

That's the whole trick. A friendly conversation, with none of the made-up-figure risk.

> **Under the hood.** That "calculator" is a deterministic database layer (we call it
> the *Penny* layer). When you ask anything involving a number — a total, a count, a
> comparison — the system turns it into a precise database query (SQL) and returns the
> result. *Deterministic* just means the same question always gives the same, correct
> answer. The language model never sees a chance to "improvise" a figure.

---

## What you can actually ask

A flavour of what it handles today:

- Totals and balances — *"What's my total spending?"*, *"What did I earn last year?"*
- By shop or service — *"How much went to Amazon?"*, *"How many Swiggy orders?"*
- By category — *"How much on healthcare?"*, *"What % goes to investments?"*
- By time — *"Spending in March 2024?"*, *"Which month was my priciest?"*
- Comparisons — *"Did I spend more on shopping or groceries, and by how much?"*
- Follow-ups — ask *"how much at Netflix?"*, then just *"…and in 2025?"* and it keeps
  the thread.

It's built for scale, too. We've tested it on a statement with over a **lakh of
transactions** (1,05,000) and it stays fast and precise.

---

## What happens when you ask a question

Here's the journey of a single question, start to finish. In plain terms first, with
the technical names alongside.

1. **It listens.** Your question comes in along with the recent chat, so short
   follow-ups make sense in context.
2. **Quick safety checks.** Empty message? Nonsense punctuation? Asking for an opinion
   rather than a fact? Each is handled sensibly before anything else runs.
3. **It tries the calculator first.** If you're after a number, it goes straight to the
   data and computes the exact answer. No AI guessing is involved at all, and this is
   the most common path by far.
4. **It calls in the AI only when needed.** For fuzzier or more conversational
   questions, the language model steps in *purely to work out what you meant* — and the
   calculator still produces the actual figure.
5. **It answers neatly.** The reply comes back in proper Indian rupee formatting
   (₹12,19,322.34), with tables where they help, streamed word by word, and saved to
   your history.

> **Under the hood — the layers a question can pass through:**
>
> ```
>   Your question
>        │
>        ▼
>   ┌──────────────┐   first: handle empties, gibberish, and
>   │ Guards +     │   "advice" phrasing; remember the chat thread
>   │ context      │
>   └──────┬───────┘
>          ▼
>   ┌──────────────┐   the common path: money/count/compare
>   │ Deterministic│   questions resolved as exact SQL — no AI
>   │ SQL ("Penny")│
>   └──────┬───────┘
>          ▼
>   ┌──────────────┐   only if still unclear: a LOCAL language
>   │ LLM router   │   model classifies intent (it never emits a number)
>   └──────┬───────┘
>          ▼
>   ┌──────────────┐   for "find that transaction where…" type
>   │ Hybrid search│   lookups over transaction text
>   └──────────────┘
> ```
>
> The router runs **Llama 3.1 (8B) locally via Ollama** — no internet, no external AI
> service. Resolving common money questions *before* the model is even consulted also
> makes them noticeably faster.

The one sentence to carry away: **the only thing that ever produces a number is the
calculator reading your real statement.**

---

## Why the numbers can be trusted

This is worth stating plainly, because it's the entire point.

The AI in FinQuery is deliberately given **no authority to output figures.** Its job
ends at understanding your question. Every amount, count, and percentage is computed by
looking up your actual transactions. Because of that:

- The answers are **exact**, not estimates.
- They're **repeatable** — ask the same thing tomorrow, get the same correct figure.
- They're **auditable** — for any answer, we can point to the exact query behind it.

So even in the rare case the AI misreads a vague question, the worst that can happen is
it answers a slightly different question. It can't hand you a wrong amount.

---

## How we know it's accurate (and not just claiming it)

Any vendor can *say* their tool is accurate. We wanted it measured.

So we built a verification suite: **1,000 real questions** spanning every angle — by
shop, category, month, year, totals, comparisons, rankings — and we worked out the
correct answer to each one straight from the data. Then we run the assistant against
that list and compare, automatically.

Two findings from our latest full run are worth sharing honestly:

- **It never returned a wrong number.** Not once across the 1,000 questions. Where it
  answered, the figure was exact. That's the deterministic design doing its job.
- **It correctly understood and answered about 85% of them on the first pass.** The
  misses weren't bad maths — they were phrasings it didn't yet recognise (for example,
  a few merchant names written as two words, or an unusual way of asking for an
  average). Those are comprehension gaps we're steadily closing, and each fix is easy
  to verify against the same 1,000-question list.

That test set is something we can hand over so you can spot-check it yourself. Nothing
is hidden.

---

## Your data stays with you

This is private by design, not as an afterthought.

- Your statements live in a small local database **on your own device**, not on the
  internet.
- The AI model runs **on the device, offline** — your information isn't sent to any
  outside AI service.
- It works with **no internet connection.**
- It never asks for your bank login or passwords. It only needs the statement file you
  give it.

Think of it like a private notebook you keep in your pocket, not a service you hand
your finances over to.

> **Under the hood.** Data sits in a local **SQLite** database. The transactions table
> stores each row with its date split into separate year / month / day fields, which is
> what makes date-scoped questions ("in March 2024", "on the 27th") both fast and
> exact. The search index and the language model are local too, so the whole query path
> can run with the network switched off.

---

## A bit more it can do

Beyond answering questions, the assistant quietly looks for patterns worth knowing
about:

- **Flags unusual transactions** — a payment far larger than your normal ones.
- **Spots recurring payments** — subscriptions and EMIs that repeat each month.
- **Estimates where spending is heading** — a simple forecast from your history.
- **Sorts transactions into categories** automatically.

> **Under the hood.** These use established, dependable machine-learning techniques
> from the **scikit-learn** library (Isolation Forest for anomalies, clustering for
> recurring payments, regression for the forecast) — all running locally on your own
> data, not guesswork from a chatbot.

---

## What it deliberately does *not* do

Being upfront about the boundaries matters:

- It **won't give personalised investment advice.** Ask "should I buy this stock?" and
  it politely explains it isn't a licensed advisor. It sticks to facts about *your*
  money.
- It **won't move money** — no payments, transfers, or trades. It's read-only.
- If you ask about a shop that isn't in your statement, it says so rather than inventing
  an answer.

---

## What it's built with

For the technically minded, the short version of the stack:

| Part | What we use |
|------|-------------|
| The service that ties it together | Python with FastAPI |
| Where your data lives | SQLite (local), plus a local search index |
| The "understanding" AI | Llama 3.1 8B, running locally through Ollama |
| Pattern-spotting / insights | scikit-learn |
| Finding relevant records | Hybrid search (meaning-based + keyword) |
| What you see | A web interface (React) |

Nothing in that list phones home. Every piece can run on the device.

---

## How you'll see it

- **For this review:** we've put the assistant behind a temporary web link, so you can
  open it in any browser and try it yourself — no install needed.
- **For the finished product:** the goal is to have everything run on a phone, fully
  self-contained — the assistant, your data, and the search, all local, with nothing
  leaving the device.

---

## Where this is heading

A rough map of what's next:

1. Support for more banks' statement layouts (HDFC, SBI, ICICI, and so on).
2. Closing the remaining comprehension gaps from our test suite, towards near-perfect
   coverage.
3. A richer insights view — trends, simple budgets, alerts.
4. Conversation memory that carries across sessions.
5. Packaging it all up neatly for the phone.

---

## A few words you might come across

- **AI / language model (LLM)** — the part that understands your everyday question.
- **Hallucination** — when an AI confidently gives a made-up answer. (Preventing this
  for numbers is the whole point of the design.)
- **Deterministic** — always gives the same, exact result for the same input.
- **SQL** — the standard language for asking precise questions of a database.
- **Offline / on-device** — everything runs on your own phone or computer, with no
  internet and no data sent away.

---

*This is an overview for discussion. The features and figures reflect what's built and
measured today; we'll lock the final scope together before the next stage.*

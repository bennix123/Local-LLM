#!/usr/bin/env python3
"""
Interactive chat with Penny over the Paytm statement (brief §32-33 final test).

  ../../.venv-mlx/bin/python chat.py            # interactive REPL
  ../../.venv-mlx/bin/python chat.py --demo     # runs a scripted multi-turn conversation
  ../../.venv-mlx/bin/python chat.py --trace     # also print resolver trace + memory state

REPL commands:  /state  (show entity memory)   /reset  (clear focus)   /quit
"""
import os, sys, argparse
from penny_memory import PennyAgent, CTX_ADAPTER

DEMO = [
    "What was the largest transaction in the statement?",
    "When did it happen?",
    "Who was it from?",
    "What was the balance right after it?",
    "What was the transaction before it?",
    "How much was that one?",
    "Now what was the largest debit?",
    "Go back to the first transaction we discussed — what was its transaction ID?",
    "By the way, what's the interest rate on the account?",
    "And the closing balance of the whole statement?",
    "Forget all that. What was the amount of that transaction?",   # should ask to clarify
    "What happened on 07 Jan 2023?",
]

def run_turn(ag, q, trace):
    r = ag.ask(q, max_tokens=64)
    print(f"\n\033[1mYou:\033[0m {q}")
    print(f"\033[36mPenny:\033[0m {r['answer']}")
    if trace:
        print(f"       \033[90m[resolved={r['resolved_kind']} via {r.get('note')} "
              f"target={r.get('target')} | state={r.get('state_after', r.get('state_before'))}]\033[0m")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--trace", action="store_true")
    ap.add_argument("--base", action="store_true", help="use the plain base model (no context-LoRA)")
    ap.add_argument("--adapter", default=None, help="path to a LoRA adapter (defaults to the context-LoRA)")
    args = ap.parse_args()
    adapter = None if args.base else (args.adapter or (CTX_ADAPTER if os.path.isdir(CTX_ADAPTER) else None))
    stack = "context-LoRA + memory (full stack)" if adapter else "base model + memory"
    print(f"Loading Penny [{stack}]…")
    ag = PennyAgent(adapter_path=adapter)
    ag._ensure_llm()
    print("Ready. Ask about the Paytm statement.\n")

    if args.demo:
        for q in DEMO:
            run_turn(ag, q, True)
        return

    while True:
        try:
            q = input("\nYou: ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not q: continue
        if q == "/quit": break
        if q == "/state": print("  memory:", ag.mem.state()); continue
        if q == "/reset": ag.mem.reset(); print("  (focus cleared)"); continue
        run_turn(ag, q, args.trace)

if __name__ == "__main__":
    main()

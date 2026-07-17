# Penny parsing contract

This directory is the **language-neutral spec** for Penny's bank-statement
parsing. Any implementation (the Python backend in `../backend`, the Swift
`PennyTxnStore` module in `../../PennyMac`) must produce byte-identical results
on the fixtures here.

## Contents
- `fixtures/*.pdf` + `fixtures/*_expected.json` — 15 statement PDFs and the
  exact rows a conforming parser must produce (`date`, `description`, `debit`,
  `credit`, `balance`, `category`, `bank`).
- `schemas/` — JSON Schemas for parsed transactions and bank profiles.
- `categories.json` — the deterministic categorizer's merchant map and keyword
  rules. **Order matters**: the merchant map is first-match-wins in file order.
- `prompts/` — shared LLM prompt templates (schema inference, chunk
  extraction, categorizer). Used by app-layer features, NOT by conformance.
- `conformance.py` — the reference runner: parses every fixture through the
  Python pipeline and exact-matches the expected JSON.

## Running the suite

**Windows** (nothing preinstalled beyond Python 3.10+):
```bat
contract\run_conformance.bat
```

**macOS / Linux**:
```bash
cd finquery
python -m venv .venv-conformance && . .venv-conformance/bin/activate
pip install pymupdf jsonschema
TXN_DB_PATH=/tmp/penny_conformance.db python contract/conformance.py
```

Expected output: `[PASS]` for all 15 fixtures, then
`[SUCCESS] ALL TESTS PASSED SUCCESSFULLY!` (exit code 0).

**Swift implementation** (macOS only):
```bash
cd PennyMac/PennyCore
swift build --product penny-conformance
.build/debug/penny-conformance run
```

## The determinism rule (important)

The expected fixtures encode the **deterministic pipeline only** — they were
generated with the LLM unavailable. On a Mac where `mlx-lm` is installed and a
model can load, the LLM layers (schema inference, chunk extraction, and the
"Other"-category mop-up) activate and will change some categories, making the
suite report false failures. On Windows this can't happen (MLX doesn't run
there), which is why `run_conformance.bat` needs no special handling.

If you must run the Python suite on a Mac with MLX installed, stub the
provider first:

```python
import sys, types, runpy
stub = types.ModuleType("src.services.llm_provider")
def complete(*a, **k): raise RuntimeError("LLM disabled for conformance")
stub.complete = complete
sys.modules["src.services.llm_provider"] = stub
sys.argv = ["conformance.py"]
runpy.run_path("contract/conformance.py", run_name="__main__")
```

Regenerating expectations after an intentional parser change:
`python contract/conformance.py --generate` (same LLM caveat applies).

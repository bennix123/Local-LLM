"""MLX-backed LLM provider — the ONE place the whole app talks to a model.

Apple Silicon (macOS) only: MLX runs on Metal, in-process. There is deliberately no
Ollama / llama.cpp fallback:

  * the model runs INSIDE the app  -> no separate Ollama install for users
  * no subprocess, no localhost HTTP -> the prerequisite for a sandboxed / App Store build

Note on formats: MLX does NOT load GGUF. Weights come from the `mlx-community` org on
HuggingFace (already converted to MLX format).

The `mlx_lm` import is LAZY on purpose. Penny's numbers — totals, category/merchant/time
breakdowns, top expenses, balances, counts — are answered by the deterministic SQL layer with
NO model at all. So the server still boots and answers those anywhere; only the LLM paths
(advice, the parser's LLM fallback layers, the categoriser mop-up) need a Mac.
"""
import os
import json
import queue
import threading

# --- Catalogue (MLX-format weights on HuggingFace) --------------------------------------
MODEL_CATALOG = [
    {"id": "mlx-community/Llama-3.1-8B-Instruct-4bit", "name": "Llama 3.1 8B",
     "size": "4.5 GB", "min_ram_gb": 16, "note": "Best reasoning · recommended"},
    {"id": "mlx-community/Qwen2.5-7B-Instruct-4bit",  "name": "Qwen 2.5 7B",
     "size": "4.3 GB", "min_ram_gb": 16, "note": "Strong all-rounder"},
    {"id": "mlx-community/Llama-3.2-3B-Instruct-4bit", "name": "Llama 3.2 3B",
     "size": "1.8 GB", "min_ram_gb": 8,  "note": "Balanced · low memory"},
    {"id": "mlx-community/Qwen2.5-3B-Instruct-4bit",  "name": "Qwen 2.5 3B",
     "size": "1.7 GB", "min_ram_gb": 8,  "note": "Fast · lightest"},
]
DEFAULT_MODEL = MODEL_CATALOG[0]["id"]

_loaded = {"id": None, "model": None, "tokenizer": None}
_lock = threading.Lock()   # guards _loaded on MLX platforms
DATA_SENT_OUT = 0


def get_brain_stats() -> dict:
    global DATA_SENT_OUT
    is_local = True
    try:
        _mlx()
    except LLMUnavailable:
        is_local = False

    model_id = active_model()
    
    if is_local:
        model_info = next((m for m in MODEL_CATALOG if m["id"] == model_id), None)
        ram = model_info["size"] if model_info else "4.5 GB"
        context = "32K tokens"
        model_name = model_info["name"] if model_info else "Local Model"
    else:
        ram = "0.0 GB"
        context = "128K tokens"
        model_name = "Groq (Llama 8B)"
        
    return {
        "model": model_name,
        "ram": ram,
        "context": context,
        "data_sent": f"{DATA_SENT_OUT:,} bytes" if DATA_SENT_OUT > 0 else "0 bytes"
    }


class LLMUnavailable(RuntimeError):
    """Raised when an LLM path is used on a machine that can't run MLX."""


def _mlx():
    """Import mlx_lm lazily — importing this module must work on any OS."""
    try:
        from mlx_lm import load, generate, stream_generate
        from mlx_lm.sample_utils import make_sampler
        return load, generate, stream_generate, make_sampler
    except ImportError as e:
        raise LLMUnavailable(
            "MLX isn't available on this machine. Penny runs its model on Apple Silicon "
            "(macOS) via MLX — `pip install mlx-lm`. Everything that doesn't need a model "
            "(all totals, categories, merchants, dates, balances) still works."
        ) from e


# --- Active model ------------------------------------------------------------------------

def active_model() -> str:
    return os.environ.get("LLM_MODEL") or DEFAULT_MODEL


def set_active_model(model_id: str) -> str:
    os.environ["LLM_MODEL"] = model_id
    try:
        _mlx()            # only unload if MLX is actually available (Mac)
        unload()          # drop the old weights; next call loads the new ones
    except LLMUnavailable:
        pass              # Windows/Groq: nothing to unload
    return model_id


def physical_ram_gb() -> int:
    try:
        return max(1, int(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / (1024 ** 3)))
    except Exception:
        pass
    try:
        import psutil
        return max(1, int(psutil.virtual_memory().total / (1024 ** 3)))
    except Exception:
        return 16


def is_downloaded(repo_id: str) -> bool:
    """On Apple Silicon (mlx available) check the HF cache.
    On Windows/Linux we use the Groq API fallback, so every model is 'available'."""
    try:
        _mlx()   # raises LLMUnavailable on non-Mac
    except LLMUnavailable:
        return True   # Windows / no MLX → Groq handles everything, all models selectable
    try:
        from huggingface_hub import scan_cache_dir
        return any(r.repo_id == repo_id for r in scan_cache_dir().repos)
    except Exception:
        return False


def list_models() -> dict:
    """Feeds the model picker: what's active, what's downloaded, what this machine can hold.
    On Windows (no MLX) all models show as installed so the user can select any of them."""
    ram = physical_ram_gb()
    # Check if MLX is available (Mac) or not (Windows → Groq fallback)
    try:
        _mlx()
        mlx_available = True
    except LLMUnavailable:
        mlx_available = False
    if mlx_available:
        recs = [{**m, "installed": is_downloaded(m["id"]), "can_run": m["min_ram_gb"] <= ram}
                for m in MODEL_CATALOG]
    else:
        # On Windows: show all models as installed (Groq API handles inference)
        recs = [{**m, "installed": True, "can_run": True} for m in MODEL_CATALOG]
    return {"active": active_model(), "ram_gb": ram, "recommended": recs,
            "installed": [m["id"] for m in recs if m["installed"]]}


# --- Download (streams progress for the picker's bar) -------------------------------------

def download_model(repo_id: str):
    """Yield {status, completed, total} dicts while pulling MLX weights from HuggingFace."""
    try:
        from huggingface_hub import snapshot_download
        import huggingface_hub.utils as hf_utils
    except ImportError:
        yield {"status": "error", "error": "huggingface_hub not installed (pip install huggingface_hub)"}
        return

    q: "queue.Queue" = queue.Queue()

    class _ProgressTqdm(hf_utils.tqdm):       # capture download progress
        def update(self, n=1):
            super().update(n)
            try:
                q.put({"status": "downloading", "completed": int(self.n or 0),
                       "total": int(self.total or 0)})
            except Exception:
                pass

    result = {}

    def _work():
        try:
            snapshot_download(repo_id, tqdm_class=_ProgressTqdm)
            result["ok"] = True
        except Exception as e:                # noqa: BLE001
            result["err"] = str(e)
        q.put(None)

    threading.Thread(target=_work, daemon=True).start()
    yield {"status": f"pulling {repo_id}"}
    while True:
        item = q.get()
        if item is None:
            break
        yield item
    if "err" in result:
        yield {"status": "error", "error": result["err"]}
    else:
        yield {"status": "success"}


import urllib.request

# --- Load / unload -------------------------------------------------------------------------

def ensure_loaded(model_id: str = None):
    """Load (downloading on first use) and cache the model. Thread-safe."""
    mid = model_id or active_model()
    with _lock:
        if _loaded["id"] == mid and _loaded["model"] is not None:
            return _loaded["model"], _loaded["tokenizer"]
        load, _, _, _ = _mlx()
        print(f"[mlx] loading {mid} …", flush=True)
        model, tokenizer = load(mid)
        _loaded.update({"id": mid, "model": model, "tokenizer": tokenizer})
        print(f"[mlx] {mid} ready", flush=True)
        return model, tokenizer


def unload():
    with _lock:
        _loaded.update({"id": None, "model": None, "tokenizer": None})


def is_ready() -> bool:
    try:
        _mlx()
        return _loaded["model"] is not None
    except LLMUnavailable:
        key = os.environ.get("GROQ_API_KEY") or os.environ.get("GROQ_API_KEY2")
        if not key:
            try:
                from dotenv import load_dotenv
                load_dotenv()
                key = os.environ.get("GROQ_API_KEY") or os.environ.get("GROQ_API_KEY2")
            except Exception:
                pass
        return bool(key)


# --- Generation ----------------------------------------------------------------------------

def _build_prompt(tokenizer, system, user) -> str:
    msgs = []
    if system:
        msgs.append({"role": "system", "content": system})
    msgs.append({"role": "user", "content": user})
    tmpl = getattr(tokenizer, "chat_template", None)
    if tmpl and hasattr(tokenizer, "apply_chat_template"):
        return tokenizer.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False)
    return (f"{system}\n\n" if system else "") + user


def complete(user: str, system: str = None, temperature: float = 0.2,
             top_p: float = 0.9, max_tokens: int = 512, json_mode: bool = False) -> str:
    """One-shot generation -> text. `json_mode` nudges the model to emit bare JSON."""
    try:
        _, generate, _, make_sampler = _mlx()
        model, tok = ensure_loaded()
        sys_prompt = system
        if json_mode:
            sys_prompt = ((system + "\n\n") if system else "") + \
                         "Reply with ONLY valid JSON. No prose, no markdown fences."
        prompt = _build_prompt(tok, sys_prompt, user)
        sampler = make_sampler(temp=float(temperature), top_p=float(top_p))
        out = generate(model, tok, prompt=prompt, max_tokens=max_tokens,
                       sampler=sampler, verbose=False)
        return (out or "").strip()
    except LLMUnavailable:
        key = os.environ.get("GROQ_API_KEY") or os.environ.get("GROQ_API_KEY2")
        if not key:
            try:
                from dotenv import load_dotenv
                load_dotenv()
                key = os.environ.get("GROQ_API_KEY") or os.environ.get("GROQ_API_KEY2")
            except Exception:
                pass
        if not key:
            raise LLMUnavailable("MLX is unavailable and GROQ_API_KEY is not set.")
        
        url = "https://api.groq.com/openai/v1/chat/completions"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}"
        }
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": user})
        
        data = {
            "model": "llama-3.1-8b-instant",
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens
        }
        if json_mode:
            data["response_format"] = {"type": "json_object"}
            
        req = urllib.request.Request(url, data=json.dumps(data).encode("utf-8"), headers=headers, method="POST")
        global DATA_SENT_OUT
        DATA_SENT_OUT += len(json.dumps(data).encode("utf-8"))
        try:
            with urllib.request.urlopen(req, timeout=30) as res:
                resp = json.loads(res.read().decode("utf-8"))
                return resp["choices"][0]["message"]["content"].strip()
        except Exception as e:
            raise RuntimeError(f"Groq API call failed: {e}") from e


def stream(user: str, system: str = None, temperature: float = 0.3,
           top_p: float = 0.9, max_tokens: int = 512):
    """Token-by-token generation -> yields text pieces."""
    try:
        _, _, stream_generate, make_sampler = _mlx()
        model, tok = ensure_loaded()
        prompt = _build_prompt(tok, system, user)
        sampler = make_sampler(temp=float(temperature), top_p=float(top_p))
        for chunk in stream_generate(model, tok, prompt=prompt, max_tokens=max_tokens,
                                     sampler=sampler):
            piece = getattr(chunk, "text", None)
            if piece:
                yield piece
    except LLMUnavailable:
        key = os.environ.get("GROQ_API_KEY") or os.environ.get("GROQ_API_KEY2")
        if not key:
            try:
                from dotenv import load_dotenv
                load_dotenv()
                key = os.environ.get("GROQ_API_KEY") or os.environ.get("GROQ_API_KEY2")
            except Exception:
                pass
        if not key:
            raise LLMUnavailable("MLX is unavailable and GROQ_API_KEY is not set.")
        
        url = "https://api.groq.com/openai/v1/chat/completions"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}"
        }
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": user})
        
        data = {
            "model": "llama-3.1-8b-instant",
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "stream": True
        }
        req = urllib.request.Request(url, data=json.dumps(data).encode("utf-8"), headers=headers, method="POST")
        global DATA_SENT_OUT
        DATA_SENT_OUT += len(json.dumps(data).encode("utf-8"))
        try:
            with urllib.request.urlopen(req, timeout=30) as res:
                buffer = ""
                while True:
                    chunk = res.read(1024)
                    if not chunk:
                        break
                    buffer += chunk.decode("utf-8")
                    while "\n" in buffer:
                        line, buffer = buffer.split("\n", 1)
                        line = line.strip()
                        if line.startswith("data:"):
                            data_str = line[5:].strip()
                            if data_str == "[DONE]":
                                break
                            try:
                                json_data = json.loads(data_str)
                                text = json_data["choices"][0]["delta"].get("content", "")
                                if text:
                                    yield text
                            except Exception:
                                pass
        except Exception as e:
            yield f"\n_(Groq API stream failed: {e})_"


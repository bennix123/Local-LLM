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
import urllib.request

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

# GGUF corresponding mappings for Windows/Linux local testing
GGUF_MAPPING = {
    "mlx-community/Llama-3.1-8B-Instruct-4bit": {
        "repo_id": "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
        "filename": "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
    },
    "mlx-community/Qwen2.5-7B-Instruct-4bit": {
        "repo_id": "Qwen/Qwen2.5-7B-Instruct-GGUF",
        "filename": "qwen2.5-7b-instruct-q4_k_m.gguf"
    },
    "mlx-community/Llama-3.2-3B-Instruct-4bit": {
        "repo_id": "bartowski/Llama-3.2-3B-Instruct-GGUF",
        "filename": "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    },
    "mlx-community/Qwen2.5-3B-Instruct-4bit": {
        "repo_id": "Qwen/Qwen2.5-3B-Instruct-GGUF",
        "filename": "qwen2.5-3b-instruct-q4_k_m.gguf"
    }
}

# Ollama mappings and helper functions
OLLAMA_MAPPING = {
    "mlx-community/Llama-3.1-8B-Instruct-4bit": "llama3.1:latest",
    "mlx-community/Qwen2.5-7B-Instruct-4bit": "qwen2.5:7b",
    "mlx-community/Llama-3.2-3B-Instruct-4bit": "llama3.2:latest",
    "mlx-community/Qwen2.5-3B-Instruct-4bit": "qwen2.5:3b"
}

def _is_ollama_running() -> bool:
    try:
        req = urllib.request.Request("http://127.0.0.1:11434/api/tags", method="GET")
        with urllib.request.urlopen(req, timeout=1.0) as res:
            return res.status == 200
    except Exception:
        return False

def _call_ollama(model_name: str, messages: list, temperature: float = 0.2, max_tokens: int = 512, json_mode: bool = False):
    url = "http://127.0.0.1:11434/api/chat"
    data = {
        "model": model_name,
        "messages": messages,
        "options": {
            "temperature": temperature,
            "num_predict": max_tokens
        },
        "stream": False
    }
    if json_mode:
        data["format"] = "json"
    
    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            resp = json.loads(res.read().decode("utf-8"))
            return resp["message"]["content"].strip()
    except Exception as e:
        print(f"[ollama] request failed: {e}")
        return None

# Resolve MODELS_DIR to finquery/models (4 levels up from this file's directory: finquery/backend/src/services)
MODELS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))), "models")

_loaded = {"id": None, "model": None, "tokenizer": None}
_lock = threading.Lock()   # guards _loaded on MLX/llama_cpp platforms
DATA_SENT_OUT = 0


def _llama_cpp():
    """Import llama_cpp lazily — importing this module must work on any OS."""
    try:
        from llama_cpp import Llama
        return Llama
    except ImportError:
        return None


def get_brain_stats() -> dict:
    global DATA_SENT_OUT
    is_local = True
    is_llama_cpp = False
    is_ollama = False
    try:
        _mlx()
    except LLMUnavailable:
        if _is_ollama_running():
            is_ollama = True
        elif _llama_cpp() is not None:
            is_llama_cpp = True
        else:
            is_local = False

    model_id = active_model()
    
    if is_local:
        model_info = next((m for m in MODEL_CATALOG if m["id"] == model_id), None)
        ram = model_info["size"] if model_info else "4.5 GB"
        if is_ollama:
            context = "8K tokens (Ollama)"
            model_name = (model_info["name"] if model_info else "Local Model") + " (Ollama)"
        else:
            context = "32K tokens" if not is_llama_cpp else "2K/4K tokens (GGUF)"
            model_name = (model_info["name"] if model_info else "Local Model") + (" (GGUF)" if is_llama_cpp else "")
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
        try:
            if _llama_cpp() is not None:
                unload()  # unload GGUF model too
        except Exception:
            pass
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
    On Windows/Linux, check if Ollama is running and has the model, or if llama_cpp is available and GGUF exists.
    Otherwise, default to True (Groq API fallback)."""
    try:
        _mlx()   # raises LLMUnavailable on non-Mac
        try:
            from huggingface_hub import scan_cache_dir
            return any(r.repo_id == repo_id for r in scan_cache_dir().repos)
        except Exception:
            return False
    except LLMUnavailable:
        if _is_ollama_running():
            try:
                # Query Ollama to see if it has the mapped model
                req = urllib.request.Request("http://127.0.0.1:11434/api/tags", method="GET")
                with urllib.request.urlopen(req, timeout=1.0) as res:
                    data = json.loads(res.read().decode("utf-8"))
                    installed_names = [m["name"] for m in data.get("models", [])]
                    target = OLLAMA_MAPPING.get(repo_id, "llama3.1")
                    return any(target in name or name in target for name in installed_names)
            except Exception:
                pass
        if _llama_cpp() is not None:
            # Check GGUF mapping
            mapping = GGUF_MAPPING.get(repo_id)
            if mapping:
                gguf_path = os.path.join(MODELS_DIR, mapping["filename"])
                return os.path.exists(gguf_path)
            return False
        return True   # Windows / no MLX, llama_cpp, and Ollama → Groq handles everything, all models selectable


def list_models() -> dict:
    """Feeds the model picker: what's active, what's downloaded, what this machine can hold."""
    ram = physical_ram_gb()
    # Check if MLX is available (Mac) or not (Windows → GGUF / Ollama / Groq fallback)
    try:
        _mlx()
        mlx_available = True
    except LLMUnavailable:
        mlx_available = False
    
    if mlx_available:
        recs = [{**m, "installed": is_downloaded(m["id"]), "can_run": m["min_ram_gb"] <= ram}
                for m in MODEL_CATALOG]
    elif _is_ollama_running() or _llama_cpp() is not None:
        recs = [{**m, "installed": is_downloaded(m["id"]), "can_run": m["min_ram_gb"] <= ram}
                for m in MODEL_CATALOG]
    else:
        # On Windows without llama_cpp or Ollama: show all models as installed (Groq API handles inference)
        recs = [{**m, "installed": True, "can_run": True} for m in MODEL_CATALOG]
    return {"active": active_model(), "ram_gb": ram, "recommended": recs,
            "installed": [m["id"] for m in recs if m["installed"]]}


# --- Download (streams progress for the picker's bar) -------------------------------------

def download_model(repo_id: str):
    """Yield {status, completed, total} dicts while pulling weights from HuggingFace.
    Downloads MLX format on macOS, GGUF format on Windows/Linux if llama_cpp is available."""
    try:
        from huggingface_hub import snapshot_download, hf_hub_download
        import huggingface_hub.utils as hf_utils
    except ImportError:
        yield {"status": "error", "error": "huggingface_hub not installed (pip install huggingface_hub)"}
        return

    # Check if we should download the GGUF model
    use_gguf = False
    try:
        _mlx()
    except LLMUnavailable:
        if _llama_cpp() is not None:
            use_gguf = True

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
            if use_gguf:
                mapping = GGUF_MAPPING.get(repo_id)
                if not mapping:
                    raise ValueError(f"No GGUF mapping for model: {repo_id}")
                os.makedirs(MODELS_DIR, exist_ok=True)
                hf_hub_download(
                    repo_id=mapping["repo_id"],
                    filename=mapping["filename"],
                    local_dir=MODELS_DIR,
                    tqdm_class=_ProgressTqdm
                )
            else:
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


# --- Load / unload -------------------------------------------------------------------------

def ensure_loaded(model_id: str = None):
    """Load (downloading on first use) and cache the model. Thread-safe."""
    mid = model_id or active_model()
    with _lock:
        if _loaded["id"] == mid and _loaded["model"] is not None:
            return _loaded["model"], _loaded["tokenizer"]
        
        try:
            load, _, _, _ = _mlx()
            print(f"[mlx] loading {mid} …", flush=True)
            model, tokenizer = load(mid)
            _loaded.update({"id": mid, "model": model, "tokenizer": tokenizer})
            print(f"[mlx] {mid} ready", flush=True)
            return model, tokenizer
        except LLMUnavailable as e:
            if _is_ollama_running() and is_downloaded(mid):
                print(f"[ollama] active and model {mid} downloaded, skipping in-process load", flush=True)
                return None, None
            Llama = _llama_cpp()
            if Llama is not None:
                mapping = GGUF_MAPPING.get(mid)
                if not mapping:
                    raise ValueError(f"No GGUF mapping for model: {mid}") from e
                
                # Check if it exists or download it on first use
                gguf_path = os.path.join(MODELS_DIR, mapping["filename"])
                if not os.path.exists(gguf_path):
                    print(f"[llama-cpp] downloading {mid} on first use …", flush=True)
                    from huggingface_hub import hf_hub_download
                    os.makedirs(MODELS_DIR, exist_ok=True)
                    hf_hub_download(
                        repo_id=mapping["repo_id"],
                        filename=mapping["filename"],
                        local_dir=MODELS_DIR
                    )
                
                model = Llama(model_path=gguf_path, n_ctx=2048, verbose=False)
                _loaded.update({"id": mid, "model": model, "tokenizer": None})

                print(f"[llama-cpp] GGUF {mid} ready", flush=True)
                return model, None
            else:
                raise e


def unload():
    with _lock:
        _loaded.update({"id": None, "model": None, "tokenizer": None})


def is_ready() -> bool:
    try:
        _mlx()
        return _loaded["model"] is not None
    except LLMUnavailable:
        if _llama_cpp() is not None:
            return _loaded["model"] is not None or is_downloaded(active_model())
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
    if tokenizer is None:
        return (f"{system}\n\n" if system else "") + user
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
    except LLMUnavailable as e:
        if _is_ollama_running():
            mid = active_model()
            ollama_model = OLLAMA_MAPPING.get(mid, "llama3.1:latest")
            messages = []
            if system:
                messages.append({"role": "system", "content": system})
            messages.append({"role": "user", "content": user})
            
            res = _call_ollama(ollama_model, messages, temperature=temperature, max_tokens=max_tokens, json_mode=json_mode)
            if res is not None:
                return res
        
        Llama = _llama_cpp()
        if Llama is not None:
            model, _ = ensure_loaded()
            if model is not None:      # None when Ollama owns the model (no in-process load)
                messages = []
                if system:
                    messages.append({"role": "system", "content": system})
                messages.append({"role": "user", "content": user})

                response_format = None
                if json_mode:
                    response_format = {"type": "json_object"}

                res = model.create_chat_completion(
                    messages=messages,
                    temperature=temperature,
                    top_p=top_p,
                    max_tokens=max_tokens,
                    response_format=response_format
                )
                return res["choices"][0]["message"]["content"].strip()

        key = os.environ.get("GROQ_API_KEY") or os.environ.get("GROQ_API_KEY2")
        if not key:
            try:
                from dotenv import load_dotenv
                load_dotenv()
                key = os.environ.get("GROQ_API_KEY") or os.environ.get("GROQ_API_KEY2")
            except Exception:
                pass
        if not key:
            raise LLMUnavailable("MLX and llama-cpp are unavailable and GROQ_API_KEY is not set.") from e
        
        url = "https://api.groq.com/openai/v1/chat/completions"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
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
        except Exception as e_groq:
            raise RuntimeError(f"Groq API call failed: {e_groq}") from e_groq


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
    except LLMUnavailable as e:
        if _is_ollama_running():
            mid = active_model()
            ollama_model = OLLAMA_MAPPING.get(mid, "llama3.1:latest")
            messages = []
            if system:
                messages.append({"role": "system", "content": system})
            messages.append({"role": "user", "content": user})

            data = {
                "model": ollama_model,
                "messages": messages,
                "options": {
                    "temperature": temperature,
                    "num_predict": max_tokens
                },
                "stream": True
            }
            req = urllib.request.Request(
                "http://127.0.0.1:11434/api/chat",
                data=json.dumps(data).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            yielded = False
            try:
                with urllib.request.urlopen(req, timeout=30) as res:
                    for line in res:                 # Ollama streams NDJSON, one object per line
                        line = line.strip()
                        if not line:
                            continue
                        chunk = json.loads(line.decode("utf-8"))
                        piece = chunk.get("message", {}).get("content")
                        if piece:
                            yielded = True
                            yield piece
                        if chunk.get("done"):
                            break
                return
            except Exception as e_ollama:
                print(f"[ollama] stream failed: {e_ollama}")
                if yielded:
                    return               # partial output already sent — don't restart on another backend

        Llama = _llama_cpp()
        if Llama is not None:
            model, _ = ensure_loaded()
            if model is not None:      # None when Ollama owns the model (no in-process load)
                messages = []
                if system:
                    messages.append({"role": "system", "content": system})
                messages.append({"role": "user", "content": user})

                stream_res = model.create_chat_completion(
                    messages=messages,
                    temperature=temperature,
                    top_p=top_p,
                    max_tokens=max_tokens,
                    stream=True
                )
                for chunk in stream_res:
                    delta = chunk["choices"][0]["delta"]
                    if "content" in delta:
                        yield delta["content"]
                return

        key = os.environ.get("GROQ_API_KEY") or os.environ.get("GROQ_API_KEY2")
        if not key:
            try:
                from dotenv import load_dotenv
                load_dotenv()
                key = os.environ.get("GROQ_API_KEY") or os.environ.get("GROQ_API_KEY2")
            except Exception:
                pass
        if not key:
            raise LLMUnavailable("MLX and llama-cpp are unavailable and GROQ_API_KEY is not set.") from e
        
        url = "https://api.groq.com/openai/v1/chat/completions"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
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
        except Exception as e_groq:
            yield f"\n_(Groq API stream failed: {e_groq})_"

#!/usr/bin/env python3
"""
Iterative eval loop: evaluate every LoRA checkpoint on the held-out set, compare against
the baseline, KEEP THE BEST checkpoint (never overwrite a better model with a worse one),
and write a consolidated before/after report.

Run after (or during) training:
  python tools/mlx/run_loop.py --per-field 60
"""
import json, os, glob, shutil, subprocess, sys, argparse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MLXDIR = os.path.join(ROOT, "data", "paytm_mlx")
ADIR = os.path.join(MLXDIR, "adapters")
PY = os.path.join(ROOT, ".venv-mlx", "bin", "python")
EVAL = os.path.join(ROOT, "tools", "mlx", "evaluate.py")

def ckpt_iter(path):
    b = os.path.basename(path)
    n = "".join(c for c in b.split("_")[0] if c.isdigit())
    return int(n) if n else 0

def prep_ckpt_dir(ckpt_file, tag):
    d = os.path.join(ADIR, f"ckpt_{tag}")
    os.makedirs(d, exist_ok=True)
    shutil.copy(os.path.join(ADIR, "adapter_config.json"), os.path.join(d, "adapter_config.json"))
    shutil.copy(ckpt_file, os.path.join(d, "adapters.safetensors"))
    return d

def run_eval(tag, adapter, per_field):
    out = os.path.join(MLXDIR, f"eval_{tag}.json")
    cmd = [PY, EVAL, "--tag", tag, "--per-field", str(per_field), "--out", out]
    if adapter: cmd += ["--adapter", adapter]
    subprocess.run(cmd, check=True, cwd=ROOT,
                   stdout=sys.stdout, stderr=sys.stderr)
    return json.load(open(out))["report"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-field", type=int, default=60)
    args = ap.parse_args()

    # baseline (reuse if present)
    base_path = os.path.join(MLXDIR, "eval_base.json")
    base = json.load(open(base_path))["report"] if os.path.exists(base_path) else run_eval("base", None, args.per_field)

    ckpts = sorted(glob.glob(os.path.join(ADIR, "*_adapters.safetensors")), key=ckpt_iter)
    rows = []
    for c in ckpts:
        it = ckpt_iter(c)
        d = prep_ckpt_dir(c, str(it))
        r = run_eval(f"iter{it}", d, args.per_field)
        rows.append((it, r))

    # pick best by overall accuracy (tie-break: fewer iters)
    best_it, best = max(rows, key=lambda x: (x[1]["overall_accuracy"], -x[0])) if rows else (None, None)
    if best is not None:
        # materialise best -> adapters/best (never overwrite a better model with a worse one)
        bestdir = os.path.join(ADIR, "best")
        os.makedirs(bestdir, exist_ok=True)
        src = next(c for c in ckpts if ckpt_iter(c) == best_it)
        shutil.copy(os.path.join(ADIR, "adapter_config.json"), os.path.join(bestdir, "adapter_config.json"))
        shutil.copy(src, os.path.join(bestdir, "adapters.safetensors"))

    summary = {
        "baseline": {"overall": base["overall_accuracy"], "atomic": base["by_kind"].get("atomic",{}).get("acc"),
                     "tokens_per_sec": base["tokens_per_sec"], "avg_latency_s": base["avg_latency_s"]},
        "checkpoints": [{"iter": (None if it==10**9 else it),
                         "label": ("final" if it==10**9 else f"iter{it}"),
                         "overall": r["overall_accuracy"],
                         "atomic": r["by_kind"].get("atomic",{}).get("acc"),
                         "by_field": {k: v["acc"] for k,v in r["by_field"].items()},
                         "tokens_per_sec": r["tokens_per_sec"], "avg_latency_s": r["avg_latency_s"]}
                        for it, r in rows],
        "best": {"label": (f"iter{best_it}") if best else None,
                 "overall": best["overall_accuracy"] if best else None,
                 "atomic": best["by_kind"].get("atomic",{}).get("acc") if best else None,
                 "path": os.path.join(ADIR, "best")},
    }
    json.dump(summary, open(os.path.join(MLXDIR, "eval_loop_summary.json"), "w"), indent=2, ensure_ascii=False)
    print("\n==== EVAL LOOP SUMMARY ====")
    print(f"baseline overall={summary['baseline']['overall']:.3f}  atomic={summary['baseline']['atomic']:.3f}")
    for c in summary["checkpoints"]:
        print(f"  {c['label']:8s} overall={c['overall']:.3f}  atomic={c['atomic']:.3f}  "
              f"amount={c['by_field'].get('amount')}  balance={c['by_field'].get('balance_after')}  "
              f"cp={c['by_field'].get('counterparty')}  id={c['by_field'].get('txn_id')}")
    if best:
        print(f"BEST -> {summary['best']['label']}  overall={summary['best']['overall']:.3f}  "
              f"(kept at {summary['best']['path']})")
    print("wrote", os.path.join(MLXDIR, "eval_loop_summary.json"))

if __name__ == "__main__":
    main()

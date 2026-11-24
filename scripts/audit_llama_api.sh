#!/usr/bin/env bash
# Static API audit of lai_bridge.cpp against the REAL include/llama.h of the pinned
# checkout. It only proves that names/fields exist; signatures and behaviour still
# need the real compile and real-model tests. NOT RUN in the authoring sandbox.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="${1:-$ROOT/third_party/llama.cpp/include/llama.h}"
[ -f "$H" ] || { echo "llama.h not found: $H (run scripts/fetch_llama_cpp.sh)"; exit 2; }
python3 - "$ROOT/native/src/lai_bridge.cpp" "$H" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
hdr = open(sys.argv[2], encoding="utf-8").read()
used = sorted(set(re.findall(r"\b(llama_[a-z0-9_]+|LLAMA_[A-Z0-9_]+)\b", src)))
missing = [u for u in used if not re.search(r"\b%s\b" % re.escape(u), hdr)]
fields = {
  "llama_model_params": ["n_gpu_layers", "load_mode"],
  "llama_context_params": ["n_ctx", "n_batch", "n_ubatch", "n_threads", "n_threads_batch"],
  "llama_batch": ["n_tokens", "token", "embd", "pos", "n_seq_id", "seq_id", "logits"],
}
bad = []
for st, names in fields.items():
    m = re.search(r"struct\s+%s\s*\{(.*?)\n\s*\}\s*(?:%s)?\s*;" % (st, st), hdr, re.S)
    if not m:
        bad.append(f"struct {st} not found"); continue
    for n in names:
        if not re.search(r"\b%s\b" % n, m.group(1)):
            bad.append(f"{st}.{n}")
print("symbols used by the bridge:", len(used))
print("MISSING symbols:", missing or "none")
print("MISSING fields :", bad or "none")
print("Deprecated declarations among used symbols:")
# DEPRECATED(<return type> name(args...), "hint"): take the declared name only.
dep = set(re.findall(r"^\s*DEPRECATED\(\s*[^()]*?\b([A-Za-z_0-9]+)\s*\(", hdr, re.M))
hits = [u for u in used if u in dep]
print("  " + (", ".join(hits) if hits else "none"))
sys.exit(1 if (missing or bad) else 0)
PY

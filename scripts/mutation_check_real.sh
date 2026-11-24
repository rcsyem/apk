#!/usr/bin/env bash
# Mutation check against the REAL libllama (not the fake): re-introduces position/logits bugs
# into copies of lai_bridge.cpp, links each with the static llama/ggml libs of an existing real
# build, and runs the real-model driver. Every mutant must FAIL (the real llama_decode rejects
# the bad batches or the driver's output checks catch them). A surviving mutant = weak test.
# Usage: mutation_check_real.sh <real-build-dir> <llama.cpp dir> <model.gguf>
set -uo pipefail
BUILD="${1:?build dir}"; LLAMA="${2:?llama.cpp dir}"; MODEL="${3:?model.gguf}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lai_mut_real"; mkdir -p "$OUT"
LIBS="$BUILD/llama_build/src/libllama.a $BUILD/llama_build/ggml/src/libggml.a $BUILD/llama_build/ggml/src/libggml-cpu.a $BUILD/llama_build/ggml/src/libggml-base.a"
fail=0
run_mutant() {
  local name="$1" from="$2" to="$3" expect="${4:-kill}"
  python3 -I - "$ROOT/native/src/lai_bridge.cpp" "$OUT/$name.cpp" "$from" "$to" <<'PY' || { echo "MUTANT $name: pattern not found"; fail=1; return; }
import sys
src, out, a, b = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
if t.count(a) != 1: sys.exit(1)
open(out, "w", encoding="utf-8").write(t.replace(a, b))
PY
  g++ -std=c++17 -O1 -pthread -I"$ROOT/native/include" -I"$ROOT/native/src" -I"$LLAMA/include" -I"$LLAMA/ggml/include" \
      "$OUT/$name.cpp" "$ROOT/native/tests/real_engine_test.cpp" $LIBS -ldl -lm -o "$OUT/$name" 2>"$OUT/$name.cc.log" \
      || { echo "MUTANT $name: did not compile (see $OUT/$name.cc.log)"; fail=1; return; }
  if timeout 120 "$OUT/$name" "$MODEL" 2048 2 >"$OUT/$name.log" 2>&1; then
    if [ "$expect" = survive ]; then
      echo "MUTANT $name: survived (EXPECTED: not a correctness bug in llama.cpp; it costs ~+600 MB peak RSS" \
           "on the synthetic model. Killed only by the fake-based host test: scripts/mutation_check.sh)"
    else
      echo "MUTANT $name: SURVIVED  <-- test too weak"; fail=1
    fi
  else
    local why; why="$(grep -m1 -E 'FAIL line|rc=[1-9]|decode' "$OUT/$name.log" | cut -c1-120)"
    local lib; lib="$(grep -m1 -iE 'inconsistent|invalid|failed to find|position|decode: ' "$OUT/$name.log" | cut -c1-140)"
    echo "MUTANT $name: killed | driver: ${why:-nonzero exit} | llama.cpp said: ${lib:-<nothing>}"
  fi
}
run_mutant pos_reset_to_zero    'b.pos[i] = pos0 + i;'                   'b.pos[i] = i;'
run_mutant prompt_npast_frozen  'n_past += n;'                           '/* mutant */'
run_mutant gen_npast_frozen     'n_past += 1;'                           '/* mutant */'
run_mutant no_cache_clear       'llama_memory_clear(mem, true);'         '(void)mem;'
run_mutant wrong_seq_id         'b.seq_id[i][0] = kSeq;'                 'b.seq_id[i][0] = 1;'
run_mutant no_logits_on_prompt  '(want_logits && i == n - 1) ? 1 : 0'    '0'
run_mutant logits_on_all        '(want_logits && i == n - 1) ? 1 : 0'    '1' survive
exit $fail

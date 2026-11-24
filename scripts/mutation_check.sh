#!/usr/bin/env bash
# Mutation check for the position tests (host, FAKE llama only).
# Each mutant re-introduces a position/logits bug into a COPY of lai_bridge.cpp.
# The bridge test MUST fail for every mutant; if one survives, the position tests
# are too weak. This does NOT replace a test against real llama.cpp.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/mut
CXX=${CXX:-g++}
COMMON="-std=c++17 -g -O1 -Wall -Wextra -Inative/include -Inative/src -Inative/tests/fake -pthread"
SRC=native/src/lai_bridge.cpp
fail=0

# Two modes: "strict" (fake rejects bad positions, like a library would) and
# "permissive" (fake only RECORDS them, so the test's own assertions must catch the bug).
run_mutant() {
  local mode="$1" name="$2" from="$3" to="$4"
  local flag=""; [ "$mode" = permissive ] && flag="-DLAI_FAKE_PERMISSIVE"
  name="${mode}_${name}"
  local out="build/mut/lai_bridge_${name}.cpp"
  python3 - "$SRC" "$out" "$from" "$to" <<'PY' || { echo "MUTANT $name: pattern not found (script out of date)"; fail=1; return; }
import sys
src, out, a, b = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
if t.count(a) != 1:
    sys.exit(1)
open(out, "w", encoding="utf-8").write(t.replace(a, b))
PY
  if ! $CXX $COMMON $flag "$out" native/tests/fake_llama.cpp native/tests/bridge_test.cpp -o "build/mut/bt_${name}" 2>build/mut/err_${name}.txt; then
    echo "MUTANT $name: did not compile (see build/mut/err_${name}.txt)"; fail=1; return
  fi
  if "build/mut/bt_${name}" >/dev/null 2>build/mut/out_${name}.txt; then
    echo "MUTANT $name: SURVIVED  <-- tests too weak"; fail=1
  else
    echo "MUTANT $name: killed  ($(grep -m1 -E 'FAIL|WATCHDOG' build/mut/out_${name}.txt || echo 'nonzero exit'))"
  fi
}

run_mutant strict pos_reset_to_zero   'b.pos[i] = pos0 + i;'                        'b.pos[i] = i;'
run_mutant strict prompt_npast_frozen 'n_past += n;'                                '/* mutant */'
run_mutant strict gen_npast_frozen    'n_past += 1;'                                '/* mutant */'
run_mutant strict no_logits_on_prompt '(want_logits && i == n - 1) ? 1 : 0'        '0'
run_mutant strict logits_on_all       '(want_logits && i == n - 1) ? 1 : 0'        '1'
run_mutant strict no_cache_clear      'llama_memory_clear(mem, true);'              '(void)mem;'
run_mutant strict wrong_seq_id        'b.seq_id[i][0] = kSeq;'                      'b.seq_id[i][0] = 1;'
run_mutant permissive pos_reset_to_zero   'b.pos[i] = pos0 + i;'                        'b.pos[i] = i;'
run_mutant permissive prompt_npast_frozen 'n_past += n;'                                '/* mutant */'
run_mutant permissive gen_npast_frozen    'n_past += 1;'                                '/* mutant */'
run_mutant permissive no_logits_on_prompt '(want_logits && i == n - 1) ? 1 : 0'        '0'
run_mutant permissive logits_on_all       '(want_logits && i == n - 1) ? 1 : 0'        '1'
run_mutant permissive no_cache_clear      'llama_memory_clear(mem, true);'              '(void)mem;'
run_mutant permissive wrong_seq_id        'b.seq_id[i][0] = kSeq;'                      'b.seq_id[i][0] = 1;'
exit $fail

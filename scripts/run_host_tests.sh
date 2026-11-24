#!/usr/bin/env bash
# Host tests of the native bridge against a FAKE llama (native/tests/fake_llama.cpp).
# They validate threading, chunking, queueing, UTF-8 splitting and error paths of
# lai_bridge.cpp. They say NOTHING about compatibility with real llama.cpp.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/host
CXX=${CXX:-g++}
COMMON="-std=c++17 -g -O1 -Wall -Wextra -Inative/include -Inative/src -Inative/tests/fake -pthread"
SRCS="native/src/lai_bridge.cpp native/tests/fake_llama.cpp native/tests/bridge_test.cpp"

# Static guard: the bridge must not use the implicit-position batch helper.
if grep -nE "llama_batch_get_one[[:space:]]*\(" native/src/lai_bridge.cpp; then
  echo "FAIL: lai_bridge.cpp uses llama_batch_get_one (explicit positions required)"; exit 1
fi
echo "== catalog gate"
python3 -I scripts/test_validate_catalog.py && python3 -I scripts/validate_catalog.py
$CXX $COMMON native/tests/utf8_test.cpp -o build/host/utf8_test && build/host/utf8_test
echo "== bridge_test (no sanitizer)"
$CXX $COMMON $SRCS -o build/host/bridge_test_plain
build/host/bridge_test_plain
if [ "${LAI_SKIP_SANITIZERS:-0}" = 1 ]; then
  echo "== sanitizers SKIPPED (LAI_SKIP_SANITIZERS=1) - not verified"
else
  # If ASan aborts at start-up with a virtual-memory reservation error, try
  # `ulimit -v unlimited` first. Do not claim ASan/TSan results unless these ran.
  for SAN in address,undefined thread; do
    echo "== bridge_test with -fsanitize=$SAN"
    $CXX $COMMON -fsanitize=$SAN $SRCS -o build/host/bridge_test_${SAN%%,*}
    build/host/bridge_test_${SAN%%,*}
  done
fi
echo "== mutation check of the position tests"
scripts/mutation_check.sh
echo "== PoC against fake llama (smoke only)"
$CXX $COMMON native/src/lai_bridge.cpp native/tests/fake_llama.cpp native/poc/poc_main.cpp -o build/host/poc_fake
echo x > /tmp/poc_model.gguf
build/host/poc_fake /tmp/poc_model.gguf "hi" 2048 2 30000 80 >/dev/null

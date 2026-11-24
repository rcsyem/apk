#!/usr/bin/env bash
# Real-llama.cpp HOST pipeline (x86-64/arm64 Linux, CPU): fetch pinned commit -> API audit ->
# build bridge + driver against the REAL source -> run the real-model acceptance driver.
# Usage: scripts/run_real_host.sh /path/model.gguf
# Env: LAI_LLAMA_DIR (llama.cpp checkout), LAI_BUILD_DIR (build dir), LAI_N_CTX, LAI_THREADS.
# This is NOT the Android build (see scripts/build_poc_android.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${1:?usage: $0 model.gguf}"
LLAMA="${LAI_LLAMA_DIR:-$ROOT/third_party/llama.cpp}"
BUILD="${LAI_BUILD_DIR:-$ROOT/build/real-host}"
[ -d "$LLAMA/.git" ] || LAI_LLAMA_DIR="$LLAMA" "$ROOT/scripts/fetch_llama_cpp.sh"
"$ROOT/scripts/audit_llama_api.sh" "$LLAMA/include/llama.h"
cmake -S "$ROOT/native" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DLLAMA_DIR="$LLAMA" -DLAI_BUILD_POC=ON
cmake --build "$BUILD" --target lai_bridge lai_poc lai_real_test -j"$(nproc)"
LD_LIBRARY_PATH="$BUILD" "$BUILD/lai_real_test" "$MODEL" "${LAI_N_CTX:-2048}" "${LAI_THREADS:-4}" 2>&1 | tee "$BUILD/real_test.log"
test "${PIPESTATUS[0]}" -eq 0

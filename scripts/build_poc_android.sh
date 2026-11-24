#!/usr/bin/env bash
# Builds the engine PoC CLI for Android arm64-v8a. NOT RUN in the authoring
# sandbox (no NDK, no network). Requires: cmake, ninja and an NDK (ANDROID_NDK_HOME, or auto-detected by
# scripts/ndk_detect.py from env / local.properties / SDK, failing on conflicts),
# Optional opt-in tuning (never default): LAI_EXTRA_ARCH_FLAGS="-march=armv8.2-a+dotprod"
# and a llama.cpp checkout in third_party/llama.cpp (see third_party/README.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME="$(python3 -I "$ROOT/scripts/ndk_detect.py" --project "$ROOT" --print-path)" \
    || { echo "NDK detection failed (run: python3 -I scripts/ndk_detect.py --project . for details)" >&2; exit 1; }
  export ANDROID_NDK_HOME
fi
OUT="$ROOT/build/poc-arm64"
cmake -S "$ROOT/native" -B "$OUT" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLAI_EXTRA_ARCH_FLAGS="${LAI_EXTRA_ARCH_FLAGS:-}" \
  -DLAI_BUILD_POC=ON
cmake --build "$OUT" --target lai_poc lai_real_test
echo "Built: $OUT/lai_poc  (also needs $OUT/liblai_bridge.so next to it)"
echo "Run on a device you control: LD_LIBRARY_PATH=. ./lai_poc model.gguf \"مرحبا\" 2048 4 128 [stop_after_ms]"
echo "Real-model acceptance: LD_LIBRARY_PATH=. ./lai_real_test model.gguf 2048 4   (needs liblai_bridge.so + libc++_shared.so if shared STL)"

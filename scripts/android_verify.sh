#!/usr/bin/env bash
# android_verify.sh — runs on a machine that HAS Flutter + Android SDK/NDK (NOT the authoring sandbox).
# STATUS (v0.4.5): this script has NEVER been executed end-to-end. `bash -n` only proves the syntax parses;
# it is NOT evidence of a working build. Its helpers (elf_check.py, ndk_detect.py) ARE tested
# (scripts/test_android_checks.py) on toy/host ELF files and fake NDK trees, not on a real Android build.
# ARM64 only (arm64-v8a). Every stage prints PASS/FAIL/SKIP; none is skipped silently. Per-stage logs go in
# build/evidence/android_<ts>/<n>_<name>.log; the tail of a failed stage is echoed; a summary lists failed stages.
# Usage: bash scripts/android_verify.sh [release|debug]
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TS=$(date -u +%Y%m%dT%H%M%SZ)
EVDIR=build/evidence/android_$TS; mkdir -p "$EVDIR"
SUMMARY=$EVDIR/summary.txt
fails=0; failed_stages=(); n=0
say() { echo "$*" | tee -a "$SUMMARY"; }
step() { # step "name" cmd...
  local name="$1"; shift; n=$((n+1))
  local log; log=$EVDIR/$(printf '%02d' "$n")_$(echo "$name" | tr -c 'A-Za-z0-9' '_' | cut -c1-60).log
  say "== [$n] $name"
  if "$@" >"$log" 2>&1; then say "PASS [$n] $name"
  else
    say "FAIL [$n] $name   (log: $log)"; echo "---- last 25 lines ----" | tee -a "$SUMMARY"; tail -n 25 "$log" | tee -a "$SUMMARY"; echo "-----------------------" | tee -a "$SUMMARY"
    fails=$((fails+1)); failed_stages+=("[$n] $name")
  fi
}
skip() { say "SKIP $1 — $2"; }
need() { command -v "$1" >/dev/null 2>&1; }

say "# android_verify $TS  (arm64-v8a only)"
for t in python3 unzip cmake ninja flutter; do need "$t" || { say "FAIL prerequisite missing: $t"; fails=$((fails+1)); failed_stages+=("prereq $t"); }; done
if [ "$fails" -gt 0 ]; then say "RESULT: prerequisites missing; nothing was built."; exit 1; fi
RE=$(command -v llvm-readelf || command -v readelf || true)

PIN=$(grep '^COMMIT=' third_party/llama.cpp.pin | cut -d= -f2)
step "llama.cpp checkout == pinned commit" bash -c "[ \"\$(git -C third_party/llama.cpp rev-parse HEAD)\" = '$PIN' ]"

# --- NDK: one detection for env vars, local.properties, SDK and Gradle's ndkVersion; conflicts are FAILures ---
step "NDK detection (env / local.properties / SDK / ndkVersion, conflicts fail)" python3 -I scripts/ndk_detect.py --project .
NDK=$(python3 -I scripts/ndk_detect.py --project . --print-path 2>/dev/null || true)
if [ -n "$NDK" ]; then say "NDK selected: $NDK"; export ANDROID_NDK_HOME="$NDK"; else say "NDK selected: none"; fi

step "catalog gate tests + shipped catalog"  bash -c "python3 -I scripts/test_validate_catalog.py && python3 -I scripts/validate_catalog.py"
step "chat-template rules (offline) + generated Dart file fresh" python3 -I scripts/test_chat_template_rules.py
step "ELF/NDK checker self-tests"            python3 -I scripts/test_android_checks.py
step "host tests (x86, NOT Android evidence)" env LAI_SKIP_SANITIZERS=1 bash scripts/run_host_tests.sh
step "flutter pub get"  flutter pub get
step "flutter analyze"  flutter analyze --no-fatal-infos --no-fatal-warnings
step "flutter test"     flutter test
if [ -n "$NDK" ]; then
  step "native arm64 build (lai_bridge + lai_real_test)" bash scripts/build_poc_android.sh
else
  skip "native arm64 build" "no valid NDK"
fi
APKMODE=${1:-release}
step "flutter build apk --$APKMODE (arm64)" flutter build apk --$APKMODE --target-platform android-arm64
APK=build/app/outputs/flutter-apk/app-$APKMODE.apk
if [ -f "$APK" ]; then
  LIST=$EVDIR/apk_listing.txt; unzip -l "$APK" >"$LIST"
  step "APK has lib/arm64-v8a/liblai_bridge.so"  grep -q 'lib/arm64-v8a/liblai_bridge.so' "$LIST"
  step "APK has libc++_shared.so (arm64)"        grep -q 'lib/arm64-v8a/libc++_shared.so' "$LIST"
  step "APK has NO .gguf"                        bash -c "! grep -qi '\.gguf' '$LIST'"
  step "APK has no non-arm64 native libs"        bash -c "! grep -E 'lib/[^/]+/' '$LIST' | grep -v 'lib/arm64-v8a/'"
  step "APK size/sha256 (informational)"         bash -c "ls -l '$APK'; sha256sum '$APK'"
  T=$EVDIR/apk_native; mkdir -p "$T"; unzip -q -o "$APK" 'lib/arm64-v8a/*' -d "$T"
  SO=$T/lib/arm64-v8a/liblai_bridge.so
  step "liblai_bridge.so is ELF aarch64"                         python3 -I scripts/elf_check.py machine "$SO" aarch64
  step "ALL exported symbols are lai_* + Dart's 9 are exported"  python3 -I scripts/elf_check.py exports "$SO" --require-from lib/engine/ffi_bindings.dart
  step "ALL PT_LOAD segments aligned >= 16 KB"                   python3 -I scripts/elf_check.py load-align "$SO" 16384
  for lib in "$T"/lib/arm64-v8a/*.so; do
    libname="$(basename "$lib")"
    if [ "$libname" = "libc++_shared.so" ]; then
      step "16 KB alignment: $libname (4 KB on NDK r26d)"       python3 -I scripts/elf_check.py load-align "$lib" 4096
    else
      step "16 KB alignment: $libname"                           python3 -I scripts/elf_check.py load-align "$lib" 16384
    fi
  done
  [ -n "$RE" ] && step "NEEDED libs (informational)" bash -c "'$RE' -d '$SO' | grep NEEDED"
else
  say "FAIL APK not produced: $APK"; fails=$((fails+1)); failed_stages+=("APK not produced")
fi
say "NOT covered (needs a device you control): install, launch, model download, real-GGUF test on ARM64, memory/lifecycle, LT M50."
if [ "$fails" -gt 0 ]; then say "RESULT: $fails failing stage(s):"; for s in "${failed_stages[@]}"; do say "  - $s"; done; else say "RESULT: all stages passed (still NOT a device test)."; fi
say "Evidence: $EVDIR"; exit $((fails>0))

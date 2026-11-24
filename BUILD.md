# Build (NOT yet executed for Flutter/Android by the author)

Requirements: Flutter (Dart >= 3.4), JDK 17, Android SDK + NDK (choose and record a
version), CMake 3.22.1, Ninja, git.

1. `flutter create --platforms=android .` to generate missing scaffolding (Gradle wrapper
   jar, icons). Keep this repo's `android/app/build.gradle.kts`, `AndroidManifest.xml`
   (activity `.MainActivity`), `src/main/kotlin/.../MainActivity.kt`, `res/values/styles.xml`,
   `settings.gradle.kts`, `assets/model_catalog.json`. Merge; do not overwrite.
2. llama.cpp is pinned: v1.0.0 = b1b770d90d94cad9e9ea5b993bdbc383a522fb28
   (`third_party/llama.cpp.pin`). `scripts/fetch_llama_cpp.sh` checks it out (shallow) into
   `third_party/llama.cpp` and verifies the SHA and that the tag resolves to the same commit.
   `scripts/audit_llama_api.sh` checks every `llama_*` name/field the bridge uses against the
   real `llama.h`. The checkout is NOT shipped in the ZIP (about 100 MB).
3a. Host logic tests (any machine with g++; FAKE llama): `scripts/run_host_tests.sh`.
3b. Host test against the REAL llama.cpp: `scripts/run_real_host.sh model.gguf`
    (`scripts/make_synthetic_gguf.py` makes a tiny random-weights GGUF if no real model is at hand;
    that proves plumbing only, not quality). `scripts/mutation_check_real.sh` re-runs the position
    mutants against the real library.
4. Engine proof: `scripts/build_poc_android.sh`, then run `lai_poc model.gguf "مرحبا" 2048 4 128 300`
   (last arg = stop after N ms) on an ARM64 device you control. Record results in TESTING.md.
5. `flutter pub get && flutter analyze && flutter test`
6. `flutter build apk --release --target-platform android-arm64`

## CMake notes learned from the real build (llama.cpp v1.0.0)
- `LLAMA_CURL` no longer exists; HTTPS support is `LLAMA_OPENSSL` (default ON) and is forced OFF.
- Static libllama/ggml are linked into the shared `liblai_bridge.so`, so `CMAKE_POSITION_INDEPENDENT_CODE`
  must be ON (the first real link failed with "recompile with -fPIC").
- `-Wl,--exclude-libs,ALL` keeps llama/ggml internals out of the exported symbols (only `lai_*`).
- `llama_model_params.use_mmap` was removed; the bridge sets `load_mode = LLAMA_LOAD_MODE_MMAP`.

## CPU flags
Baseline arm64-v8a by default (no `-march`). Opt in for experiments only:
`-DLAI_EXTRA_ARCH_FLAGS="-march=armv8.2-a+dotprod"`. Any gain is unmeasured.

## Unverified
Package versions in pubspec (never resolved), AGP/Kotlin/Gradle versions, `ndkVersion`,
`c++_shared` packaging, `-Wl,-z,max-page-size=16384`, file_picker behaviour on SAF URIs,
APK size. The launcher icon is a placeholder system drawable.

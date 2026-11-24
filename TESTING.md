# Testing

## EXECUTED in the authoring sandbox (Ubuntu x86_64, g++ 13.3; no Flutter/Dart/NDK/network)
`scripts/run_host_tests.sh` (all passing on the last run):
- `utf8_test`: strict UTF-8 sanitizer: valid sequences, carry across calls, truncated tails
  dropped on final, malformed (stray continuation, overlong, surrogate, >U+10FFFF) -> U+FFFD.
- `bridge_test` under AddressSanitizer+UBSan and under ThreadSanitizer, against a FAKE
  llama (`native/tests/fake_llama.cpp`, hand-written). Covers: load validation and
  `*out == NULL`; generation, ordering, backpressure; prompt > n_batch chunked; prompt too
  long; template larger than the initial buffer; unsupported / missing template;
  cross-thread stop and reuse; BUSY; small-buffer semantics; free while the producer is
  blocked; exception containment; generation ending in the MIDDLE of a multi-byte character
  (nothing invalid reaches the consumer); malformed model bytes sanitized; sampler init
  failures (null chain/temp/dist/greedy) handled and not leaked; ABI validation (role names,
  NaN/inf/negative/huge temperature, bad counts, oversized messages, null pointers, path
  length, thread/ctx limits); RAII: exceptions thrown after the model and after the context
  exist leave zero live objects; no leaks at exit.
- v0.4 position tests (fake llama emulating "positions continue after the cache, stay
  below n_ctx, explicit positions required, logits only where sampled"): prompt of 5,
  512, 513, 1024, 1500 tokens; max_new cut; second run on the same engine restarts at 0;
  reuse after stop; context-edge run; decode failure on a later chunk and on a generated
  token; batch allocation failure; zero live objects afterwards (batches included).
- `scripts/mutation_check.sh`: 7 injected bugs (position reset to zero, frozen n_past in
  prompt / generation, missing or excessive logits, no cache clear, wrong seq id), each
  in a strict and a permissive fake mode: 14/14 killed on the last run.
- Static guard in run_host_tests.sh: the bridge must not call llama_batch_get_one.
- `lai_poc` smoke run against the fake (its printed rates are the fake's; meaningless).
- Crude static checks of the Dart sources: bracket balance and import-path existence.
  This is NOT compilation or analysis.

## What the executed tests do NOT prove
Compatibility with real llama.cpp (API names/behaviour are assumed), real inference,
tokenization, chat templates, timing or memory.

## WRITTEN but NOT executed (no Dart toolchain here)
`flutter test` suites: chat repository (DB closed in tearDown), context builder, GGUF reader
(synthetic files), memory estimator/policy, ModelManager (single-model order, serialization,
refusals), ChatController (streaming, stop, mid-stream failure, load failure, background,
no auto-load, context too small) with a FAKE engine, DownloadManager against a local
HttpServer (verify, SHA mismatch, pause/resume with Range, ignored Range, changed
validator, cancel, unverified entry, no storage); v0.4 additions: `download_trust_test.dart`
(HTTPS->HTTP redirect refused, redirect loop, missing Location, HTTPS redirect followed,
host allowlist, gzip refused, wrong Content-Length, overrun, early end, bad Content-Range,
stall timeout, cancel during SHA-256 verification, complete .part verified offline,
cancellable hasher) using a throwaway localhost TLS fixture in test/fixtures;
`test/engine/ffi_engine_lifecycle_test.dart` (missing library, initError, exit before
ready, death during load / generation, cancel stops generation, dispose ordering) using
double worker isolates.
All Dart code, including `FfiInferenceEngine`, has never been compiled or analyzed.

## NOT executed at all
Gradle/NDK/CMake build of llama.cpp, APK build/install, anything on LT M50 or any device,
real model download, real import via the picker, real memory-pressure and lifecycle behaviour.

## Acceptance checklist (spec section 19): 0 of 14 verified.

## Measurements to record (all pending, real runs only)
tokens/s (engine counter), first-token time, RAM (RSS delta recorded by the app), load time,
long-session stability.

## v0.4.2: real llama.cpp v1.0.0 (b1b770d90d94cad9e9ea5b993bdbc383a522fb28)
Environment: x86-64 Linux host, g++, CPU only. Logs: docs/evidence/.

EXECUTED (real libllama, SYNTHETIC random-weights GGUF with the real Qwen2 tokenizer):
- Pin check, API audit (42 symbols, 0 missing, 0 deprecated), compile and link without fake_llama.
- lai_real_test: load; Arabic prompt streamed in 47 pieces with valid UTF-8; greedy determinism across
  two runs on one engine (cache clear + positions verified by real llama_decode); 704-token prompt
  across several n_batch chunks; stop from another thread then reuse; context edge n_ctx=256
  (12+244=256 tokens, no error); prompt larger than context refused (code 7); lai_free during
  generation. Result PASS, also under ASan+UBSan+LSan (0 reports; LSan verified active).
- scripts/mutation_check_real.sh: 6/7 mutants killed (the library itself reports "inconsistent
  sequence positions" / "invalid seq_id"; a missing logits flag aborts the process). The 7th
  (logits on every prompt token) survives by design: no correctness impact, +600 MB peak RSS
  (105 -> 706 MB on this host); killed only by the fake-based test.
- Fake-llama suite (ASan/UBSan, TSan, mutants) re-run: PASS.

NOT EXECUTED:
- Any REAL language model (huggingface.co is blocked here). The synthetic model's output is
  meaningless: nothing is known about Arabic answer quality, speed, memory or the real Qwen2.5
  chat template.
- Android arm64-v8a build, lai_poc for Android, APK, LT M50 (dl.google.com blocked; no NDK).
- TSan on the real stack. Dart: flutter analyze / flutter test (no SDK).

# Changelog

## 0.4.9 (UI/UX Redesign & Modern Arabic Experience)
- Implemented comprehensive Material 3 UI/UX overhaul tailored for Arabic RTL layout and offline local intelligence.
- Created HomeScreen: Dashboard displaying active model status badge (Ready, Loading, Unloaded, Error), context & RAM info, direct "بدء محادثة جديدة" action, recent conversations list with relative Arabic dates, and offline privacy reassurance.
- Created ConversationsScreen: Dedicated full conversation manager with search/filter, formatted dates (اليوم، أمس، التاريخ), single chat delete with confirmation, and delete all conversations with guard against deletion during generation.
- Redesigned ChatScreen: Modern user/assistant message bubbles with role avatars, copy-to-clipboard button, selectable text, Arabic suggestion chips on empty state, prominent generation progress indicator with stop generation button, and clear disabled send states when model is not ready.
- Redesigned SettingsScreen: Categorized cards for Installed Models, Manual GGUF Import, Approved 5-Model Catalog with progress and gated notice, Memory-safe Context Length selector, Temperature slider, and Device & System RAM diagnostics.
- Added MainNavigationScreen: Material 3 NavigationBar with 4 primary destinations (Home, Chat, Conversations, Settings) with state-preserving IndexedStack.
- Added ArabicDateFormatter for lightweight, zero-dependency Arabic relative date and time formatting.
- Added widget and unit tests for UI screens and Arabic date formatting.

## 0.4.8 (Model Management & Model Catalog)
- Approved 5-model catalog integrated into assets/model_catalog.json with full schema (RightNow-Arabic-0.5B-Turbo, Qwen3-0.6B, Qwen3-1.7B, Qwen3-4B, Jais-2-8B-Chat).
- CatalogEntry model enriched with description, family, version, license, quantization, RAM requirements, and verified/gated status flags.
- ModelManager updated with 12 canonical lifecycle states (noModel, downloading, downloadPaused, downloaded, verifying, verified, loading, ready, generating, unloading, error, incompatible) and safe sequential model switching with generation stop and engine unload guards.
- SettingsScreen redesigned with model cards for the 5 models, direct download/pause/resume/cancel controls for verified models, gated notice for Jais-2-8B-Chat, and local GGUF file import.
- Arabic quality and evaluation test suite added covering MSA, daily conversational, and Yemeni dialect prompts, UTF-8 streaming boundary safety, and RTL preservation.
- Full suite of unit tests for model catalog, GGUF importer, model manager switching, and lifecycle safety.

## 0.4.7 (Core Stability & Chat Invariants)
- Added ChatUiState enum (noModel, loading, ready, generating, error) distinguishing all UI states.
- Disabled message input and send button when no active model is loaded with clear Arabic explanations.
- Added confirmation dialogs for single chat deletion and deleting all conversations with Arabic messages.
- Generation safety invariants: blocked deletion during generation, safe stop preserving partial text as interrupted.
- Auto-naming conversations from first user message up to 40 characters without altering existing titles.
- Prevented saving messages if model loading fails; preserved prior chat integrity across model failures.

## 0.4.5 (validator hardening, chat-template gate, Android checks; NOT built/run for Android; Dart NOT compiled)
- Catalog gate rewritten fail-closed (real URL parsing, type confusion, evidence path traversal/symlink, duplicate keys, NaN,
  never a traceback); tests 824 PASS; the OLD v0.4.4 validator fails 75 of them.
- Chat-template gate in Dart (`GgufInfo` -> importer/manager, before any load/copy): missing / invalid / unsupported / supported,
  Arabic messages. Rules extracted from the pinned llama.cpp into `scripts/chat_template_rules.json`; Python port agrees with the
  real libllama on 166/166 templates. Dart code is UNCOMPILED. Engine `LAI_ERR_TEMPLATE` remains the final authority.
- Android verification: `elf_check.py` (all exports lai_*, Dart symbols exported, all PT_LOAD >=16KB, aarch64), `ndk_detect.py`
  (env/local.properties/SDK/ndkVersion with conflict detection), `android_verify.sh` rewritten (per-stage logs, failed-stage summary).
  Never run on a real Android build.
- Build: `native/lai_exports.map` version script. A real host build exported 18 libstdc++ symbols besides the 9 lai_*; now exactly 9.
  `lai_bridge.cpp/.h` unchanged. llama.cpp pin unchanged.
- Report: docs/REPORT_V0.4.5.md. Evidence: docs/evidence/v045/.

## 0.4.2 (bridge compiled and run against REAL llama.cpp v1.0.0 on a host; not Android)
- Pin verified: v1.0.0 == b1b770d90d94cad9e9ea5b993bdbc383a522fb28 (tag peels to this commit).
- API drift found by audit + real compile and fixed in lai_bridge.cpp:
  `llama_model_params.use_mmap` was removed -> `load_mode = LLAMA_LOAD_MODE_MMAP`;
  `llama_tokenize` can return INT32_MIN (overflow): no longer negated (was undefined behaviour);
  token_to_piece retry buffer capped.
- Build fixes found by the real build: libllama/ggml are static inside a shared .so -> PIC required;
  `LLAMA_CURL` no longer exists (-> `LLAMA_OPENSSL OFF`, plus COMMON/TOOLS/APP OFF);
  `--exclude-libs,ALL` so only the 9 `lai_*` functions are exported.
- Test driver bug found under ASan: LAI_NEXT_TIMEOUT was treated as an error. Fixed.
- New: scripts make_synthetic_gguf.py, mutation_check_real.sh; fetch script now shallow + tag check;
  run_real_host.sh honours LAI_LLAMA_DIR / LAI_BUILD_DIR; audit script no longer reports false
  DEPRECATED hits; fake llama mirrors `load_mode` and poisons batch memory like real malloc.
- Evidence: docs/evidence/. Report: docs/REPORT_V0.4.2.md.

## 0.4.1 (pin recorded; bridge still NOT compiled against real llama.cpp)
- Pinned llama.cpp v1.0.0 = b1b770d90d94cad9e9ea5b993bdbc383a522fb28 (third_party/llama.cpp.pin).
- Added scripts: fetch_llama_cpp.sh (SHA + tag check), audit_llama_api.sh (names/fields vs
  real llama.h), run_real_host.sh, real-model driver native/tests/real_engine_test.cpp
  (Arabic streaming, greedy determinism, long prompt, cross-thread stop, reuse, free during
  generation). Driver self-checked against the FAKE only. No API fixes were possible: the
  real header was unavailable.

## 0.4.0 (still unbuilt for Android; NOT compiled against any real llama.cpp)
- Bridge: explicit token positions. `llama_batch_get_one` removed; batches are built with
  `llama_batch_init`/`llama_batch_free` (RAII) with explicit pos / seq_id / logits; the
  bridge tracks `n_past` for prompt chunks and generated tokens; logits requested only
  for the last prompt token and each generated token. The batch API usage is UNVERIFIED
  against a real llama.h.
- Tests: fake llama emulates position continuity; position tests + mutation check
  (`scripts/mutation_check.sh`). FFI lifecycle tests and download-trust tests written,
  not executed.
- FFI worker: errors contained and answered per request; worker death/exit/initError fail
  all pending requests and open streams; stream cancel stops generation; stop targets a
  generation id; shutdown answered only after lai_free; unload waits for in-flight load.
- Download: manual redirects (HTTPS-only per hop, max hops, optional host allowlist),
  identity encoding, size/Content-Range checks, overrun cut-off, idle timeout, abortable
  connect, cancel works during SHA-256 verification (cancellable hasher), complete
  partial verified without re-download.

## 0.3.0 (still unbuilt for Android; native logic host-tested against a fake llama)
- Bridge: strict UTF-8 only (flush drops truncated characters, malformed -> U+FFFD);
  sampler init results checked; full ABI input validation; RAII for model/context/samplers.
- Dart: real FFI engine (worker isolate, copy-based polling), ModelManager, download
  (resume/verify/pause/cancel), import, SHA-256, GGUF header reader, memory estimator and
  policy, context builder, streaming ChatController, lifecycle + trim-memory handling,
  settings screen wiring, MainActivity.kt, schema v2.
- Catalog entry intentionally unverified/not downloadable.
## 0.2.0
- Async queue API, chunked prompt evaluation, host tests with fake llama, no forced -march.
## 0.1.0
- Skeleton.

## real-gguf attempt (2026-11-22)
- Added `scripts/verify_gguf.py`; added `docs/REPORT_REAL_GGUF_TEST.md` and evidence 10/11.
- Real model could not be downloaded (egress policy); no engine behaviour changed, no real-model result claimed.

## real-gguf run (2026-11-22, round 3)
- Ran the real bridge + libllama v1.0.0 on an UNVERIFIED-provenance Gemma 3 270M GGUF (test-only, not in catalog): PASS incl. ASan/UBSan/LSan. Output quality is poor (base model).
- verify_gguf.py: fixed offset bug in truncation check; missing chat template is a WARN; template family is informational.
- Bridge unchanged. Evidence: docs/evidence/gemma/. Report: docs/REPORT_REAL_GGUF_TEST.md.

## v0.4.4 (2026-11-22) - investigation + readiness, no bridge change
- Logit difference bridge vs llama-simple explained: different ggml CPU build variant (NATIVE ON vs OFF); identical logits within one build. See docs/evidence/logits.
- aarch64-linux-musl compile check of bridge + pinned llama.cpp via zig (link fails on zig's --exclude-libs; NOT Android).
- Added catalog release gate + self-test, android_verify.sh (not yet run), docs/REPORT_V0.4.4_ANDROID_READINESS.md.
- Nothing executed on Android; no Flutter/Dart/NDK available.

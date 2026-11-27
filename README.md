# بسيط (Local AI Assistant)

Android (ARM64) app: offline Arabic chat with GGUF models through llama.cpp.
Flutter UI, SQLite storage, CPU only, one model in memory at a time.

## Status (v0.4.2)
All planned features exist as source (chat, streaming, SQLite, FFI engine, model manager,
download/import/SHA-256, memory policy, lifecycle). llama.cpp is pinned to v1.0.0
(b1b770d90d94cad9e9ea5b993bdbc383a522fb28). The native bridge now compiles and runs against the
REAL llama.cpp on an x86-64 Linux host, but only with a synthetic random-weights GGUF: no real
language model has been run, nothing has been built for Android arm64-v8a, no APK exists, and the
Dart code has never been compiled (no Flutter SDK). See TESTING.md and docs/REPORT_V0.4.2.md.

## Layout
lib/presentation, lib/application, lib/data, lib/engine (abstract interface),
native/ (C ABI bridge + CMake + PoC CLI), android/, docs in repo root.

## Hard rules (from the spec)
No cloud, accounts, telemetry, GPU, extra screens or advanced sampling options.
INTERNET permission exists only for optional model download.

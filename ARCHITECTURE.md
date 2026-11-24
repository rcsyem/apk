# Architecture (v0.4)

Layers: Presentation (Flutter) -> Application (ChangeNotifier controllers) ->
Data (SQLite) / Engine (`InferenceEngine`) / Model Management / Native Android.
The UI never imports FFI types.

```
lib/presentation   chat + settings screens (Arabic, RTL)
lib/application    ChatController, AppSettings, ContextBuilder, AsyncLock, error messages
lib/data           AppDatabase (schema v2), ChatRepository, ModelRepository
lib/engine         InferenceEngine (abstract), FfiInferenceEngine, engine_worker (isolate), ffi_bindings
lib/models         ModelManager, DownloadManager, ModelImporter, GgufInfo, ModelCatalog, sha256
lib/memory         MemoryEstimator, MemoryPolicy, MemoryCalibration
lib/native         NativeInfo (MethodChannel + /proc fallbacks)
native/            C ABI bridge (lai_bridge), CMake, PoC CLI, host tests with a FAKE llama
android/           Gradle, manifest, MainActivity.kt (memory info, free storage, trim events)
```

## Engine binding: FFI (provisional until a real build + real GGUF run succeed)
C ABI (`native/include/lai_bridge.h`): `lai_load`, `lai_generate_start`, `lai_next`,
`lai_result`, `lai_stop`, `lai_stats`, `lai_count_prompt_tokens`, `lai_free`.
- Generation runs on a native worker thread that fills a bounded queue (256 pieces,
  backpressure). No callbacks into Dart, no native-stack pointers shared.
- Only strictly valid UTF-8 is queued: malformed bytes become U+FFFD; a truncated
  trailing character at the end of generation is dropped (never forwarded).
- `lai_next` COPIES into a caller-owned buffer. A single worker isolate
  (`engine_worker.dart`) owns the engine pointer, polls `lai_next` (20 ms timeout),
  yields to its event loop between polls (so `stop` is processed) and forwards decoded
  Strings to the UI isolate through a `SendPort`.
- Input validation at the ABI: roles in {system,user,assistant}, finite temperature in
  [0,2], bounded message count/sizes, int32-safe conversions, `*out = NULL` on load.
- RAII owns model, context and samplers; every export is exception-guarded.
- Sampler creation results are checked individually; none is added as nullptr.
Fallback if FFI fails on device: JNI behind the same `InferenceEngine` interface.

## Model management (one model in memory)
`ModelManager` serializes everything through an `AsyncLock`. Switching = `stop` ->
`unload` (awaited, native memory freed) -> memory check -> `load`. Changing the context
length reloads. The model is never auto-loaded at app start; it loads on the first send.

## Downloads and import
`DownloadManager`: HTTPS only, resumable (HTTP Range + `If-Range`) only when a strong
validator (ETag, else Last-Modified) was recorded at the start; otherwise restart from
zero. Pause keeps the `.part` file, cancel deletes it, SHA-256 verified before the file
becomes a model, mismatch deletes it. Storage space checked first. Catalog entries
without verified url/size/sha256 are not downloadable. `ModelImporter` validates the GGUF
header, moves/copies into app-private storage, records SHA-256.

## Context policy
Full history stays in SQLite. `ContextBuilder.fit` binary-searches the longest suffix of
whole messages whose templated token count (real `lai_count_prompt_tokens`) fits
`n_ctx - max_new - 16`; it never starts with a dangling assistant reply and always keeps
the newest message. The KV cache is cleared and the prompt re-evaluated each turn.

## Memory estimation (components kept separate; method documented, NOT yet calibrated)
1. File size (disk, mmap-backed; informational).
2. Resident model memory: upper bound = file size (to be replaced by measured RSS delta).
3. KV cache = 2 * layers * n_ctx * kv_heads * head_dim * 2 bytes, from GGUF metadata
   (flagged approximate when metadata is missing).
4. Compute/context buffers: placeholder constant until measured.
5. App memory: already reflected in the OS's available-memory figure.
Decision: deny if `required + reserve > available`; warn if Android reports low memory.
`reserve = measured reserve, else max(Android threshold, placeholder)`. No fixed
percentage rule. After each load the app records the RSS delta locally
(`measure.last_load` in SQLite) to support calibration. The placeholders
(`kPlaceholder*`) are NOT measurements.

## Lifecycle
`paused`/`detached` and `TRIM_MEMORY_RUNNING_CRITICAL` (>= 15): stop generation, wait
for the stream to end, persist the partial reply (`interrupted`), then unload the model.
Partial text is also persisted every ~400 ms while streaming, because cleanup at force
kill is not relied upon.

## Token positions (v0.4)
The bridge owns `n_past` (tokens cached for sequence 0). Each generation clears the cache,
then decodes the prompt in chunks of <= n_batch at positions n_past.., then each generated
token at n_past. Batches come from `llama_batch_init` with explicit pos/seq_id/logits;
`llama_batch_get_one` is not used. Compiled and run against llama.cpp v1.0.0 on a host with a
synthetic model (real llama_decode validated the positions); not yet on Android or a real model.

## Worker lifecycle (v0.4)
Every request id receives one terminal answer. Worker exit/error fails pending requests and
open streams (state -> error). If the worker dies unexpectedly its native engine cannot be
freed from the main isolate; that memory remains until process exit. Shutdown is answered
only after lai_free.

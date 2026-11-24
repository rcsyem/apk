# Progress report v0.3

## Bridge fixes requested (1-4): written AND executed on host against a fake llama
1. Emitter/flush: strict UTF-8 only; truncated tail dropped; test ends generation mid-character.
2. Sampler results checked (null chain/temp/dist/greedy) without leaks; tested via fault injection.
3. ABI validation (roles, temperature, sizes, int32 conversions, limits); tested.
4. RAII for model/context/samplers; exceptions during load leave no live objects; tested.

## New Dart features: written only, never compiled or run
FFI engine + worker isolate, ModelManager, DownloadManager, ModelImporter, GGUF reader,
SHA-256, memory estimator/policy, context builder, streaming ChatController, lifecycle and
trim-memory handling, settings UI, MainActivity.kt, DB schema v2, tests (unrun).

## Open / unverified
llama.cpp commit not pinned; real API compatibility unknown; Flutter/Android build never
run; catalog entry unverified (no download offered); memory constants are placeholders;
nothing run on LT M50. Acceptance checklist: 0 of 14.

## Next gate
Pin llama.cpp, compile the bridge, run `lai_poc` with a real GGUF on ARM64, then `flutter analyze/test`
and `flutter build apk`. Only then can FFI be adopted as final.

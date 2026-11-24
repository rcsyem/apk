# Model catalog

`assets/model_catalog.json` is the fixed built-in catalog. The only candidate entry,
Qwen2.5-0.5B-Instruct Q4_K_M, is shipped with `"verified": false` and null url/size/sha256,
because none of these could be verified while authoring (no network). The app therefore
does NOT offer to download it; manual GGUF import works.

To enable a download, fill ALL fields from a trusted source and set `"verified": true`:
`url` (https), `sizeBytes`, `sha256` (64 hex), `license`. Also check the embedded chat
template and compatibility with the pinned llama.cpp. No second model before the first
is proven on a device. GGUF files are never bundled in the APK.

## Release gate (v0.4.5; same required fields as v0.4.4, validator hardened)
`python3 -I scripts/validate_catalog.py` must pass before every build (it is part of `scripts/run_host_tests.sh`
and `scripts/android_verify.sh`). A `verified: true` entry needs: https url, sizeBytes, sha256, license + licenseUrl,
publisher + sourceRepo, `provenance: "publisher-verified"`, `instruct: true`, `chatTemplate {family, presentInGguf: true}`
and `evidence {llamaCppCommit == pinned, engineTest: "PASS", report: <repo file that mentions the sha256>}`.
Experimental files (e.g. the unverified-provenance Gemma 3 270M used only for engine testing) are deny-listed and must never be added.
Unknown extra keys are ignored by the Dart parser, so these fields do not change the app's parsing (not compiled here).

Hardening in v0.4.5: real URL parsing (https, hostname, no user-info/IP/port/fragment), every field type-checked, evidence path must stay
inside the repo (no `..`/symlink escape) and must mention the entry's sha256, duplicate JSON keys/NaN rejected; the gate never raises.
`chatTemplate.family` must be one of chatml, gemma, llama3, mistral, phi3.

## Chat-template gate in the app (v0.4.5, Dart code NOT compiled)
Before import or load the app reads `tokenizer.chat_template` from the GGUF header: missing, empty/invalid, unsupported by the pinned
llama.cpp, or supported. Only "supported" proceeds. This is a preliminary metadata check; the engine's `LAI_ERR_TEMPLATE` is final.
Regenerate `lib/models/chat_template_rules.g.dart` (`scripts/gen_dart_chat_template_rules.py`) whenever the llama.cpp pin changes.

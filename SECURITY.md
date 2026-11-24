# Security & privacy

- Chats, prompts and models stay on the device. No analytics, telemetry or crash reporting.
- Network: `INTERNET` is used only by `DownloadManager`, HTTPS only, to the URL of a verified
  catalog entry (none enabled yet). No other network calls exist in the code.
- Downloads: SHA-256 verified before a file becomes a model; mismatch deletes it; partial
  files deleted on cancel; resume only with Range + strong validator.
- Imported GGUF files are validated and moved/copied into app-private storage, never uploaded.
- Memory/storage queries (`MainActivity.kt`) are local; measurements are stored in local SQLite only.
- `allowBackup=false`. No accounts, no cloud sync.

## Download trust (v0.4)
HTTPS on every hop, manual redirects (max 5), identity encoding, size/range checks,
no bytes beyond the pinned size, idle timeout, pinned SHA-256 as final authority.
`test/fixtures/test_key.pem` is a throwaway self-signed localhost key used only by tests.

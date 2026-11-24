# Changes in v0.2.0 (answers to review items 1-9)

| # | Fix | Written | Executed |
|---|-----|---------|----------|
| 1 | No forced `-march`; opt-in `LAI_EXTRA_ARCH_FLAGS` | yes | grep only; no Android build |
| 2 | Template buffer: try, grow to reported size, verify; clear errors | yes | yes (fake, incl. >4096 case) |
| 3 | Prompt chunked by n_batch | yes | yes (fake rejects oversize batch) |
| 4 | Safe transport: native thread + bounded queue + copying `lai_next`, no Dart callbacks | yes | yes (fake, ASan/UBSan/TSan) |
| 5 | PoC: async, cross-thread stop, join stopper, free after end | yes | smoke only, vs fake |
| 6 | Engine token counters; pieces reported separately | yes | smoke only |
| 7 | Exception guards, validation, `*out = NULL` | yes | yes (fake exception test) |
| 8 | DB closed in `tearDown` | yes | no (no Dart) |
| 9 | Android styles/RTL/icon/manifest review | yes | no (no Gradle) |

Fake-llama tests do not establish compatibility with real llama.cpp.

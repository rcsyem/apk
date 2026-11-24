# third_party

`llama.cpp` goes in `third_party/llama.cpp` at the commit pinned in `llama.cpp.pin`
(v1.0.0, b1b770d90d94cad9e9ea5b993bdbc383a522fb28 — chosen by the project owner; never
master/nightly). `scripts/fetch_llama_cpp.sh` checks it out detached and verifies the SHA
and that the tag resolves to the same commit.

STATUS (2026-11-22): fetched, SHA-verified, audited and compiled on a host; see TESTING.md.
The checkout is not part of the ZIP; run `scripts/fetch_llama_cpp.sh`.

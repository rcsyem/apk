#!/usr/bin/env python3
"""Verifies a downloaded GGUF BEFORE it is used: size, SHA-256, header, metadata, tokenizer,
chat template. Read-only; never loads weights into memory (mmap via gguf-py).

Usage (run with -I; paths are explicit arguments):
  python3 -I verify_gguf.py <llama.cpp checkout (for gguf-py)> <model.gguf> [expected_sha256] [expected_size]

Exit code: 0 = all requested checks passed, 1 = a check failed, 2 = usage / unreadable file.
The expected SHA-256 / size must come from the model publisher's page; this script never
invents them. Without an expected hash it only REPORTS the computed one (not a pass).
"""
import hashlib, os, struct, sys

if len(sys.argv) < 3:
    print(__doc__); sys.exit(2)
llama_dir, path = sys.argv[1], sys.argv[2]
exp_sha = sys.argv[3].lower() if len(sys.argv) > 3 and sys.argv[3] else None
exp_size = int(sys.argv[4]) if len(sys.argv) > 4 else None
sys.path.insert(0, os.path.join(llama_dir, "gguf-py"))
import gguf  # noqa: E402

fails = []
def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}")
    if not ok: fails.append(name)

size = os.path.getsize(path)
print(f"file: {os.path.basename(path)}\nsize_bytes: {size}")
h = hashlib.sha256()
with open(path, "rb") as f:
    magic = f.read(4)
    f.seek(0)
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
sha = h.hexdigest()
print(f"sha256: {sha}")
check("GGUF magic", magic == b"GGUF", repr(magic))
if exp_size is not None: check("size matches publisher", size == exp_size, f"{size} vs {exp_size}")
if exp_sha: check("sha256 matches publisher", sha == exp_sha)
else: print("[NOTE] no expected sha256 given: hash reported, NOT verified")

if magic != b"GGUF":
    print("not a GGUF file; stopping"); sys.exit(1)
try:
    r = gguf.GGUFReader(path)
except Exception as e:  # truncated / corrupt header
    check("GGUF parses", False, repr(e)); sys.exit(1)
def get(k):
    f = r.fields.get(k)
    return f.contents() if f is not None else None

arch = get("general.architecture")
print("architecture:", arch)
for k in ("general.name", "general.basename", "general.size_label", "general.license",
          "general.finetune", "general.file_type", "general.quantization_version"):
    print(f"{k}:", get(k))
if arch:
    for k in ("context_length", "embedding_length", "block_count", "attention.head_count",
              "attention.head_count_kv"):
        print(f"{arch}.{k}:", get(f"{arch}.{k}"))
toks = get("tokenizer.ggml.tokens")
print("tokenizer.ggml.model:", get("tokenizer.ggml.model"), "| pre:", get("tokenizer.ggml.pre"))
print("vocab_size:", len(toks) if toks is not None else None)
for k in ("bos_token_id", "eos_token_id", "padding_token_id"):
    print(f"tokenizer.ggml.{k}:", get(f"tokenizer.ggml.{k}"))
check("tokenizer tokens present", toks is not None and len(toks) > 1000)

tpl = get("tokenizer.chat_template")
if not tpl: print("[WARN] no tokenizer.chat_template (normal for BASE models; the app must not assume a template)")
if tpl:
    print("--- chat_template (verbatim) ---\n" + tpl + "\n--- end ---")
    fam = "ChatML" if "<|im_start|>" in tpl else "Gemma" if "<start_of_turn>" in tpl else "other/unknown"
    print("chat_template family:", fam, "(informational; compare with the bridge/context_builder expectations)")

tensors = r.tensors
total = sum(t.n_bytes for t in tensors)
print("tensor_count:", len(tensors), "| tensor_bytes:", total)
types = {}
for t in tensors: types[t.tensor_type.name] = types.get(t.tensor_type.name, 0) + 1
print("tensor_types:", types)
if tensors:
    last = max(tensors, key=lambda t: t.data_offset)
    end = last.data_offset + last.n_bytes   # gguf-py's ReaderTensor.data_offset is already absolute
    check("file covers all tensor data (not truncated)", end <= size, f"end={end} size={size}")
else:
    print("[NOTE] no tensors (vocab-only file)")
sys.exit(1 if fails else 0)

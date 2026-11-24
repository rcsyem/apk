#!/usr/bin/env python3
"""Builds a TINY *synthetic* GGUF for plumbing tests of the native bridge.

What it is: a llama-architecture GGUF with RANDOM weights (2 layers, 64-dim) that reuses a
REAL tokenizer (the vocab-only GGUF shipped in llama.cpp, e.g. ggml-vocab-qwen2.gguf) and a
ChatML-style chat template. It loads and decodes with the real llama.cpp.

What it is NOT: a language model. Its output is meaningless. It proves nothing about answer
quality, Arabic fluency, speed, memory use or the real Qwen2.5 chat template. It exists so the
real load / tokenize / template / decode / sample / stop / free paths can be exercised when no
real model is available. Real-model acceptance (scripts/run_real_host.sh) is still required.

Usage (run with `python3 -I`; the paths are explicit arguments):
  python3 -I make_synthetic_gguf.py <llama.cpp checkout> <vocab.gguf> <out.gguf> [seed]
"""
import sys, os
import numpy as np

llama_dir, vocab_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
seed = int(sys.argv[4]) if len(sys.argv) > 4 else 1234
sys.path.insert(0, os.path.join(llama_dir, "gguf-py"))
import gguf  # noqa: E402  (official gguf-py from the pinned checkout)

CHATML = ("{% for message in messages %}{{'<|im_start|>' + message['role'] + '\\n' + "
          "message['content'] + '<|im_end|>' + '\\n'}}{% endfor %}"
          "{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}{% endif %}")

r = gguf.GGUFReader(vocab_path)

def field(name):
    f = r.fields[name]
    return f

def scalar(name):
    f = field(name)
    return f.contents()

tokens = field("tokenizer.ggml.tokens").contents()
types = field("tokenizer.ggml.token_type").contents()
merges = field("tokenizer.ggml.merges").contents() if "tokenizer.ggml.merges" in r.fields else None
model = scalar("tokenizer.ggml.model")
pre = scalar("tokenizer.ggml.pre") if "tokenizer.ggml.pre" in r.fields else None
n_vocab = len(tokens)

n_embd, n_layer, n_head, n_head_kv, n_ff, n_ctx = 64, 2, 4, 2, 128, 4096
head_dim = n_embd // n_head
rng = np.random.default_rng(seed)

w = gguf.GGUFWriter(out_path, "llama")
w.add_name("lai-synthetic-random-weights")
w.add_context_length(n_ctx)
w.add_embedding_length(n_embd)
w.add_block_count(n_layer)
w.add_feed_forward_length(n_ff)
w.add_head_count(n_head)
w.add_head_count_kv(n_head_kv)
w.add_rope_dimension_count(head_dim)
w.add_layer_norm_rms_eps(1e-5)
w.add_vocab_size(n_vocab)
w.add_file_type(gguf.LlamaFileType.MOSTLY_F16)

w.add_tokenizer_model(model)
if pre is not None:
    w.add_tokenizer_pre(pre)
w.add_token_list(tokens)
w.add_token_types(types)
if merges is not None:
    w.add_token_merges(merges)
for key, setter in (("tokenizer.ggml.bos_token_id", w.add_bos_token_id),
                    ("tokenizer.ggml.eos_token_id", w.add_eos_token_id),
                    ("tokenizer.ggml.padding_token_id", w.add_pad_token_id)):
    if key in r.fields:
        setter(int(scalar(key)))
w.add_chat_template(CHATML)

def f16(*shape, std=0.05):
    return (rng.standard_normal(shape) * std).astype(np.float16)

def ones(n):
    return np.ones(n, dtype=np.float32)

# gguf tensor shapes are given numpy-style (rows, cols) = (out_features, in_features)
w.add_tensor("token_embd.weight", f16(n_vocab, n_embd))
w.add_tensor("output_norm.weight", ones(n_embd))
w.add_tensor("output.weight", f16(n_vocab, n_embd))
for i in range(n_layer):
    p = f"blk.{i}."
    w.add_tensor(p + "attn_norm.weight", ones(n_embd))
    w.add_tensor(p + "attn_q.weight", f16(n_head * head_dim, n_embd))
    w.add_tensor(p + "attn_k.weight", f16(n_head_kv * head_dim, n_embd))
    w.add_tensor(p + "attn_v.weight", f16(n_head_kv * head_dim, n_embd))
    w.add_tensor(p + "attn_output.weight", f16(n_embd, n_head * head_dim))
    w.add_tensor(p + "ffn_norm.weight", ones(n_embd))
    w.add_tensor(p + "ffn_gate.weight", f16(n_ff, n_embd))
    w.add_tensor(p + "ffn_up.weight", f16(n_ff, n_embd))
    w.add_tensor(p + "ffn_down.weight", f16(n_embd, n_ff))

w.write_header_to_file()
w.write_kv_data_to_file()
w.write_tensors_to_file()
w.close()
print(f"wrote {out_path}: vocab={n_vocab} tokenizer={model}/{pre} random weights, seed={seed}")

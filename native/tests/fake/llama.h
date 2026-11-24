// TEST DOUBLE ONLY. A minimal fake of the llama.h subset used by lai_bridge.cpp,
// with a fake implementation in ../fake_llama.cpp. Not llama.cpp.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <vector>
extern "C" {
typedef int32_t llama_token;
typedef int32_t llama_pos;
typedef int32_t llama_seq_id;
struct llama_model; struct llama_context; struct llama_vocab; struct llama_sampler; struct llama_memory_i;
typedef llama_memory_i *llama_memory_t;
enum llama_load_mode { LLAMA_LOAD_MODE_AUTO = -1, LLAMA_LOAD_MODE_NONE = 0, LLAMA_LOAD_MODE_MMAP = 1, LLAMA_LOAD_MODE_MLOCK = 2, LLAMA_LOAD_MODE_MMAP_MLOCK = 3, LLAMA_LOAD_MODE_DIRECT_IO = 4 };
// Mirrors the v1.0.0 field that matters here: load_mode replaced the removed use_mmap boolean.
struct llama_model_params { int32_t n_gpu_layers; llama_load_mode load_mode; };
struct llama_context_params { uint32_t n_ctx; uint32_t n_batch; uint32_t n_ubatch; int32_t n_threads; int32_t n_threads_batch; };
struct llama_sampler_chain_params { bool no_perf; };
struct llama_chat_message { const char *role; const char *content; };
// Field layout mirrors the real llama_batch (token, embd, pos, n_seq_id, seq_id, logits).
struct llama_batch { int32_t n_tokens; llama_token *token; float *embd; llama_pos *pos; int32_t *n_seq_id; llama_seq_id **seq_id; int8_t *logits; };
#define LLAMA_DEFAULT_SEED 0xFFFFFFFF
void llama_backend_init(void);
llama_model_params llama_model_default_params(void);
llama_context_params llama_context_default_params(void);
llama_model *llama_model_load_from_file(const char *, llama_model_params);
llama_context *llama_init_from_model(llama_model *, llama_context_params);
uint32_t llama_n_ctx(const llama_context *);
uint32_t llama_n_batch(const llama_context *);
const llama_vocab *llama_model_get_vocab(const llama_model *);
const char *llama_model_chat_template(const llama_model *, const char *);
int32_t llama_chat_apply_template(const char *, const llama_chat_message *, size_t, bool, char *, int32_t);
int32_t llama_tokenize(const llama_vocab *, const char *, int32_t, llama_token *, int32_t, bool, bool);
llama_memory_t llama_get_memory(const llama_context *);
void llama_memory_clear(llama_memory_t, bool);
llama_sampler_chain_params llama_sampler_chain_default_params(void);
llama_sampler *llama_sampler_chain_init(llama_sampler_chain_params);
void llama_sampler_chain_add(llama_sampler *, llama_sampler *);
llama_sampler *llama_sampler_init_greedy(void);
llama_sampler *llama_sampler_init_temp(float);
llama_sampler *llama_sampler_init_dist(uint32_t);
// llama_batch_get_one is DELIBERATELY absent from this fake: the bridge must not use it.
llama_batch llama_batch_init(int32_t n_tokens, int32_t embd, int32_t n_seq_max);
void llama_batch_free(llama_batch);
int32_t llama_decode(llama_context *, llama_batch);
llama_token llama_sampler_sample(llama_sampler *, llama_context *, int32_t);
bool llama_vocab_is_eog(const llama_vocab *, llama_token);
int32_t llama_token_to_piece(const llama_vocab *, llama_token, char *, int32_t, int32_t, bool);
void llama_sampler_free(llama_sampler *);
void llama_free(llama_context *);
void llama_model_free(llama_model *);
}
// test hooks
extern int g_fake_eog_after, g_fake_throw_on_decode, g_fake_max_batch_seen, g_fake_big_decodes, g_fake_live_objects;
extern int g_fake_fail_sampler;      // 1 chain-init null, 2 temp null, 3 dist null, 4 greedy null
extern int g_fake_throw_in_ctx;      // llama_init_from_model throws (after model loaded)
extern int g_fake_throw_in_vocab;    // llama_model_get_vocab throws (after ctx created)
extern const char *g_fake_raw;       // if set, token t emits g_fake_raw[t % len] (raw bytes)
extern int g_fake_raw_len;
extern int g_fake_tokenize_overflow; // llama_tokenize returns INT32_MIN (v1.0.0 overflow marker)
extern llama_load_mode g_fake_seen_load_mode; // load_mode the bridge passed to llama_model_load_from_file
extern int g_fake_fail_batch;        // llama_batch_init returns a batch with null arrays (alloc failure)
extern int g_fake_fail_decode_at;    // 1-based index of the decode call that returns 1 (0 = never)
// Position bookkeeping (emulates the rule that a sequence's new positions must
// continue exactly after the last cached one, and never reach n_ctx).
struct FakeDecode { int n_tokens; int first_pos; int last_pos; int n_logits; bool last_has_logits; bool seq_ok; bool contiguous; bool ok; };
extern std::vector<FakeDecode> g_fake_decodes;
extern int g_fake_null_pos_decodes;      // decodes submitted without explicit positions
extern int g_fake_pos_violations;        // pos != cached length, non-contiguous, or >= n_ctx
extern int g_fake_sample_without_logits; // sampled although the last decode requested no logits
extern int g_fake_clear_calls;
void fake_reset_decode_log();

// Fake llama implementation for host tests of lai_bridge.cpp (see fake/llama.h).
#include "llama.h"
#include <atomic>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

int g_fake_eog_after = 400;
int g_fake_throw_on_decode = 0;
int g_fake_max_batch_seen = 0;
int g_fake_big_decodes = 0;   // decodes with n_tokens > 1
int g_fake_live_objects = 0;  // leak check: models+contexts+samplers
int g_fake_fail_sampler = 0, g_fake_throw_in_ctx = 0, g_fake_throw_in_vocab = 0;
const char *g_fake_raw = nullptr;
int g_fake_raw_len = 0;
int g_fake_fail_batch = 0, g_fake_fail_decode_at = 0, g_fake_tokenize_overflow = 0;
llama_load_mode g_fake_seen_load_mode = LLAMA_LOAD_MODE_AUTO;
std::vector<FakeDecode> g_fake_decodes;
int g_fake_null_pos_decodes = 0, g_fake_pos_violations = 0, g_fake_sample_without_logits = 0, g_fake_clear_calls = 0;
static int g_decode_calls = 0;
static int g_kv_len = 0;            // tokens "cached" for sequence 0 (next valid position)
static bool g_last_had_logits = false;
static int g_ctx_n_ctx = 0;
void fake_reset_decode_log() {
  g_fake_decodes.clear();
  g_fake_null_pos_decodes = g_fake_pos_violations = g_fake_sample_without_logits = g_fake_clear_calls = 0;
  g_decode_calls = 0;
}

static const char *kCanned = "مرحبا بالعالم! ";  // multi-byte UTF-8 on purpose

struct llama_model { std::string path; };
struct llama_context { uint32_t n_ctx, n_batch; int sampled = 0; };
struct llama_vocab {};
struct llama_sampler { std::vector<llama_sampler *> kids; };
struct llama_memory_i {};
static llama_vocab g_vocab;
static llama_memory_i g_mem;
static int g_sampled = 0;  // reset by llama_memory_clear, like a fresh KV state

extern "C" {
void llama_backend_init(void) {}
llama_model_params llama_model_default_params(void) { return {0, LLAMA_LOAD_MODE_AUTO}; }
llama_context_params llama_context_default_params(void) { return {512, 512, 512, 4, 4}; }
llama_model *llama_model_load_from_file(const char *p, llama_model_params mp) {
  g_fake_seen_load_mode = mp.load_mode;
  std::string s(p);
  if (s.size() >= 8 && s.compare(s.size() - 8, 8, "bad.gguf") == 0) return nullptr;
  g_fake_live_objects++;
  return new llama_model{s};
}
llama_context *llama_init_from_model(llama_model *, llama_context_params cp) {
  if (g_fake_throw_in_ctx) throw std::runtime_error("fake ctx init exploded");
  if (cp.n_ctx > 20000) return nullptr;  // simulate OOM
  g_fake_live_objects++;
  auto *c = new llama_context();
  c->n_ctx = cp.n_ctx;
  g_ctx_n_ctx = (int)cp.n_ctx;
  c->n_batch = cp.n_batch;
  return c;
}
uint32_t llama_n_ctx(const llama_context *c) { return c->n_ctx; }
uint32_t llama_n_batch(const llama_context *c) { return c->n_batch; }
const llama_vocab *llama_model_get_vocab(const llama_model *) {
  if (g_fake_throw_in_vocab) throw std::runtime_error("fake vocab exploded");
  return &g_vocab;
}
const char *llama_model_chat_template(const llama_model *m, const char *) {
  return m->path.find("notemplate") != std::string::npos ? nullptr : "fake";
}
int32_t llama_chat_apply_template(const char *, const llama_chat_message *m, size_t n,
                                  bool, char *buf, int32_t len) {
  std::string out;
  for (size_t i = 0; i < n; i++) {
    if (std::string(m[i].content) == "BADTEMPLATE") return -1;
    out += std::string("<") + m[i].role + ">" + m[i].content + "</>";
  }
  out += "<assistant>";
  if (buf && len > 0) std::memcpy(buf, out.data(), std::min<size_t>(out.size(), (size_t)len));
  return (int32_t)out.size();  // real behaviour: total size, even if truncated
}
int32_t llama_tokenize(const llama_vocab *, const char *t, int32_t tl, llama_token *o,
                       int32_t max, bool, bool) {
  if (g_fake_tokenize_overflow) return INT32_MIN;
  if (tl > max) return -tl;
  for (int i = 0; i < tl; i++) o[i] = (unsigned char)t[i];
  return tl;
}
llama_memory_t llama_get_memory(const llama_context *) { return &g_mem; }
void llama_memory_clear(llama_memory_t, bool) { g_sampled = 0; g_kv_len = 0; g_last_had_logits = false; g_fake_clear_calls++; }
llama_sampler_chain_params llama_sampler_chain_default_params(void) { return {false}; }
static llama_sampler *mk(int fail_code) {
  if (g_fake_fail_sampler == fail_code) return nullptr;
  g_fake_live_objects++;
  return new llama_sampler();
}
llama_sampler *llama_sampler_chain_init(llama_sampler_chain_params) { return mk(1); }
void llama_sampler_chain_add(llama_sampler *c, llama_sampler *s) { c->kids.push_back(s); }
llama_sampler *llama_sampler_init_greedy(void) { return mk(4); }
llama_sampler *llama_sampler_init_temp(float) { return mk(2); }
llama_sampler *llama_sampler_init_dist(uint32_t) { return mk(3); }
llama_batch llama_batch_init(int32_t n, int32_t embd, int32_t n_seq_max) {
  (void)embd;
  llama_batch b{};
  g_fake_live_objects++;  // counted as one object; freed by llama_batch_free
  if (g_fake_fail_batch) return b;  // all-null arrays, like a failed allocation
  // Like the real llama_batch_init (malloc, "all members left uninitialized"): poison
  // instead of zero, so any field the bridge forgets to set makes the decode check fail.
  b.token = new llama_token[(size_t)n];
  b.pos = new llama_pos[(size_t)n];
  b.n_seq_id = new int32_t[(size_t)n];
  b.seq_id = new llama_seq_id *[(size_t)n + 1];
  for (int32_t i = 0; i < n; i++) b.seq_id[i] = new llama_seq_id[(size_t)n_seq_max];
  b.seq_id[n] = nullptr;
  b.logits = new int8_t[(size_t)n];
  for (int32_t i = 0; i < n; i++) {
    b.token[i] = -7; b.pos[i] = -7777; b.n_seq_id[i] = -7; b.logits[i] = 0x5A;
    for (int32_t k = 0; k < n_seq_max; k++) b.seq_id[i][k] = -7;
  }
  b.n_tokens = 0;
  return b;
}
void llama_batch_free(llama_batch b) {
  g_fake_live_objects--;
  delete[] b.token;
  delete[] b.pos;
  delete[] b.n_seq_id;
  if (b.seq_id) {
    for (int32_t i = 0; b.seq_id[i]; i++) delete[] b.seq_id[i];
    delete[] b.seq_id;
  }
  delete[] b.logits;
}
int32_t llama_decode(llama_context *c, llama_batch b) {
  if (g_fake_throw_on_decode) throw std::runtime_error("fake decode exploded");
  g_decode_calls++;
  if (b.n_tokens > g_fake_max_batch_seen) g_fake_max_batch_seen = b.n_tokens;
  if (b.n_tokens > 1) g_fake_big_decodes++;
  if (b.n_tokens <= 0 || b.n_tokens > (int32_t)c->n_batch) return -1;  // real llama.cpp rejects > n_batch
  FakeDecode d{b.n_tokens, -1, -1, 0, false, true, true, true};
  if (!b.pos) {
    g_fake_null_pos_decodes++;  // the bridge is required to pass explicit positions
    d.ok = false;
    g_fake_decodes.push_back(d);
    return -3;
  }
  if (!b.token || !b.n_seq_id || !b.seq_id || !b.logits) { d.ok = false; g_fake_decodes.push_back(d); return -3; }
  d.first_pos = b.pos[0];
  d.last_pos = b.pos[b.n_tokens - 1];
  for (int i = 0; i < b.n_tokens; i++) {
    if (b.pos[i] != b.pos[0] + i) d.contiguous = false;
    if (b.n_seq_id[i] != 1 || !b.seq_id[i] || b.seq_id[i][0] != 0) d.seq_ok = false;
    if (b.logits[i] == 1) d.n_logits++; else if (b.logits[i] != 0) d.ok = false;  // poison leaked
  }
  d.last_has_logits = b.logits[b.n_tokens - 1] == 1;
  // Emulated rule: positions continue exactly after the cache, stay inside the context.
  if (d.first_pos != g_kv_len || !d.contiguous || !d.seq_ok || d.last_pos >= g_ctx_n_ctx) {
    g_fake_pos_violations++;
    d.ok = false;
  }
  g_fake_decodes.push_back(d);
#ifndef LAI_FAKE_PERMISSIVE
  if (!d.ok) return 1;   // strict mode: behave like a library that rejects bad positions
#endif
  // LAI_FAKE_PERMISSIVE (mutation check only): accept the decode anyway, so that the
  // position assertions in bridge_test.cpp, not the decode error, must catch the bug.
  if (g_fake_fail_decode_at && g_decode_calls == g_fake_fail_decode_at) return 1;
  std::this_thread::sleep_for(std::chrono::milliseconds(1));
  g_kv_len += b.n_tokens;
  g_last_had_logits = d.last_has_logits;
  return 0;
}
llama_token llama_sampler_sample(llama_sampler *, llama_context *c, int32_t) {
  (void)c;
  if (!g_last_had_logits) g_fake_sample_without_logits++;
  if (g_sampled >= g_fake_eog_after) return 100000;
  return g_sampled++;
}
bool llama_vocab_is_eog(const llama_vocab *, llama_token t) { return t == 100000; }
int32_t llama_token_to_piece(const llama_vocab *, llama_token t, char *buf, int32_t n, int32_t, bool) {
  if (n < 1) return -1;
  buf[0] = g_fake_raw ? g_fake_raw[(size_t)t % (size_t)g_fake_raw_len] : kCanned[(size_t)t % std::strlen(kCanned)];
  return 1;
}
void llama_sampler_free(llama_sampler *s) {
  if (!s) return;
  for (auto *k : s->kids) llama_sampler_free(k);
  g_fake_live_objects--;
  delete s;
}
void llama_free(llama_context *c) { g_fake_live_objects--; delete c; }
void llama_model_free(llama_model *m) { g_fake_live_objects--; delete m; }
}

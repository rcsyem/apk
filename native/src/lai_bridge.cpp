// Written for llama.cpp v1.0.0 (pinned in third_party/llama.cpp.pin). Concurrency/chunking/UTF-8/position logic IS exercised on the
// host against a FAKE llama (native/tests), which proves nothing about llama.cpp
// itself. Audited and compiled against llama.cpp v1.0.0
// (b1b770d90d94cad9e9ea5b993bdbc383a522fb28); see TESTING.md for what was run.
#include "lai_bridge.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "llama.h"
#include "utf8_util.h"

namespace {
constexpr size_t kMaxQueue = 256;   // backpressure bound (pieces)
constexpr int kMaxCtx = 32768;
constexpr int kMaxThreads = 64;
constexpr int kMaxBatch = 512;
constexpr int kMaxMsgs = 1024;
constexpr size_t kMaxContentBytes = 1u << 20;      // 1 MiB per message
constexpr size_t kMaxTotalBytes = 8u << 20;        // 8 MiB per request
constexpr size_t kMaxPathBytes = 4096;
constexpr float kMaxTemperature = 2.0f;

void set_err(char *err, int n, const std::string &msg) {
  if (err && n > 0) std::snprintf(err, (size_t)n, "%s", msg.c_str());
}
}  // namespace

namespace {
struct ModelDeleter { void operator()(llama_model *m) const { if (m) llama_model_free(m); } };
struct CtxDeleter { void operator()(llama_context *c) const { if (c) llama_free(c); } };
struct SamplerDeleter { void operator()(llama_sampler *x) const { if (x) llama_sampler_free(x); } };
}  // namespace

struct lai_engine {
  // Declaration order matters: ctx is destroyed before model.
  std::unique_ptr<llama_model, ModelDeleter> model;
  std::unique_ptr<llama_context, CtxDeleter> ctx;
  const llama_vocab *vocab = nullptr;
  int n_ctx = 0;
  int n_batch = 0;

  std::atomic<bool> stop{false};
  std::atomic<int> prompt_tokens{0};
  std::atomic<int> gen_tokens{0};

  std::mutex start_mu;  // serializes start/join of the worker
  std::thread worker;

  std::mutex mu;  // guards everything below
  std::condition_variable cv;
  std::deque<std::string> q;
  bool done = true;  // true == no generation active
  int result = LAI_OK;
  bool stopped = false;
  std::string error;

  ~lai_engine() {
    stop.store(true);
    { std::lock_guard<std::mutex> lk(mu); }
    cv.notify_all();
    if (worker.joinable()) worker.join();  // never destroy a running thread
  }
};

namespace {

std::once_flag g_backend_once;

// ---- output queue --------------------------------------------------------
struct Emitter {
  lai_engine *e;
  std::string carry;  // incomplete UTF-8 tail between pieces

  bool enqueue(std::string s) {
    std::unique_lock<std::mutex> lk(e->mu);
    e->cv.wait(lk, [&] { return e->q.size() < kMaxQueue || e->stop.load(); });
    if (e->stop.load()) return false;  // consumer asked to stop: drop
    e->q.push_back(std::move(s));
    e->cv.notify_all();
    return true;
  }
  // Only valid UTF-8 ever reaches the queue (and therefore Dart).
  bool push(const std::string &bytes) {
    carry += bytes;
    std::string out;
    lai::utf8_sanitize(carry, false, out);
    if (out.empty()) return true;
    return enqueue(std::move(out));
  }
  // End of generation: a truncated trailing character is dropped, not emitted.
  void flush() {
    std::string out;
    lai::utf8_sanitize(carry, true, out);
    if (!out.empty()) enqueue(std::move(out));
  }
};

// ---- input validation ---------------------------------------------------
bool valid_role(const char *r) {
  return r && (!std::strcmp(r, "system") || !std::strcmp(r, "user") ||
               !std::strcmp(r, "assistant"));
}

// Copies and validates messages. Returns LAI_OK or LAI_ERR_ARGS (+err).
int validate_messages(const char **roles, const char **contents, int n,
                      std::vector<std::string> &r, std::vector<std::string> &c,
                      std::string &err) {
  if (!roles || !contents || n <= 0 || n > kMaxMsgs) {
    err = "invalid message count or arrays";
    return LAI_ERR_ARGS;
  }
  size_t total = 0;
  for (int i = 0; i < n; i++) {
    if (!valid_role(roles[i])) {
      err = "invalid role (allowed: system, user, assistant)";
      return LAI_ERR_ARGS;
    }
    if (!contents[i]) {
      err = "null content";
      return LAI_ERR_ARGS;
    }
    size_t len = strnlen(contents[i], kMaxContentBytes + 1);  // bounded scan
    if (len > kMaxContentBytes) {
      err = "message too large";
      return LAI_ERR_ARGS;
    }
    total += len;
    if (total > kMaxTotalBytes) {
      err = "request too large";
      return LAI_ERR_ARGS;
    }
    r.emplace_back(roles[i]);
    c.emplace_back(contents[i], len);
  }
  return LAI_OK;
}

// ---- llama helpers -------------------------------------------------------
int apply_template(lai_engine *e, const std::vector<std::string> &roles,
                   const std::vector<std::string> &contents, std::string &out,
                   std::string &err) {
  const size_t n = roles.size();
  std::vector<llama_chat_message> msgs(n);
  for (size_t i = 0; i < n; i++) msgs[i] = {roles[i].c_str(), contents[i].c_str()};

  const char *tmpl = llama_model_chat_template(e->model.get(), nullptr);
  if (!tmpl) {
    err = "model has no embedded chat template";
    return LAI_ERR_TEMPLATE;
  }
  // llama_chat_apply_template returns the TOTAL required length even when the
  // buffer is too small (output is then truncated), and a negative value when
  // the template is unsupported. So: try, grow once to the reported size, verify.
  std::vector<char> buf(4096);
  int32_t got = llama_chat_apply_template(tmpl, msgs.data(), n, true, buf.data(),
                                          (int32_t)buf.size());
  if (got < 0) {
    err = "chat template unsupported or invalid";
    return LAI_ERR_TEMPLATE;
  }
  if (got > (int32_t)buf.size()) {
    buf.assign((size_t)got + 1, 0);
    got = llama_chat_apply_template(tmpl, msgs.data(), n, true, buf.data(),
                                    (int32_t)buf.size());
    if (got < 0 || got > (int32_t)buf.size()) {
      err = "chat template result inconsistent after resize";
      return LAI_ERR_TEMPLATE;
    }
  }
  if (got == 0) {
    err = "chat template produced an empty prompt";
    return LAI_ERR_TEMPLATE;
  }
  out.assign(buf.data(), (size_t)got);
  return LAI_OK;
}

int tokenize(lai_engine *e, const std::string &text, std::vector<llama_token> &toks) {
  if (text.empty() || text.size() > (size_t)INT32_MAX) return LAI_ERR_TOKENIZE;
  int32_t n = llama_tokenize(e->vocab, text.c_str(), (int32_t)text.size(), nullptr, 0,
                             true, true);
  // Negative == required count; INT32_MIN == result size overflows int32_t (v1.0.0 docs).
  // Never negate INT32_MIN (undefined behaviour).
  if (n == INT32_MIN) return LAI_ERR_TOKENIZE;
  n = n < 0 ? -n : n;
  if (n <= 0) return LAI_ERR_TOKENIZE;
  toks.assign((size_t)n, 0);
  int32_t m = llama_tokenize(e->vocab, text.c_str(), (int32_t)text.size(), toks.data(),
                             (int32_t)toks.size(), true, true);
  if (m <= 0 || m > n) return LAI_ERR_TOKENIZE;
  toks.resize((size_t)m);
  return LAI_OK;
}

bool token_piece(const llama_vocab *v, llama_token t, std::string &out) {
  char buf[128];
  int32_t n = llama_token_to_piece(v, t, buf, (int32_t)sizeof buf, 0, true);
  if (n < 0) {
    if (-(int64_t)n > (1 << 20)) return false;  // a single piece is never this large
    std::vector<char> big((size_t)(-(int64_t)n) + 1);
    n = llama_token_to_piece(v, t, big.data(), (int32_t)big.size(), 0, true);
    if (n < 0) return false;
    out.assign(big.data(), (size_t)n);
    return true;
  }
  out.assign(buf, (size_t)n);
  return true;
}

// Builds the sampler chain. Every sampler pointer is checked; a sampler that was
// created but not yet handed to the chain is freed here (no leaks, no nullptr add).
bool build_sampler(float temperature, std::unique_ptr<llama_sampler, SamplerDeleter> &chain,
                   std::string &err) {
  chain.reset(llama_sampler_chain_init(llama_sampler_chain_default_params()));
  if (!chain) { err = "sampler chain init failed"; return false; }
  auto add = [&](llama_sampler *s, const char *what) {
    if (!s) { err = std::string("sampler init failed: ") + what; return false; }
    llama_sampler_chain_add(chain.get(), s);  // chain takes ownership
    return true;
  };
  if (temperature <= 0.0f) return add(llama_sampler_init_greedy(), "greedy");
  return add(llama_sampler_init_temp(temperature), "temp") &&
         add(llama_sampler_init_dist(LLAMA_DEFAULT_SEED), "dist");
}

// ---- explicit batch / position management -------------------------------
// The bridge never relies on the implicit-position batch helper (the one that
// leaves positions to the library). Every token gets an explicit position, sequence id and logits flag,
// and the bridge tracks n_past itself: the number of tokens currently cached for
// sequence 0 == the position of the next token to decode.
constexpr llama_seq_id kSeq = 0;

struct BatchGuard {
  llama_batch b{};
  explicit BatchGuard(int32_t capacity) { b = llama_batch_init(capacity, 0, 1); }
  ~BatchGuard() { llama_batch_free(b); }  // llama_batch_free tolerates null arrays
  BatchGuard(const BatchGuard &) = delete;
  BatchGuard &operator=(const BatchGuard &) = delete;
  bool usable() const { return b.token && b.pos && b.n_seq_id && b.seq_id && b.logits; }
};

// Fills `b` with n tokens at consecutive positions pos0, pos0+1, ...
// Logits are requested only for the last token, and only when `want_logits`.
void fill_batch(llama_batch &b, const llama_token *t, int n, llama_pos pos0, bool want_logits) {
  b.n_tokens = n;
  for (int i = 0; i < n; i++) {
    b.token[i] = t[i];
    b.pos[i] = pos0 + i;
    b.n_seq_id[i] = 1;
    b.seq_id[i][0] = kSeq;
    b.logits[i] = (want_logits && i == n - 1) ? 1 : 0;
  }
}

int generate_impl(lai_engine *e, const std::vector<std::string> &roles,
                  const std::vector<std::string> &contents, float temperature,
                  int max_new, Emitter &em, std::string &err) {
  std::string prompt;
  int rc = apply_template(e, roles, contents, prompt, err);
  if (rc != LAI_OK) return rc;

  std::vector<llama_token> toks;
  rc = tokenize(e, prompt, toks);
  if (rc != LAI_OK) {
    err = "tokenize failed";
    return rc;
  }
  const int total = (int)toks.size();
  e->prompt_tokens.store(total);
  if (total + 1 >= e->n_ctx) {
    err = "prompt does not fit in context";
    return LAI_ERR_PROMPT_TOO_LONG;
  }

  llama_memory_t mem = llama_get_memory(e->ctx.get());
  if (!mem) {
    err = "context has no memory object";
    return LAI_ERR_INTERNAL;
  }
  llama_memory_clear(mem, true);  // fresh evaluation: cache is empty, so n_past == 0
  llama_pos n_past = 0;

  std::unique_ptr<llama_sampler, SamplerDeleter> smpl;
  if (!build_sampler(temperature, smpl, err)) return LAI_ERR_INTERNAL;

  BatchGuard bg(e->n_batch);
  if (!bg.usable()) {
    err = "llama_batch_init failed (out of memory)";
    return LAI_ERR_INTERNAL;
  }

  // Prompt evaluation in chunks of at most n_batch tokens. Each chunk continues
  // at n_past; only the final token of the final chunk requests logits.
  for (int off = 0; off < total;) {
    if (e->stop.load()) return LAI_OK;
    const int n = std::min(e->n_batch, total - off);
    if (n_past + n > e->n_ctx) {  // defensive: already excluded by the size check above
      err = "prompt does not fit in context";
      return LAI_ERR_PROMPT_TOO_LONG;
    }
    fill_batch(bg.b, toks.data() + off, n, n_past, /*want_logits=*/off + n == total);
    int drc = llama_decode(e->ctx.get(), bg.b);
    if (drc != 0) {
      err = "llama_decode failed on prompt (code " + std::to_string(drc) + ")";
      return LAI_ERR_DECODE;
    }
    n_past += n;
    off += n;
  }

  int produced = 0;
  std::string piece;
  while (!e->stop.load()) {
    llama_token tok = llama_sampler_sample(smpl.get(), e->ctx.get(), -1);
    if (llama_vocab_is_eog(e->vocab, tok)) break;
    e->gen_tokens.fetch_add(1);
    ++produced;
    if (token_piece(e->vocab, tok, piece) && !piece.empty()) {
      if (!em.push(piece)) break;  // stopped while waiting for consumer
    }
    if (produced >= max_new) break;
    if (n_past + 1 >= e->n_ctx) break;  // no room to cache another token
    fill_batch(bg.b, &tok, 1, n_past, /*want_logits=*/true);
    int drc = llama_decode(e->ctx.get(), bg.b);
    if (drc != 0) {
      err = "llama_decode failed (code " + std::to_string(drc) + ")";
      return LAI_ERR_DECODE;
    }
    n_past += 1;
  }
  return LAI_OK;
}

void run_generation(lai_engine *e, std::vector<std::string> roles,
                    std::vector<std::string> contents, float temperature,
                    int max_new) {
  int rc = LAI_OK;
  std::string err;
  Emitter em{e, {}};
  try {
    rc = generate_impl(e, roles, contents, temperature, max_new, em, err);
  } catch (const std::exception &ex) {
    rc = LAI_ERR_INTERNAL;
    err = std::string("exception: ") + ex.what();
  } catch (...) {
    rc = LAI_ERR_INTERNAL;
    err = "unknown exception";
  }
  try {
    if (rc == LAI_OK && !e->stop.load()) em.flush();
  } catch (...) {
  }
  {
    std::lock_guard<std::mutex> lk(e->mu);
    e->result = rc;
    e->error = err;
    e->stopped = e->stop.load();
    e->done = true;
  }
  e->cv.notify_all();
}

}  // namespace

// ============================== C ABI ====================================
extern "C" {

const char *lai_version(void) { return "lai_bridge/0.4"; }

int lai_load(const char *path, int n_ctx, int n_threads, lai_engine **out, char *err,
             int err_len) {
  if (out) *out = nullptr;  // always initialised, whatever happens below
  try {
    if (!path || !out || n_ctx < 128 || n_ctx > kMaxCtx || n_threads < 1 ||
        n_threads > kMaxThreads || strnlen(path, kMaxPathBytes + 1) > kMaxPathBytes) {
      set_err(err, err_len, "bad arguments");
      return LAI_ERR_ARGS;
    }
    FILE *f = std::fopen(path, "rb");
    if (!f) {
      set_err(err, err_len, "cannot open model file");
      return LAI_ERR_FILE;
    }
    std::fclose(f);

    std::call_once(g_backend_once, [] { llama_backend_init(); });

    // Everything below is owned by RAII: any early return or exception frees
    // the context and the model automatically.
    std::unique_ptr<lai_engine> e(new lai_engine());

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0;  // CPU only (approved decision)
    mp.load_mode = LLAMA_LOAD_MODE_MMAP;  // v1.0.0: replaces the removed use_mmap boolean
    e->model.reset(llama_model_load_from_file(path, mp));
    if (!e->model) {
      set_err(err, err_len, "model load failed (corrupt or unsupported GGUF)");
      return LAI_ERR_MODEL;
    }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = (uint32_t)n_ctx;
    cp.n_batch = (uint32_t)std::min(n_ctx, kMaxBatch);
    cp.n_ubatch = cp.n_batch;
    cp.n_threads = n_threads;
    cp.n_threads_batch = n_threads;
    e->ctx.reset(llama_init_from_model(e->model.get(), cp));
    if (!e->ctx) {
      set_err(err, err_len, "context creation failed (likely out of memory)");
      return LAI_ERR_CONTEXT;
    }

    e->vocab = llama_model_get_vocab(e->model.get());
    if (!e->vocab) {
      set_err(err, err_len, "model has no vocabulary");
      return LAI_ERR_MODEL;
    }
    e->n_ctx = (int)llama_n_ctx(e->ctx.get());
    e->n_batch = std::max(1, (int)llama_n_batch(e->ctx.get()));
    *out = e.release();
    return LAI_OK;
  } catch (const std::exception &ex) {
    set_err(err, err_len, std::string("exception: ") + ex.what());
  } catch (...) {
    set_err(err, err_len, "unknown exception");
  }
  if (out) *out = nullptr;
  return LAI_ERR_INTERNAL;
}

int lai_generate_start(lai_engine *e, const char **roles, const char **contents,
                       int n_msgs, float temperature, int max_new, char *err,
                       int err_len) {
  try {
    if (!e) {
      set_err(err, err_len, "null engine");
      return LAI_ERR_ARGS;
    }
    if (!std::isfinite(temperature) || temperature < 0.0f || temperature > kMaxTemperature) {
      set_err(err, err_len, "temperature must be finite and within [0, 2]");
      return LAI_ERR_ARGS;
    }
    if (max_new <= 0 || max_new > kMaxCtx) {
      set_err(err, err_len, "max_new out of range");
      return LAI_ERR_ARGS;
    }
    std::vector<std::string> r, c;
    std::string verr;
    if (validate_messages(roles, contents, n_msgs, r, c, verr) != LAI_OK) {
      set_err(err, err_len, verr);
      return LAI_ERR_ARGS;
    }
    std::lock_guard<std::mutex> sl(e->start_mu);
    {
      std::lock_guard<std::mutex> lk(e->mu);
      if (!e->done) {
        set_err(err, err_len, "generation already running");
        return LAI_ERR_BUSY;
      }
    }
    if (e->worker.joinable()) e->worker.join();  // previous run already finished
    {
      std::lock_guard<std::mutex> lk(e->mu);
      e->q.clear();
      e->done = false;
      e->result = LAI_OK;
      e->stopped = false;
      e->error.clear();
      e->stop.store(false);
      e->prompt_tokens.store(0);
      e->gen_tokens.store(0);
    }
    try {
      e->worker = std::thread(run_generation, e, std::move(r), std::move(c),
                              temperature, max_new);
    } catch (...) {
      std::lock_guard<std::mutex> lk(e->mu);
      e->done = true;
      set_err(err, err_len, "could not start worker thread");
      return LAI_ERR_INTERNAL;
    }
    return LAI_OK;
  } catch (const std::exception &ex) {
    set_err(err, err_len, std::string("exception: ") + ex.what());
  } catch (...) {
    set_err(err, err_len, "unknown exception");
  }
  return LAI_ERR_INTERNAL;
}

int lai_next(lai_engine *e, char *buf, int cap, int timeout_ms, int *out_len) {
  if (out_len) *out_len = 0;
  if (!e || !out_len || cap < 0 || (cap > 0 && !buf)) return LAI_NEXT_INVALID;
  try {
    if (timeout_ms < 0) timeout_ms = 0;
    if (timeout_ms > 60000) timeout_ms = 60000;
    std::unique_lock<std::mutex> lk(e->mu);
    e->cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                   [&] { return !e->q.empty() || e->done; });
    if (!e->q.empty()) {
      const std::string &front = e->q.front();
      if (front.size() > (size_t)INT32_MAX) return LAI_NEXT_INVALID;
      if ((int)front.size() > cap) {
        *out_len = (int)front.size();
        return LAI_NEXT_SMALL_BUFFER;
      }
      if (!front.empty()) std::memcpy(buf, front.data(), front.size());
      *out_len = (int)front.size();
      e->q.pop_front();
      e->cv.notify_all();  // wake a producer blocked on backpressure
      return LAI_NEXT_PIECE;
    }
    return e->done ? LAI_NEXT_DONE : LAI_NEXT_TIMEOUT;
  } catch (...) {
    return LAI_NEXT_INVALID;
  }
}

int lai_result(lai_engine *e, int *stopped, char *err, int err_len) {
  if (!e) return LAI_ERR_ARGS;
  try {
    std::lock_guard<std::mutex> lk(e->mu);
    if (stopped) *stopped = e->stopped ? 1 : 0;
    set_err(err, err_len, e->error);
    return e->result;
  } catch (...) {
    return LAI_ERR_INTERNAL;
  }
}

void lai_stop(lai_engine *e) {
  if (!e) return;
  try {
    e->stop.store(true);
    { std::lock_guard<std::mutex> lk(e->mu); }  // avoid lost wakeup
    e->cv.notify_all();
  } catch (...) {
  }
}

int lai_stats(lai_engine *e, int *prompt_tokens, int *generated_tokens) {
  if (!e) return LAI_ERR_ARGS;
  if (prompt_tokens) *prompt_tokens = e->prompt_tokens.load();
  if (generated_tokens) *generated_tokens = e->gen_tokens.load();
  return LAI_OK;
}

int lai_count_prompt_tokens(lai_engine *e, const char **roles, const char **contents,
                            int n) {
  if (!e) return -1;
  try {
    std::vector<std::string> r, c;
    std::string verr;
    if (validate_messages(roles, contents, n, r, c, verr) != LAI_OK) return -1;
    std::string p, err;
    if (apply_template(e, r, c, p, err) != LAI_OK) return -1;
    std::vector<llama_token> t;
    if (tokenize(e, p, t) != LAI_OK) return -1;
    return (int)t.size();
  } catch (...) {
    return -1;
  }
}

void lai_free(lai_engine *e) {
  if (!e) return;
  try {
    delete e;  // ~lai_engine: stop + join worker, then free ctx, then model
  } catch (...) {
  }
}

}  // extern "C"

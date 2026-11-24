// Host test of lai_bridge.cpp against the FAKE llama (fake_llama.cpp).
// Exercises chunking, template resize, queue/backpressure, UTF-8 boundaries,
// cross-thread stop, busy, free-during-generation, exception containment.
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include "lai_bridge.h"
#include "llama.h"  // fake hooks

#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); std::exit(1);} } while (0)

// Independent strict validator (deliberately NOT the code under test).
static bool valid_utf8(const std::string &s) {
  size_t i = 0, n = s.size();
  while (i < n) {
    unsigned char c = (unsigned char)s[i];
    size_t k = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 0;
    if (!k || i + k > n) return false;
    uint32_t cp = k == 1 ? c : k == 2 ? (c & 0x1F) : k == 3 ? (c & 0x0F) : (c & 0x07);
    for (size_t j = 1; j < k; j++) {
      unsigned char d = (unsigned char)s[i + j];
      if ((d & 0xC0) != 0x80) return false;
      cp = (cp << 6) | (d & 0x3F);
    }
    if ((k == 2 && cp < 0x80) || (k == 3 && cp < 0x800) || (k == 4 && cp < 0x10000)) return false;  // overlong
    if (cp >= 0xD800 && cp <= 0xDFFF) return false;  // surrogates
    if (cp > 0x10FFFF) return false;
    i += k;
  }
  return true;
}

struct Out { std::vector<std::string> pieces; std::string text; int result = -99, stopped = -1; char err[256] = {0}; };

static Out drain(lai_engine *e, int per_piece_sleep_ms = 0) {
  Out o; char buf[256]; int len = 0;
  while (true) {
    int st = lai_next(e, buf, sizeof buf, 50, &len);
    if (st == LAI_NEXT_PIECE) {
      o.pieces.emplace_back(buf, (size_t)len);
      o.text.append(buf, (size_t)len);
      if (per_piece_sleep_ms) std::this_thread::sleep_for(std::chrono::milliseconds(per_piece_sleep_ms));
    } else if (st == LAI_NEXT_DONE) break;
    else CHECK(st == LAI_NEXT_TIMEOUT);
  }
  o.result = lai_result(e, &o.stopped, o.err, sizeof o.err);
  return o;
}

static int start(lai_engine *e, const std::string &content, int max_new, float temp = 0.7f, char *err = nullptr) {
  const char *r[] = {"user"}; const char *c[] = {content.c_str()};
  char local[128]; if (!err) err = local;
  return lai_generate_start(e, r, c, 1, temp, max_new, err, 128);
}
static lai_engine *load(const char *path, int ctx = 2048) {
  lai_engine *e = nullptr; char err[128];
  CHECK(lai_load(path, ctx, 2, &e, err, sizeof err) == LAI_OK && e);
  return e;
}
static std::string expected(size_t nbytes) {
  const std::string canned = "مرحبا بالعالم! "; std::string s;
  for (size_t i = 0; i < nbytes; i++) s += canned[i % canned.size()];
  return s;
}

int main() {
  std::thread([] { std::this_thread::sleep_for(std::chrono::seconds(90)); std::fputs("WATCHDOG: hang\n", stderr); std::_Exit(3); }).detach();
  if (std::system("mkdir -p /tmp/lai_t && echo x > /tmp/lai_t/model.gguf && echo x > /tmp/lai_t/bad.gguf && echo x > /tmp/lai_t/notemplate.gguf") != 0) return 1;
  char err[256];

  // --- load validation: out pointer always initialised ---
  lai_engine *e = (lai_engine *)0x1;
  CHECK(lai_load(nullptr, 2048, 2, &e, err, sizeof err) == LAI_ERR_ARGS && e == nullptr);
  e = (lai_engine *)0x1;
  CHECK(lai_load("/tmp/lai_t/model.gguf", 10, 2, &e, err, sizeof err) == LAI_ERR_ARGS && e == nullptr);
  e = (lai_engine *)0x1;
  CHECK(lai_load("/nonexistent.gguf", 2048, 2, &e, err, sizeof err) == LAI_ERR_FILE && e == nullptr);
  e = (lai_engine *)0x1;
  CHECK(lai_load("/tmp/lai_t/bad.gguf", 2048, 2, &e, err, sizeof err) == LAI_ERR_MODEL && e == nullptr);
  e = (lai_engine *)0x1;
  CHECK(lai_load("/tmp/lai_t/model.gguf", 30000, 2, &e, err, sizeof err) == LAI_ERR_CONTEXT && e == nullptr);
  CHECK(g_fake_live_objects == 0);  // failed loads leak nothing
  CHECK(lai_generate_start(nullptr, nullptr, nullptr, 0, 0, 0, err, sizeof err) == LAI_ERR_ARGS);
  lai_free(nullptr);

  // --- basic generation, UTF-8 integrity, ordering ---
  e = load("/tmp/lai_t/model.gguf");
  g_fake_eog_after = 1000;
  CHECK(start(e, "hi", 1000) == LAI_OK);
  Out o = drain(e, 0);
  CHECK(o.result == LAI_OK && !o.stopped);
  for (size_t i = 0; i < o.pieces.size(); i++) CHECK(valid_utf8(o.pieces[i]));  // every piece incl. last
  CHECK(o.text == expected(o.text.size()) && o.text.size() > 900);
  int pt, gt; lai_stats(e, &pt, &gt);
  CHECK(gt == 1000 && pt > 0);

  // --- backpressure: slow consumer must still get everything in order ---
  g_fake_eog_after = 700;
  CHECK(start(e, "hi", 700) == LAI_OK);
  o = drain(e, 1);
  lai_stats(e, &pt, &gt);
  CHECK(o.result == LAI_OK && gt == 700 && o.text == expected(o.text.size()));

  // --- prompt longer than n_batch is chunked (fake rejects > n_batch) ---
  g_fake_eog_after = 5; g_fake_big_decodes = 0; g_fake_max_batch_seen = 0;
  CHECK(start(e, std::string(1500, 'a'), 20) == LAI_OK);
  o = drain(e);
  CHECK(o.result == LAI_OK);
  CHECK(g_fake_big_decodes >= 3 && g_fake_max_batch_seen <= 512);

  // --- prompt that cannot fit in context ---
  CHECK(start(e, std::string(3000, 'a'), 20) == LAI_OK);
  o = drain(e);
  CHECK(o.result == LAI_ERR_PROMPT_TOO_LONG);

  // --- template larger than initial 4096 buffer (resize path) ---
  lai_free(e);
  e = load("/tmp/lai_t/model.gguf", 8192);
  CHECK(start(e, std::string(6000, 'b'), 20) == LAI_OK);
  o = drain(e);
  CHECK(o.result == LAI_OK);
  lai_stats(e, &pt, &gt);
  CHECK(pt > 6000);
  const char *r1[] = {"user"}; const char *c1[] = {"hello"};
  CHECK(lai_count_prompt_tokens(e, r1, c1, 1) > 5);

  // --- unsupported template, and model with no template ---
  CHECK(start(e, "BADTEMPLATE", 5) == LAI_OK);
  o = drain(e);
  CHECK(o.result == LAI_ERR_TEMPLATE);
  lai_free(e);
  e = load("/tmp/lai_t/notemplate.gguf");
  CHECK(start(e, "hi", 5) == LAI_OK);
  o = drain(e);
  CHECK(o.result == LAI_ERR_TEMPLATE);
  lai_free(e);

  // --- cross-thread stop, then free after generation ended ---
  e = load("/tmp/lai_t/model.gguf");
  g_fake_eog_after = 30000;
  CHECK(start(e, "hi", 30000) == LAI_OK);
  CHECK(start(e, "again", 5) == LAI_ERR_BUSY);  // second start while running
  std::thread stopper([e] { std::this_thread::sleep_for(std::chrono::milliseconds(60)); lai_stop(e); });
  o = drain(e);
  stopper.join();
  lai_stats(e, &pt, &gt);
  CHECK(o.result == LAI_OK && o.stopped == 1 && gt > 0 && gt < 30000);
  // engine is reusable after a stop
  g_fake_eog_after = 30;
  CHECK(start(e, "hi", 30) == LAI_OK);
  o = drain(e);
  CHECK(o.result == LAI_OK && !o.stopped);
  lai_free(e);

  // --- lai_next small-buffer semantics (2-byte piece, cap 1) ---
  e = load("/tmp/lai_t/model.gguf");
  g_fake_eog_after = 50;
  CHECK(start(e, "hi", 50) == LAI_OK);
  char b1[1]; int len = 0, st;
  do { st = lai_next(e, b1, 1, 100, &len); } while (st == LAI_NEXT_TIMEOUT);
  CHECK(st == LAI_NEXT_SMALL_BUFFER && len == 2);
  char b2[16];
  st = lai_next(e, b2, sizeof b2, 100, &len);
  CHECK(st == LAI_NEXT_PIECE && len == 2);
  lai_stop(e); drain(e); lai_free(e);

  // --- free during generation with nobody draining (producer blocked) ---
  e = load("/tmp/lai_t/model.gguf");
  g_fake_eog_after = 30000;
  CHECK(start(e, "hi", 30000) == LAI_OK);
  std::this_thread::sleep_for(std::chrono::milliseconds(400));  // queue fills, worker blocks
  lai_free(e);  // must return, not hang

  // --- C++ exception inside llama must not cross the ABI ---
  e = load("/tmp/lai_t/model.gguf");
  g_fake_throw_on_decode = 1;
  CHECK(start(e, "hi", 10) == LAI_OK);
  o = drain(e);
  CHECK(o.result == LAI_ERR_INTERNAL && std::strstr(o.err, "exception"));
  g_fake_throw_on_decode = 0;
  lai_free(e);


  // ================= v0.3 additions =================
  // --- UTF-8: generation that ends in the MIDDLE of a multi-byte character ---
  e = load("/tmp/lai_t/model.gguf");
  g_fake_eog_after = 1000;
  CHECK(start(e, "hi", 1) == LAI_OK);            // emits only 0xD9 (first byte of 'م')
  o = drain(e);
  CHECK(o.result == LAI_OK && o.text.empty() && o.pieces.empty());  // truncated char dropped
  CHECK(start(e, "hi", 3) == LAI_OK);            // D9 85 D8 -> keeps 'م', drops lone D8
  o = drain(e);
  CHECK(o.result == LAI_OK && o.text == "\xD9\x85" && valid_utf8(o.text));
  CHECK(start(e, "hi", 7) == LAI_OK);
  o = drain(e);
  CHECK(valid_utf8(o.text) && o.text == expected(o.text.size()));

  // --- UTF-8: malformed model bytes never reach the consumer ---
  static const char raw[] = {'A', (char)0x80, 'B', (char)0xC0, (char)0xAF, 'C', (char)0xE2, 'D',
                             (char)0xED, (char)0xA0, (char)0x80, 'E', (char)0xF5, 'F'};
  g_fake_raw = raw; g_fake_raw_len = (int)sizeof raw; g_fake_eog_after = (int)sizeof raw;
  CHECK(start(e, "hi", 100) == LAI_OK);
  o = drain(e);
  const std::string R = "\xEF\xBF\xBD";
  CHECK(o.result == LAI_OK && valid_utf8(o.text));
  CHECK(o.text == "A" + R + "B" + R + R + "C" + R + "D" + R + R + R + "E" + R + "F");
  g_fake_raw = nullptr;

  // --- sampler init failures: handled, no nullptr added, nothing leaked ---
  for (int mode = 1; mode <= 4; mode++) {
    g_fake_fail_sampler = mode;
    g_fake_eog_after = 10;
    CHECK(start(e, "hi", 10, mode == 4 ? 0.0f : 0.7f) == LAI_OK);
    o = drain(e);
    CHECK(o.result == LAI_ERR_INTERNAL && std::strstr(o.err, "sampler"));
  }
  // mode 4 only affects greedy; with temperature > 0 generation must still work
  g_fake_fail_sampler = 4; g_fake_eog_after = 10;
  CHECK(start(e, "hi", 10, 0.7f) == LAI_OK);
  o = drain(e);
  CHECK(o.result == LAI_OK);
  g_fake_fail_sampler = 0;
  CHECK(start(e, "hi", 10, 0.0f) == LAI_OK);     // greedy path works when healthy
  o = drain(e);
  CHECK(o.result == LAI_OK);
  lai_free(e);
  CHECK(g_fake_live_objects == 0);

  // --- ABI input validation ---
  e = load("/tmp/lai_t/model.gguf");
  const char *ok_r[] = {"user"}; const char *ok_c[] = {"hi"};
  const char *bad_roles[][1] = {{"bot"}, {"User"}, {""}, {nullptr}};
  for (auto &br : bad_roles) CHECK(lai_generate_start(e, br, ok_c, 1, 0.7f, 10, err, sizeof err) == LAI_ERR_ARGS);
  const char *null_c[] = {nullptr};
  CHECK(lai_generate_start(e, ok_r, null_c, 1, 0.7f, 10, err, sizeof err) == LAI_ERR_ARGS);
  CHECK(lai_generate_start(e, ok_r, ok_c, 0, 0.7f, 10, err, sizeof err) == LAI_ERR_ARGS);
  CHECK(lai_generate_start(e, ok_r, ok_c, -3, 0.7f, 10, err, sizeof err) == LAI_ERR_ARGS);
  CHECK(lai_generate_start(e, nullptr, ok_c, 1, 0.7f, 10, err, sizeof err) == LAI_ERR_ARGS);
  CHECK(lai_generate_start(e, ok_r, nullptr, 1, 0.7f, 10, err, sizeof err) == LAI_ERR_ARGS);
  const float bad_t[] = {NAN, -INFINITY, INFINITY, -0.5f, 2.5f, 1e9f};
  for (float t : bad_t) CHECK(lai_generate_start(e, ok_r, ok_c, 1, t, 10, err, sizeof err) == LAI_ERR_ARGS);
  CHECK(lai_generate_start(e, ok_r, ok_c, 1, 0.7f, 0, err, sizeof err) == LAI_ERR_ARGS);
  CHECK(lai_generate_start(e, ok_r, ok_c, 1, 0.7f, -1, err, sizeof err) == LAI_ERR_ARGS);
  CHECK(lai_generate_start(e, ok_r, ok_c, 1, 0.7f, 1 << 30, err, sizeof err) == LAI_ERR_ARGS);
  {  // oversized single message and too many messages
    std::string big(2 * 1024 * 1024, 'x');
    CHECK(start(e, big, 10) == LAI_ERR_ARGS);
    std::vector<const char *> rr(5000, "user"), cc(5000, "hi");
    CHECK(lai_generate_start(e, rr.data(), cc.data(), 5000, 0.7f, 10, err, sizeof err) == LAI_ERR_ARGS);
    CHECK(lai_count_prompt_tokens(e, rr.data(), cc.data(), 5000) == -1);
    const char *brr[] = {"nope"};
    CHECK(lai_count_prompt_tokens(e, brr, ok_c, 1) == -1);
  }
  CHECK(lai_count_prompt_tokens(nullptr, ok_r, ok_c, 1) == -1);
  char nb[8]; int nl = 123;
  CHECK(lai_next(nullptr, nb, 8, 0, &nl) == LAI_NEXT_INVALID && nl == 0);
  CHECK(lai_next(e, nb, -1, 0, &nl) == LAI_NEXT_INVALID);
  CHECK(lai_next(e, nullptr, 8, 0, &nl) == LAI_NEXT_INVALID);
  CHECK(lai_next(e, nb, 8, 0, nullptr) == LAI_NEXT_INVALID);
  CHECK(lai_next(e, nb, 8, -5, &nl) == LAI_NEXT_DONE);   // idle engine, negative timeout clamped
  CHECK(lai_result(nullptr, nullptr, nullptr, 0) == LAI_ERR_ARGS);
  CHECK(lai_stats(nullptr, nullptr, nullptr) == LAI_ERR_ARGS);
  lai_stop(nullptr);
  lai_free(e);
  {  // load argument limits
    std::string longp(5000, 'p');
    lai_engine *x = (lai_engine *)0x1;
    CHECK(lai_load(longp.c_str(), 2048, 2, &x, err, sizeof err) == LAI_ERR_ARGS && x == nullptr);
    x = (lai_engine *)0x1;
    CHECK(lai_load("/tmp/lai_t/model.gguf", 2048, 0, &x, err, sizeof err) == LAI_ERR_ARGS && x == nullptr);
    x = (lai_engine *)0x1;
    CHECK(lai_load("/tmp/lai_t/model.gguf", 2048, 65, &x, err, sizeof err) == LAI_ERR_ARGS && x == nullptr);
    x = (lai_engine *)0x1;
    CHECK(lai_load("/tmp/lai_t/model.gguf", 99999, 2, &x, err, sizeof err) == LAI_ERR_ARGS && x == nullptr);
    CHECK(lai_load("/tmp/lai_t/model.gguf", 2048, 2, nullptr, err, sizeof err) == LAI_ERR_ARGS);
  }

  // --- RAII: exception during load must not leak model/context ---
  {
    lai_engine *x = (lai_engine *)0x1;
    g_fake_throw_in_ctx = 1;      // throws after the model is already loaded
    CHECK(lai_load("/tmp/lai_t/model.gguf", 2048, 2, &x, err, sizeof err) == LAI_ERR_INTERNAL && x == nullptr);
    CHECK(std::strstr(err, "exception"));
    g_fake_throw_in_ctx = 0;
    CHECK(g_fake_live_objects == 0);
    x = (lai_engine *)0x1;
    g_fake_throw_in_vocab = 1;    // throws after model AND context exist
    CHECK(lai_load("/tmp/lai_t/model.gguf", 2048, 2, &x, err, sizeof err) == LAI_ERR_INTERNAL && x == nullptr);
    g_fake_throw_in_vocab = 0;
    CHECK(g_fake_live_objects == 0);
    x = (lai_engine *)0x1;        // context failure path also frees the model
    CHECK(lai_load("/tmp/lai_t/model.gguf", 30000, 2, &x, err, sizeof err) == LAI_ERR_CONTEXT && x == nullptr);
    CHECK(g_fake_live_objects == 0);
  }


  // ================= v0.4: explicit token positions (n_past) =================
  // The fake emulates the rule "new positions continue exactly after the cached
  // ones and stay below n_ctx", rejects decodes without explicit positions, and
  // flags sampling when the last decode requested no logits. It is NOT llama.cpp.
  {
    auto check_positions = [&](const char *what, int expect_prompt_tokens, int expect_gen_decodes) {
      std::fprintf(stderr, "  positions: %s\n", what);
      CHECK(g_fake_null_pos_decodes == 0);        // never relies on implicit positions
      CHECK(g_fake_pos_violations == 0);
      CHECK(g_fake_sample_without_logits == 0);
      CHECK(!g_fake_decodes.empty());
      int next = 0, prompt_seen = 0, gen_decodes = 0;
      bool in_prompt = true;
      for (size_t i = 0; i < g_fake_decodes.size(); i++) {
        const FakeDecode &d = g_fake_decodes[i];
        CHECK(d.ok && d.seq_ok && d.contiguous);
        CHECK(d.first_pos == next);                // continues, never resets to 0
        CHECK(d.last_pos == next + d.n_tokens - 1);
        CHECK(d.n_tokens <= 512);
        if (in_prompt) {
          prompt_seen += d.n_tokens;
          const bool final_prompt_chunk = prompt_seen == expect_prompt_tokens;
          CHECK(prompt_seen <= expect_prompt_tokens);
          CHECK(d.last_has_logits == final_prompt_chunk);   // logits only where sampling reads them
          CHECK(d.n_logits == (final_prompt_chunk ? 1 : 0));
          if (final_prompt_chunk) in_prompt = false;
        } else {
          CHECK(d.n_tokens == 1 && d.last_has_logits && d.n_logits == 1);
          CHECK(d.first_pos == expect_prompt_tokens + gen_decodes);  // generated tokens follow the prompt
          gen_decodes++;
        }
        next += d.n_tokens;
      }
      CHECK(prompt_seen == expect_prompt_tokens);
      CHECK(gen_decodes == expect_gen_decodes);
    };

    e = load("/tmp/lai_t/model.gguf", 2048);
    // Fake template adds 20 bytes around a one-message prompt; fake tokenizer: 1 byte = 1 token.
    constexpr int kOverhead = 20;
    struct Case { const char *name; int content_len; int eog_after; int max_new; };
    const Case cases[] = {
        {"short prompt, generation to EOG", 5, 40, 1000},
        {"prompt exactly n_batch (512)", 512 - kOverhead, 25, 1000},
        {"prompt n_batch + 1", 513 - kOverhead, 25, 1000},
        {"prompt exactly 2 * n_batch", 1024 - kOverhead, 25, 1000},
        {"multi-chunk prompt (1500)", 1500, 60, 1000},
        {"max_new limits generation", 700, 1000, 10},
    };
    for (const Case &cs : cases) {
      g_fake_eog_after = cs.eog_after;
      fake_reset_decode_log();
      CHECK(start(e, std::string((size_t)cs.content_len, 'a'), cs.max_new) == LAI_OK);
      o = drain(e);
      CHECK(o.result == LAI_OK && !o.stopped);
      lai_stats(e, &pt, &gt);
      CHECK(pt == cs.content_len + kOverhead);
      const int produced = std::min(cs.eog_after, cs.max_new);
      CHECK(gt == produced);
      // every generated token except a last one cut by max_new/EOG gets decoded
      const int gen_decodes = (produced >= cs.max_new) ? produced - 1 : produced;
      check_positions(cs.name, pt, gen_decodes);
      CHECK(g_fake_clear_calls == 1);             // each run starts from an empty cache
    }

    // A second generation on the SAME engine must restart at position 0 (cache cleared).
    g_fake_eog_after = 30;
    fake_reset_decode_log();
    CHECK(start(e, "second run", 1000) == LAI_OK);
    o = drain(e);
    CHECK(o.result == LAI_OK);
    CHECK(g_fake_decodes.front().first_pos == 0 && g_fake_clear_calls == 1);
    lai_stats(e, &pt, &gt);
    check_positions("second run on same engine", pt, 30);

    // Stop in the middle, then reuse: positions of the next run again start at 0.
    g_fake_eog_after = 30000;
    fake_reset_decode_log();
    CHECK(start(e, std::string(800, 'c'), 30000) == LAI_OK);
    std::thread st2([e] { std::this_thread::sleep_for(std::chrono::milliseconds(40)); lai_stop(e); });
    o = drain(e);
    st2.join();
    CHECK(o.stopped == 1);
    CHECK(g_fake_pos_violations == 0 && g_fake_null_pos_decodes == 0);
    g_fake_eog_after = 12;
    fake_reset_decode_log();
    CHECK(start(e, "after stop", 1000) == LAI_OK);
    o = drain(e);
    CHECK(o.result == LAI_OK && g_fake_decodes.front().first_pos == 0);
    lai_stats(e, &pt, &gt);
    check_positions("reuse after stop", pt, 12);

    // Context edge: generation must stop before any position reaches n_ctx.
    g_fake_eog_after = 100000;
    fake_reset_decode_log();
    CHECK(start(e, std::string(2000, 'd'), 30000) == LAI_OK);
    o = drain(e);
    CHECK(o.result == LAI_OK);
    CHECK(g_fake_pos_violations == 0 && g_fake_null_pos_decodes == 0);
    int max_pos = -1;
    for (const FakeDecode &d : g_fake_decodes) max_pos = std::max(max_pos, d.last_pos);
    CHECK(max_pos >= 0 && max_pos < 2048);
    lai_free(e);

    // Decode failure on a later prompt chunk and on a generated token: reported, batch freed.
    e = load("/tmp/lai_t/model.gguf", 2048);
    g_fake_eog_after = 50;
    fake_reset_decode_log();
    g_fake_fail_decode_at = 2;                    // second prompt chunk
    CHECK(start(e, std::string(1200, 'e'), 20) == LAI_OK);
    o = drain(e);
    CHECK(o.result == LAI_ERR_DECODE && std::strstr(o.err, "prompt"));
    g_fake_fail_decode_at = 0;
    fake_reset_decode_log();
    g_fake_fail_decode_at = 3;                    // prompt (1 chunk) + 1st generated decode OK, 2nd fails
    CHECK(start(e, "short", 20) == LAI_OK);
    o = drain(e);
    CHECK(o.result == LAI_ERR_DECODE && std::strstr(o.err, "llama_decode failed"));
    g_fake_fail_decode_at = 0;
    // batch allocation failure
    g_fake_fail_batch = 1;
    CHECK(start(e, "hi", 5) == LAI_OK);
    o = drain(e);
    CHECK(o.result == LAI_ERR_INTERNAL && std::strstr(o.err, "batch"));
    g_fake_fail_batch = 0;
    // engine still healthy afterwards
    g_fake_eog_after = 10;
    fake_reset_decode_log();
    CHECK(start(e, "healthy", 20) == LAI_OK);
    o = drain(e);
    CHECK(o.result == LAI_OK && g_fake_pos_violations == 0 && g_fake_null_pos_decodes == 0);
    lai_free(e);
    CHECK(g_fake_live_objects == 0);              // batches, samplers, contexts, models all released
  }


  // ================= v0.4.2: llama.cpp v1.0.0 API differences =================
  {
    g_fake_seen_load_mode = LLAMA_LOAD_MODE_AUTO;
    e = load("/tmp/lai_t/model.gguf", 2048);
    CHECK(g_fake_seen_load_mode == LLAMA_LOAD_MODE_MMAP);   // use_mmap boolean no longer exists
    // llama_tokenize returning INT32_MIN (overflow) must be an error, not UB / a huge allocation.
    g_fake_tokenize_overflow = 1;
    CHECK(start(e, "hi", 5) == LAI_OK);
    o = drain(e);
    CHECK(o.result == LAI_ERR_TOKENIZE);
    const char *r2[] = {"user"}; const char *c2[] = {"hello"};
    CHECK(lai_count_prompt_tokens(e, r2, c2, 1) == -1);
    g_fake_tokenize_overflow = 0;
    g_fake_eog_after = 5; fake_reset_decode_log();
    CHECK(start(e, "hi", 5) == LAI_OK);                      // engine still healthy afterwards
    o = drain(e);
    CHECK(o.result == LAI_OK && g_fake_pos_violations == 0);
    lai_free(e);
  }

  CHECK(g_fake_live_objects == 0);  // nothing leaked
  std::puts("bridge_test OK");
}

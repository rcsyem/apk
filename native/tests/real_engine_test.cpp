// Real-model acceptance driver for the bridge (links lai_bridge only; no llama types).
// Usage: lai_real_test model.gguf [n_ctx=2048] [threads=4]
// Meant for a REAL llama.cpp build + REAL GGUF. It can also be compiled against the
// fake (host self-check of the driver logic only; says nothing about llama.cpp).
// Exit code 0 only if every check passed.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include <sys/resource.h>
#include "lai_bridge.h"

using Clock = std::chrono::steady_clock;
static long peak_rss_kb() { struct rusage ru; return getrusage(RUSAGE_SELF, &ru) == 0 ? ru.ru_maxrss : -1; }  // KB on Linux/Android
static int g_fail = 0;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "  FAIL line %d: %s\n", __LINE__, #c); ++g_fail; } } while (0)

static bool valid_utf8(const std::string &s) {
  size_t i = 0, n = s.size();
  while (i < n) {
    unsigned char c = (unsigned char)s[i];
    int k = c < 0x80 ? 0 : (c >> 5) == 6 ? 1 : (c >> 4) == 14 ? 2 : (c >> 3) == 30 ? 3 : -1;
    if (k < 0) return false;
    for (int j = 1; j <= k; j++)
      if (i + j >= n || ((unsigned char)s[i + j] >> 6) != 2) return false;
    i += 1 + k;
  }
  return true;
}
static bool has_arabic(const std::string &s) {  // U+0600..U+06FF = D8 80 .. DB BF
  for (size_t i = 0; i + 1 < s.size(); i++) { unsigned char a = s[i]; if (a >= 0xD8 && a <= 0xDB) return true; }
  return false;
}

struct Run { int result = -1, stopped = 0, pieces = 0, pt = 0, gt = 0; std::string text, err; double first_ms = -1, total_ms = 0; };

// Drains one generation; optional stop requested from ANOTHER thread after `stop_after_pieces`.
static Run run(lai_engine *e, const char *prompt, float temp, int max_new, int stop_after_pieces = 0,
               double *stop_latency_ms = nullptr) {
  Run r; char err[512] = {0};
  const char *roles[] = {"user"}; const char *contents[] = {prompt};
  auto t0 = Clock::now();
  int rc = lai_generate_start(e, roles, contents, 1, temp, max_new, err, sizeof err);
  if (rc != LAI_OK) { r.result = rc; r.err = err; return r; }
  std::atomic<bool> want_stop{false};
  std::atomic<long long> stop_at_us{0};
  std::thread stopper;
  if (stop_after_pieces > 0) {
    stopper = std::thread([&] {
      while (!want_stop.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
      stop_at_us = std::chrono::duration_cast<std::chrono::microseconds>(Clock::now().time_since_epoch()).count();
      lai_stop(e);  // cross-thread stop
    });
  }
  char buf[512]; int len = 0, bad_polls = 0;
  while (true) {
    int st = lai_next(e, buf, sizeof buf, 100, &len);
    if (st == LAI_NEXT_PIECE) {
      if (r.first_ms < 0) r.first_ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
      r.text.append(buf, (size_t)len); r.pieces++;
      if (stop_after_pieces > 0 && r.pieces == stop_after_pieces) want_stop = true;
    } else if (st == LAI_NEXT_DONE) {
      break;
    } else if (st == LAI_NEXT_TIMEOUT) {
      continue;  // nothing yet (slow prompt evaluation): poll again; NOT an error
    } else {     // SMALL_BUFFER / INVALID: ask the engine to stop, then keep draining until DONE
      if (r.err.empty()) r.err = "lai_next status " + std::to_string(st);
      lai_stop(e);
      if (++bad_polls > 1000) break;
    }
  }
  auto done_us = std::chrono::duration_cast<std::chrono::microseconds>(Clock::now().time_since_epoch()).count();
  if (stopper.joinable()) { want_stop = true; stopper.join(); }
  if (stop_latency_ms && stop_at_us.load() > 0) *stop_latency_ms = (done_us - stop_at_us.load()) / 1000.0;
  r.total_ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
  r.result = lai_result(e, &r.stopped, err, sizeof err);
  if (r.err.empty()) r.err = err;
  lai_stats(e, &r.pt, &r.gt);
  return r;
}

int main(int argc, char **argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: %s model.gguf [n_ctx] [threads]\n", argv[0]); return 2; }
  const int n_ctx = argc > 2 ? std::atoi(argv[2]) : 2048, threads = argc > 3 ? std::atoi(argv[3]) : 4;
  std::fprintf(stderr, "bridge: %s\n", lai_version());
  char err[512] = {0}; lai_engine *e = nullptr;
  auto t = Clock::now();
  int rc = lai_load(argv[1], n_ctx, threads, &e, err, sizeof err);
  std::fprintf(stderr, "[1] load rc=%d (%.0f ms) %s\n", rc, std::chrono::duration<double, std::milli>(Clock::now() - t).count(), err);
  CHECK(rc == LAI_OK && e);
  if (rc != LAI_OK || !e) return 1;

  const char *ar = "اكتب جملة قصيرة بالعربية عن الشمس.";
  Run a = run(e, ar, 0.0f, 48);
  std::fprintf(stderr, "[2] Arabic streaming: rc=%d pieces=%d prompt_tok=%d gen_tok=%d first=%.0f ms arabic_in_output=%d\n--\n%s\n--\n",
               a.result, a.pieces, a.pt, a.gt, a.first_ms, (int)has_arabic(a.text), a.text.c_str());
  CHECK(a.result == LAI_OK && !a.stopped);
  CHECK(a.pieces > 1 && a.gt > 0 && a.pt > 0);   // genuinely streamed, not one blob
  CHECK(valid_utf8(a.text));                     // nothing invalid reaches the consumer
  CHECK(!a.text.empty());

  // Same prompt, greedy, fresh run on the same engine: identical text proves the cache is
  // cleared and positions restart correctly (a stale/shifted position would diverge).
  Run b = run(e, ar, 0.0f, 48);
  std::fprintf(stderr, "[3] determinism (greedy, 2nd run): identical=%d\n", (int)(a.text == b.text));
  CHECK(b.result == LAI_OK && a.text == b.text && a.pt == b.pt);

  // Long prompt that MUST span several n_batch chunks (n_batch = min(n_ctx, 512)). The prompt is
  // grown with the engine's own token counter, so the multi-chunk path cannot be skipped silently.
  std::string longp;
  {
    const char *r1[] = {"user"};
    int cnt = 0;
    while (cnt < 700 && longp.size() < 20000) {
      longp += "الشمس تشرق من الشرق وتغرب في الغرب. ";
      const char *c1[] = {longp.c_str()};
      cnt = lai_count_prompt_tokens(e, r1, c1, 1);
      if (cnt < 0) break;
    }
    std::fprintf(stderr, "[4a] long prompt built: %zu bytes, %d tokens (template applied)\n", longp.size(), cnt);
    CHECK(cnt > 512 && cnt < n_ctx - 64);
  }
  const long rss_before = peak_rss_kb();
  Run c = run(e, longp.c_str(), 0.0f, 16);
  std::fprintf(stderr, "[4b] peak RSS %ld MB -> %ld MB across the long-prompt step (informational; requesting logits for\n"
                       "     every prompt token instead of the last one measured +600 MB on the synthetic model, vocab 151936)\n",
               rss_before / 1024, peak_rss_kb() / 1024);
  std::fprintf(stderr, "[4] long prompt: rc=%d prompt_tok=%d gen_tok=%d err='%s'\n", c.result, c.pt, c.gt, c.err.c_str());
  CHECK(c.result == LAI_OK && c.pt > 512 && c.gt > 0 && valid_utf8(c.text));

  // Stop from another thread, then the engine must be reusable.
  double stop_ms = -1;
  Run d = run(e, "اكتب قصة طويلة جداً عن رحلة في الصحراء.", 0.7f, 400, 3, &stop_ms);
  std::fprintf(stderr, "[5] cross-thread stop: rc=%d stopped=%d gen_tok=%d stop->done %.0f ms\n", d.result, d.stopped, d.gt, stop_ms);
  CHECK(d.result == LAI_OK && d.stopped == 1 && d.gt < 400);
  CHECK(stop_ms >= 0 && stop_ms < 10000);
  Run f = run(e, "قل مرحبا.", 0.0f, 16);
  std::fprintf(stderr, "[6] reuse after stop: rc=%d gen_tok=%d\n", f.result, f.gt);
  CHECK(f.result == LAI_OK && f.gt > 0 && valid_utf8(f.text));

  lai_free(e);  // the main engine is done; edge cases below use a small context

  // Context edge with the REAL library: n_ctx=256. A short prompt with a huge max_new must end
  // cleanly at the context limit (no decode error: the real llama_decode rejects positions >= n_ctx
  // and non-contiguous positions), and a prompt that cannot fit must be refused up-front.
  {
    lai_engine *s = nullptr;
    rc = lai_load(argv[1], 256, threads, &s, err, sizeof err);
    CHECK(rc == LAI_OK && s);
    if (rc == LAI_OK && s) {
      Run g = run(s, "اكتب قصة.", 0.7f, 5000);
      std::fprintf(stderr, "[8] context edge (n_ctx=256, max_new=5000): rc=%d prompt_tok=%d gen_tok=%d err='%s'\n", g.result, g.pt, g.gt, g.err.c_str());
      CHECK(g.result == LAI_OK && g.pt + g.gt <= 256 && g.gt > 100);
      std::string big;
      for (int i = 0; i < 60; i++) big += "الشمس تشرق من الشرق وتغرب في الغرب. ";
      Run h = run(s, big.c_str(), 0.0f, 16);
      std::fprintf(stderr, "[9] prompt larger than context: rc=%d (expect %d) prompt_tok=%d\n", h.result, LAI_ERR_PROMPT_TOO_LONG, h.pt);
      CHECK(h.result == LAI_ERR_PROMPT_TOO_LONG);
      Run k = run(s, "قل مرحبا.", 0.0f, 8);   // engine still usable after the refusal
      CHECK(k.result == LAI_OK && k.gt > 0);
      lai_free(s);
    }
  }

  // Safe free while a generation is in flight (no stop, no drain): fresh engine.
  rc = lai_load(argv[1], n_ctx, threads, &e, err, sizeof err);
  CHECK(rc == LAI_OK && e);
  if (rc != LAI_OK || !e) return 1;
  // Safe free while a generation is in flight (no stop, no drain).
  const char *roles[] = {"user"}; const char *contents[] = {"اكتب مقالاً طويلاً عن التاريخ."};
  rc = lai_generate_start(e, roles, contents, 1, 0.7f, 400, err, sizeof err);
  CHECK(rc == LAI_OK);
  char buf[256]; int len = 0;
  for (int i = 0; i < 200; i++) { if (lai_next(e, buf, sizeof buf, 100, &len) == LAI_NEXT_PIECE) break; }
  auto tf = Clock::now();
  lai_free(e);
  double free_ms = std::chrono::duration<double, std::milli>(Clock::now() - tf).count();
  std::fprintf(stderr, "[7] free during generation returned in %.0f ms\n", free_ms);
  CHECK(free_ms < 15000);
  std::fprintf(stderr, g_fail ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", g_fail);
  return g_fail ? 1 : 0;
}

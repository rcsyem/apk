// Engine proof-of-concept CLI (no Flutter). Loads a GGUF, runs one prompt via the
// async API, optionally stops it from ANOTHER thread, then frees the engine only
// after generation has really ended and the stopper thread has been joined.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include "lai_bridge.h"

using Clock = std::chrono::steady_clock;
static double ms_since(Clock::time_point t) {
  return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s model.gguf \"prompt\" [n_ctx=2048] [threads=4] [max_new=128] [stop_after_ms=0]\n",
                 argv[0]);
    return 2;
  }
  int n_ctx = argc > 3 ? std::atoi(argv[3]) : 2048;
  int threads = argc > 4 ? std::atoi(argv[4]) : 4;
  int max_new = argc > 5 ? std::atoi(argv[5]) : 128;
  int stop_after = argc > 6 ? std::atoi(argv[6]) : 0;

  char err[512] = {0};
  lai_engine *e = nullptr;
  auto t_load = Clock::now();
  int rc = lai_load(argv[1], n_ctx, threads, &e, err, sizeof err);
  double load_ms = ms_since(t_load);
  if (rc != LAI_OK) {
    std::fprintf(stderr, "load failed rc=%d: %s\n", rc, err);
    return 1;
  }
  std::fprintf(stderr, "[load: %.0f ms]\n", load_ms);

  const char *roles[] = {"user"};
  const char *contents[] = {argv[2]};
  auto t0 = Clock::now();
  rc = lai_generate_start(e, roles, contents, 1, 0.7f, max_new, err, sizeof err);
  if (rc != LAI_OK) {
    std::fprintf(stderr, "start failed rc=%d: %s\n", rc, err);
    lai_free(e);
    return 1;
  }

  std::thread stopper;
  if (stop_after > 0) {
    stopper = std::thread([e, stop_after] {
      std::this_thread::sleep_for(std::chrono::milliseconds(stop_after));
      lai_stop(e);  // real cross-thread stop
    });
  }

  char buf[512];
  int len = 0, pieces = 0;
  double first_ms = -1, last_ms = 0;
  while (true) {
    int st = lai_next(e, buf, sizeof buf, 100, &len);
    if (st == LAI_NEXT_PIECE) {
      if (first_ms < 0) first_ms = ms_since(t0);
      last_ms = ms_since(t0);
      ++pieces;
      std::fwrite(buf, 1, (size_t)len, stdout);
      std::fflush(stdout);
    } else if (st == LAI_NEXT_DONE) {
      break;
    } else if (st == LAI_NEXT_SMALL_BUFFER || st == LAI_NEXT_INVALID) {
      std::fprintf(stderr, "\nlai_next failed st=%d\n", st);
      lai_stop(e);
      break;
    }
  }
  if (stopper.joinable()) stopper.join();  // never call lai_stop after lai_free

  int stopped = 0;
  int grc = lai_result(e, &stopped, err, sizeof err);
  int pt = 0, gt = 0;
  lai_stats(e, &pt, &gt);
  double gen_s = (last_ms - (first_ms < 0 ? 0 : first_ms)) / 1000.0;
  std::fprintf(stderr,
               "\n[result=%d stopped=%d err='%s']\n"
               "[prompt_tokens=%d generated_tokens=%d (engine counters)]\n"
               "[first-piece latency: %.0f ms]\n"
               "[decode rate: %.2f tokens/s (generated_tokens, first->last piece)]\n"
               "[pieces=%d (text chunks; NOT tokens)]\n",
               grc, stopped, err, pt, gt, first_ms, gen_s > 0 ? (gt - 1) / gen_s : 0.0,
               pieces);

  lai_free(e);  // after generation ended and stopper joined
  std::fprintf(stderr, "[freed]\n");
  return grc == LAI_OK ? 0 : 1;
}

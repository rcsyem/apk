/* Thin C ABI between Dart FFI and llama.cpp.
 *
 * Design rules
 *  - Only plain C types cross the boundary. No C++ exception ever escapes.
 *  - NO callbacks into Dart and NO pointers to native-stack memory are handed
 *    out. Generation runs on a native worker thread and produces UTF-8 pieces
 *    into a bounded queue owned by the engine. The consumer (a Dart worker
 *    isolate) pulls with lai_next(), which COPIES into a caller-owned buffer.
 *  - Thread-safety: lai_stop / lai_next / lai_stats / lai_result may be called
 *    concurrently with a running generation. lai_free must not run concurrently
 *    with any other call on the same engine, and the handle is invalid after it.
 */
#ifndef LAI_BRIDGE_H
#define LAI_BRIDGE_H
#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define LAI_API __attribute__((visibility("default")))
#else
#define LAI_API
#endif

typedef struct lai_engine lai_engine;

enum {
  LAI_OK = 0,
  LAI_ERR_FILE = 1,           /* missing / unreadable */
  LAI_ERR_MODEL = 2,          /* corrupt or unsupported GGUF */
  LAI_ERR_CONTEXT = 3,        /* context creation failed (often OOM) */
  LAI_ERR_ARGS = 4,
  LAI_ERR_TEMPLATE = 5,
  LAI_ERR_TOKENIZE = 6,
  LAI_ERR_PROMPT_TOO_LONG = 7,
  LAI_ERR_DECODE = 8,
  LAI_ERR_BUSY = 9,
  LAI_ERR_INTERNAL = 10       /* caught C++ exception or unexpected state */
};

/* lai_next() status */
enum {
  LAI_NEXT_INVALID = -1,
  LAI_NEXT_TIMEOUT = 0,       /* nothing yet; call again */
  LAI_NEXT_PIECE = 1,         /* *out_len bytes copied into buf (not NUL-terminated) */
  LAI_NEXT_DONE = 2,          /* generation finished; see lai_result() */
  LAI_NEXT_SMALL_BUFFER = 3   /* *out_len = required size; piece NOT consumed */
};

LAI_API const char *lai_version(void);

/* *out is set to NULL first, always. */
LAI_API int lai_load(const char *model_path, int n_ctx, int n_threads,
                     lai_engine **out, char *err, int err_len);

/* Starts generation on a worker thread and returns immediately.
 * roles[i] in {"system","user","assistant"}; strings are copied before return.
 * Applies the model's own chat template, evaluates the prompt from scratch in
 * n_batch-sized chunks, then streams. Returns LAI_ERR_BUSY if one is running. */
LAI_API int lai_generate_start(lai_engine *e, const char **roles,
                               const char **contents, int n_msgs,
                               float temperature, int max_new, char *err,
                               int err_len);

/* Waits up to timeout_ms for the next piece. Pieces always end on UTF-8
 * character boundaries (except a final flush of a truncated sequence). */
LAI_API int lai_next(lai_engine *e, char *buf, int cap, int timeout_ms,
                     int *out_len);

/* Valid after lai_next() returned LAI_NEXT_DONE. Returns the result code;
 * *stopped = 1 if generation ended because of lai_stop(). */
LAI_API int lai_result(lai_engine *e, int *stopped, char *err, int err_len);

/* Cooperative, thread-safe. Idempotent. */
LAI_API void lai_stop(lai_engine *e);

/* Real engine token counters for the last/current generation. */
LAI_API int lai_stats(lai_engine *e, int *prompt_tokens, int *generated_tokens);

LAI_API int lai_count_prompt_tokens(lai_engine *e, const char **roles,
                                    const char **contents, int n_msgs);

/* Stops any generation, joins the worker, frees context + model. Returns only
 * after memory is released. */
LAI_API void lai_free(lai_engine *e);

#ifdef __cplusplus
}
#endif
#endif

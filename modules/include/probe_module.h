/* probe_module.h - a deliberately tiny C ABI shared by the demo modules.
 *
 * Each module exports ONE entry function, named per language so that all of
 * them can be statically linked into the same binary:
 *     const pm_module *probe_<lang>_module(void);
 * The returned table is static and lives for the lifetime of the process.
 *
 * Conventions:
 *  - No exceptions/panics cross the boundary.
 *  - Bytes returned by `reverse` are owned by the module and must be given
 *    back through the same module's `free_bytes`.
 *  - A counter handle is created by `counter_new` and destroyed by
 *    `counter_free` of the same module.
 *  - `count_to` calls host->callback(host->ctx, cb_id, i) for every step
 *    synchronously, on the calling thread, and returns the number of calls.
 */
#ifndef PROBE_MODULE_H
#define PROBE_MODULE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define PM_EXPORT __declspec(dllexport)
#else
#define PM_EXPORT __attribute__((visibility("default")))
#endif

#define PM_ABI_VERSION 1u

typedef void (*pm_callback_fn)(void *ctx, uint64_t cb_id, int64_t value);

typedef struct pm_host {
  uint32_t version;
  void *ctx;
  pm_callback_fn callback;
} pm_host;

typedef struct pm_module {
  uint32_t version; /* PM_ABI_VERSION */
  const char *name; /* NUL-terminated, static */
  int64_t (*add)(int64_t a, int64_t b);
  /* Reverse UTF-8 text by code point. 0 on success. */
  int32_t (*reverse)(const uint8_t *s, size_t len, uint8_t **out, size_t *out_len);
  void (*free_bytes)(uint8_t *p, size_t len);
  void *(*counter_new)(int64_t start);
  int64_t (*count_to)(void *counter, int64_t target, const pm_host *host, uint64_t cb_id);
  void (*counter_free)(void *counter);
} pm_module;

typedef const pm_module *(*pm_entry_fn)(void);

const pm_module *probe_c_module(void);
const pm_module *probe_rust_module(void);
const pm_module *probe_zig_module(void);
#ifndef PM_NO_GO_DECL /* the Go module's cgo header declares it itself */
const pm_module *probe_go_module(void);
#endif

#ifdef __cplusplus
}
#endif
#endif

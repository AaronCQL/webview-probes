#include "_cgo_export.h"

void pm_go_fire(const pm_host *h, uint64_t id, int64_t v) { h->callback(h->ctx, id, v); }

static void *g_counter_new(int64_t start) { return (void *)(uintptr_t)pm_go_counter_new(start); }
static int64_t g_count_to(void *c, int64_t target, const pm_host *host, uint64_t cb) {
  return pm_go_count_to((uintptr_t)c, target, (pm_host *)host, cb);
}
static void g_counter_free(void *c) { pm_go_counter_free((uintptr_t)c); }

static const pm_module GO_MODULE = {
    PM_ABI_VERSION,
    "go",
    (int64_t (*)(int64_t, int64_t))pm_go_add,
    (int32_t (*)(const uint8_t *, size_t, uint8_t **, size_t *))pm_go_reverse,
    (void (*)(uint8_t *, size_t))pm_go_free_bytes,
    g_counter_new,
    g_count_to,
    g_counter_free,
};

const pm_module *pm_go_table(void) { return &GO_MODULE; }

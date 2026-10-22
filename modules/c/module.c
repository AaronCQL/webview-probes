#include <stdlib.h>
#include <string.h>

#include "probe_module.h"

static int64_t c_add(int64_t a, int64_t b) { return a + b; }

static int32_t c_reverse(const uint8_t *s, size_t len, uint8_t **out, size_t *out_len) {
  uint8_t *buf = (uint8_t *)malloc(len ? len : 1);
  if (!buf) return 1;
  size_t w = 0, end = len;
  while (end > 0) {
    size_t start = end - 1;
    while (start > 0 && (s[start] & 0xC0) == 0x80) start--;
    memcpy(buf + w, s + start, end - start);
    w += end - start;
    end = start;
  }
  *out = buf;
  *out_len = w;
  return 0;
}

static void c_free_bytes(uint8_t *p, size_t len) {
  (void)len;
  free(p);
}

static void *c_counter_new(int64_t start) {
  int64_t *c = (int64_t *)malloc(sizeof(int64_t));
  if (c) *c = start;
  return c;
}

static int64_t c_count_to(void *counter, int64_t target, const pm_host *host, uint64_t cb_id) {
  int64_t *c = (int64_t *)counter;
  int64_t calls = 0;
  while (*c < target) {
    *c += 1;
    host->callback(host->ctx, cb_id, *c);
    calls++;
  }
  return calls;
}

static void c_counter_free(void *counter) { free(counter); }

static const pm_module C_MODULE = {
    PM_ABI_VERSION, "c", c_add, c_reverse, c_free_bytes, c_counter_new, c_count_to, c_counter_free,
};

PM_EXPORT const pm_module *probe_c_module(void) { return &C_MODULE; }

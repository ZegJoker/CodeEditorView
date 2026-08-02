#include "codeeditor_ghostty_test_spool.h"
#include <stdlib.h>
#include <string.h>

/* Test-only: minimal ordered byte spool. Not a terminal emulator. */

struct ce_test_spool_surface {
    uint8_t *screen;
    size_t screen_len;
    size_t screen_cap;
    uint8_t *spool;
    size_t spool_len;
    size_t spool_cap;
    uint64_t generation;
};

ce_test_spool_surface *ce_test_spool_create(const ce_test_spool_config *config) {
    (void)config;
    ce_test_spool_surface *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->screen_cap = 256 * 1024;
    s->spool_cap = 64 * 1024;
    s->screen = malloc(s->screen_cap);
    s->spool = malloc(s->spool_cap);
    if (!s->screen || !s->spool) {
        free(s->screen);
        free(s->spool);
        free(s);
        return NULL;
    }
    return s;
}

void ce_test_spool_destroy(ce_test_spool_surface *surface) {
    if (!surface) return;
    free(surface->screen);
    free(surface->spool);
    free(surface);
}

int ce_test_spool_write(ce_test_spool_surface *surface, const uint8_t *bytes, size_t len) {
    if (!surface || (!bytes && len)) return -1;
    if (surface->screen_len + len + 1 > surface->screen_cap) {
        size_t ncap = (surface->screen_cap + len) * 2;
        uint8_t *n = realloc(surface->screen, ncap);
        if (!n) return -1;
        surface->screen = n;
        surface->screen_cap = ncap;
    }
    memcpy(surface->screen + surface->screen_len, bytes, len);
    surface->screen_len += len;
    surface->screen[surface->screen_len] = 0;
    surface->generation += 1;
    return (int)len;
}

int ce_test_spool_read(ce_test_spool_surface *surface, uint8_t *out, size_t cap) {
    if (!surface || !out || cap == 0) return -1;
    size_t n = surface->spool_len < cap ? surface->spool_len : cap;
    if (n == 0) return 0;
    memcpy(out, surface->spool, n);
    memmove(surface->spool, surface->spool + n, surface->spool_len - n);
    surface->spool_len -= n;
    return (int)n;
}

int ce_test_spool_snapshot_utf8(ce_test_spool_surface *surface, char *out, size_t cap) {
    if (!surface || !out || cap == 0) return -1;
    size_t n = surface->screen_len < (cap - 1) ? surface->screen_len : (cap - 1);
    memcpy(out, surface->screen, n);
    out[n] = 0;
    return (int)n;
}

int ce_test_spool_key_input(ce_test_spool_surface *surface, const uint8_t *bytes, size_t len) {
    if (!surface || (!bytes && len)) return -1;
    if (surface->spool_len + len > surface->spool_cap) {
        size_t ncap = (surface->spool_cap + len) * 2;
        uint8_t *n = realloc(surface->spool, ncap);
        if (!n) return -1;
        surface->spool = n;
        surface->spool_cap = ncap;
    }
    memcpy(surface->spool + surface->spool_len, bytes, len);
    surface->spool_len += len;
    return (int)len;
}

uint64_t ce_test_spool_generation(const ce_test_spool_surface *surface) {
    return surface ? surface->generation : 0;
}

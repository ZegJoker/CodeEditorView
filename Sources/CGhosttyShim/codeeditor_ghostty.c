#include "codeeditor_ghostty.h"
#include <stdlib.h>
#include <string.h>

/*
 * Until libghostty is linked (CODEEDITOR_GHOSTTY_LINKED), this file provides a
 * minimal VT-less byte spool so the Swift Ghostty adapter and workbench can
 * compile and exercise lifecycle. Production terminal quality requires linking
 * real Ghostty per GHOSTTY.pin — ce_ghostty_is_linked() reports that state.
 */

struct ce_ghostty_surface {
    ce_ghostty_size size;
    uint8_t *spool;
    size_t spool_len;
    size_t spool_cap;
    char *screen;
    size_t screen_len;
    size_t screen_cap;
};

int ce_ghostty_shim_abi(void) {
    return CE_GHOSTTY_SHIM_ABI;
}

bool ce_ghostty_is_linked(void) {
#if defined(CODEEDITOR_GHOSTTY_LINKED)
    return true;
#else
    return false;
#endif
}

ce_ghostty_surface *ce_ghostty_surface_create(const ce_ghostty_config *config) {
    ce_ghostty_surface *s = calloc(1, sizeof(ce_ghostty_surface));
    if (!s) return NULL;
    s->size.cols = config && config->cols ? config->cols : 80;
    s->size.rows = config && config->rows ? config->rows : 24;
    s->spool_cap = 64 * 1024;
    s->spool = malloc(s->spool_cap);
    s->screen_cap = 256 * 1024;
    s->screen = malloc(s->screen_cap);
    if (!s->spool || !s->screen) {
        free(s->spool);
        free(s->screen);
        free(s);
        return NULL;
    }
    s->screen_len = 0;
    s->spool_len = 0;
    return s;
}

void ce_ghostty_surface_destroy(ce_ghostty_surface *surface) {
    if (!surface) return;
    free(surface->spool);
    free(surface->screen);
    free(surface);
}

int ce_ghostty_surface_write(ce_ghostty_surface *surface, const uint8_t *bytes, size_t len) {
    if (!surface || (!bytes && len)) return -1;
    /* Append to screen snapshot (raw UTF-8 pass-through until Ghostty linked). */
    if (surface->screen_len + len + 1 > surface->screen_cap) {
        size_t ncap = (surface->screen_cap + len) * 2;
        char *n = realloc(surface->screen, ncap);
        if (!n) return -1;
        surface->screen = n;
        surface->screen_cap = ncap;
    }
    memcpy(surface->screen + surface->screen_len, bytes, len);
    surface->screen_len += len;
    surface->screen[surface->screen_len] = 0;
    return (int)len;
}

int ce_ghostty_surface_read(ce_ghostty_surface *surface, uint8_t *out, size_t cap) {
    if (!surface || !out || cap == 0) return -1;
    size_t n = surface->spool_len < cap ? surface->spool_len : cap;
    if (n == 0) return 0;
    memcpy(out, surface->spool, n);
    memmove(surface->spool, surface->spool + n, surface->spool_len - n);
    surface->spool_len -= n;
    return (int)n;
}

int ce_ghostty_surface_resize(ce_ghostty_surface *surface, ce_ghostty_size size) {
    if (!surface) return -1;
    surface->size = size;
    return 0;
}

int ce_ghostty_surface_snapshot_utf8(ce_ghostty_surface *surface, char *out, size_t cap) {
    if (!surface || !out || cap == 0) return -1;
    size_t n = surface->screen_len < (cap - 1) ? surface->screen_len : (cap - 1);
    memcpy(out, surface->screen, n);
    out[n] = 0;
    return (int)n;
}

int ce_ghostty_surface_key_input(ce_ghostty_surface *surface, const uint8_t *bytes, size_t len) {
    if (!surface || (!bytes && len)) return -1;
    /* Queue host→PTY bytes in spool (read via ce_ghostty_surface_read). */
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

#include "codeeditor_ghostty.h"

#include <stdlib.h>
#include <string.h>

/*
 * TER-N01: Production default is fail-closed when Ghostty is not linked.
 * There is no VT-less byte-spool fallback in this translation unit.
 *
 * When CODEEDITOR_GHOSTTY_LINKED is defined, surfaces wrap libghostty-vt
 * (Ghostty VT engine). Host UI may render formatted text but must not claim
 * full Metal/CoreText Ghostty surface unless integration level says so.
 */

#if defined(CODEEDITOR_GHOSTTY_LINKED)

#ifndef GHOSTTY_STATIC
#define GHOSTTY_STATIC 1
#endif
#include <ghostty/vt.h>

struct ce_ghostty_surface {
    GhosttyTerminal terminal;
    GhosttyKeyEncoder encoder;
    uint8_t *spool;
    size_t spool_len;
    size_t spool_cap;
    uint64_t generation;
    uint32_t cols;
    uint32_t rows;
};

static int spool_append(ce_ghostty_surface *s, const uint8_t *bytes, size_t len) {
    if (!s || (!bytes && len)) return -1;
    if (len == 0) return 0;
    if (s->spool_len + len > s->spool_cap) {
        size_t ncap = (s->spool_cap + len) * 2;
        if (ncap < 4096) ncap = 4096;
        uint8_t *n = realloc(s->spool, ncap);
        if (!n) return -1;
        s->spool = n;
        s->spool_cap = ncap;
    }
    memcpy(s->spool + s->spool_len, bytes, len);
    s->spool_len += len;
    return (int)len;
}

static void write_pty_cb(GhosttyTerminal terminal, void *userdata, const uint8_t *data, size_t len) {
    (void)terminal;
    ce_ghostty_surface *s = (ce_ghostty_surface *)userdata;
    if (!s || !data || len == 0) return;
    (void)spool_append(s, data, len);
}

int ce_ghostty_shim_abi(void) {
    return CE_GHOSTTY_SHIM_ABI;
}

bool ce_ghostty_is_linked(void) {
    return true;
}

int ce_ghostty_integration_level(void) {
    /* libghostty-vt: terminal state + encoder; host owns rendering. */
    return CE_GHOSTTY_INTEGRATION_VT_ENGINE;
}

ce_ghostty_surface *ce_ghostty_surface_create(const ce_ghostty_config *config) {
    uint16_t cols = (uint16_t)(config && config->cols ? config->cols : 80);
    uint16_t rows = (uint16_t)(config && config->rows ? config->rows : 24);
    if (cols == 0) cols = 80;
    if (rows == 0) rows = 24;

    ce_ghostty_surface *s = calloc(1, sizeof(ce_ghostty_surface));
    if (!s) return NULL;
    s->cols = cols;
    s->rows = rows;
    s->spool_cap = 64 * 1024;
    s->spool = malloc(s->spool_cap);
    if (!s->spool) {
        free(s);
        return NULL;
    }

    GhosttyResult rc = ghostty_terminal_new(NULL, &s->terminal, cols, rows);
    if (rc != GHOSTTY_SUCCESS || !s->terminal) {
        free(s->spool);
        free(s);
        return NULL;
    }

    rc = ghostty_key_encoder_new(NULL, &s->encoder);
    if (rc != GHOSTTY_SUCCESS || !s->encoder) {
        ghostty_terminal_free(s->terminal);
        free(s->spool);
        free(s);
        return NULL;
    }
    ghostty_key_encoder_setopt_from_terminal(s->encoder, s->terminal);

    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, s);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                         (const void *)write_pty_cb);

    return s;
}

void ce_ghostty_surface_destroy(ce_ghostty_surface *surface) {
    if (!surface) return;
    if (surface->encoder) {
        ghostty_key_encoder_free(surface->encoder);
        surface->encoder = NULL;
    }
    if (surface->terminal) {
        ghostty_terminal_set(surface->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, NULL);
        ghostty_terminal_set(surface->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, NULL);
        ghostty_terminal_free(surface->terminal);
        surface->terminal = NULL;
    }
    free(surface->spool);
    free(surface);
}

int ce_ghostty_surface_write(ce_ghostty_surface *surface, const uint8_t *bytes, size_t len) {
    if (!surface || !surface->terminal || (!bytes && len)) return -1;
    /* Raw bytes into Ghostty VT stream — never decode as Swift String (TER-N05). */
    ghostty_terminal_vt_write(surface->terminal, bytes, len);
    surface->generation += 1;
    ghostty_key_encoder_setopt_from_terminal(surface->encoder, surface->terminal);
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
    if (!surface || !surface->terminal) return -1;
    uint16_t cols = size.cols ? (uint16_t)(size.cols > 0xFFFF ? 0xFFFF : size.cols) : 80;
    uint16_t rows = size.rows ? (uint16_t)(size.rows > 0xFFFF ? 0xFFFF : size.rows) : 24;
    if (cols == 0) cols = 1;
    if (rows == 0) rows = 1;
    uint32_t cw = size.width_px && size.cols ? size.width_px / size.cols : 0;
    uint32_t ch = size.height_px && size.rows ? size.height_px / size.rows : 0;
    GhosttyResult rc = ghostty_terminal_resize(surface->terminal, cols, rows, cw, ch);
    if (rc != GHOSTTY_SUCCESS) return -1;
    surface->cols = cols;
    surface->rows = rows;
    surface->generation += 1;
    ghostty_key_encoder_setopt_from_terminal(surface->encoder, surface->terminal);
    return 0;
}

int ce_ghostty_surface_snapshot_utf8(ce_ghostty_surface *surface, char *out, size_t cap) {
    if (!surface || !surface->terminal || !out || cap == 0) return -1;

    GhosttyFormatterTerminalOptions fmt_opts = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    fmt_opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    fmt_opts.trim = true;

    GhosttyFormatter formatter = NULL;
    GhosttyResult rc = ghostty_formatter_terminal_new(NULL, &formatter, surface->terminal, fmt_opts);
    if (rc != GHOSTTY_SUCCESS || !formatter) return -1;

    uint8_t *buf = NULL;
    size_t len = 0;
    rc = ghostty_formatter_format_alloc(formatter, NULL, &buf, &len);
    ghostty_formatter_free(formatter);
    if (rc != GHOSTTY_SUCCESS) {
        if (buf) ghostty_free(NULL, buf, len);
        return -1;
    }

    size_t n = len < (cap - 1) ? len : (cap - 1);
    if (buf && n > 0) {
        memcpy(out, buf, n);
    }
    out[n] = 0;
    if (buf) ghostty_free(NULL, buf, len);
    return (int)n;
}

int ce_ghostty_surface_key_input(ce_ghostty_surface *surface, const uint8_t *bytes, size_t len) {
    if (!surface || (!bytes && len)) return -1;
    /* Treat as UTF-8 text press for legacy callers. */
    ce_ghostty_key_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.action = CE_GHOSTTY_KEY_ACTION_PRESS;
    ev.utf8 = (const char *)bytes;
    ev.utf8_len = len;
    return ce_ghostty_surface_encode_key(surface, &ev, NULL, 0) >= 0 ? 0 : -1;
}

int ce_ghostty_surface_encode_key(
    ce_ghostty_surface *surface,
    const ce_ghostty_key_event *event,
    uint8_t *out,
    size_t cap
) {
    if (!surface || !surface->encoder || !event) return -1;

    GhosttyKeyEvent ke = NULL;
    if (ghostty_key_event_new(NULL, &ke) != GHOSTTY_SUCCESS || !ke) return -1;

    GhosttyKeyAction action = GHOSTTY_KEY_ACTION_PRESS;
    if (event->action == CE_GHOSTTY_KEY_ACTION_RELEASE) action = GHOSTTY_KEY_ACTION_RELEASE;
    else if (event->action == CE_GHOSTTY_KEY_ACTION_REPEAT) action = GHOSTTY_KEY_ACTION_REPEAT;
    ghostty_key_event_set_action(ke, action);

    if (event->key != 0) {
        ghostty_key_event_set_key(ke, (GhosttyKey)event->key);
    }
    ghostty_key_event_set_mods(ke, (GhosttyMods)event->mods);
    ghostty_key_event_set_composing(ke, event->composing != 0);
    if (event->utf8 && event->utf8_len > 0) {
        ghostty_key_event_set_utf8(ke, event->utf8, event->utf8_len);
    }

    ghostty_key_encoder_setopt_from_terminal(surface->encoder, surface->terminal);

    char stack[512];
    size_t written = 0;
    GhosttyResult rc = ghostty_key_encoder_encode(
        surface->encoder, ke, stack, sizeof(stack), &written);
    if (rc == GHOSTTY_OUT_OF_SPACE) {
        char *dyn = malloc(written > 0 ? written : 1);
        if (!dyn) {
            ghostty_key_event_free(ke);
            return -1;
        }
        rc = ghostty_key_encoder_encode(surface->encoder, ke, dyn, written, &written);
        if (rc == GHOSTTY_SUCCESS && written > 0) {
            (void)spool_append(surface, (const uint8_t *)dyn, written);
            if (out && cap > 0) {
                size_t n = written < cap ? written : cap;
                memcpy(out, dyn, n);
                free(dyn);
                ghostty_key_event_free(ke);
                return (int)n;
            }
        }
        free(dyn);
        ghostty_key_event_free(ke);
        return rc == GHOSTTY_SUCCESS ? (int)written : -1;
    }

    ghostty_key_event_free(ke);
    if (rc != GHOSTTY_SUCCESS) return -1;
    if (written > 0) {
        (void)spool_append(surface, (const uint8_t *)stack, written);
        if (out && cap > 0) {
            size_t n = written < cap ? written : cap;
            memcpy(out, stack, n);
            return (int)n;
        }
    }
    return (int)written;
}

uint64_t ce_ghostty_surface_generation(const ce_ghostty_surface *surface) {
    return surface ? surface->generation : 0;
}

#else /* !CODEEDITOR_GHOSTTY_LINKED — production fail-closed (TER-N01) */

int ce_ghostty_shim_abi(void) {
    return CE_GHOSTTY_SHIM_ABI;
}

bool ce_ghostty_is_linked(void) {
    return false;
}

int ce_ghostty_integration_level(void) {
    return CE_GHOSTTY_INTEGRATION_UNAVAILABLE;
}

ce_ghostty_surface *ce_ghostty_surface_create(const ce_ghostty_config *config) {
    (void)config;
    /* Never produce a fake terminal surface in production (TER-N01). */
    return NULL;
}

void ce_ghostty_surface_destroy(ce_ghostty_surface *surface) {
    (void)surface;
}

int ce_ghostty_surface_write(ce_ghostty_surface *surface, const uint8_t *bytes, size_t len) {
    (void)surface;
    (void)bytes;
    (void)len;
    return -1;
}

int ce_ghostty_surface_read(ce_ghostty_surface *surface, uint8_t *out, size_t cap) {
    (void)surface;
    (void)out;
    (void)cap;
    return -1;
}

int ce_ghostty_surface_resize(ce_ghostty_surface *surface, ce_ghostty_size size) {
    (void)surface;
    (void)size;
    return -1;
}

int ce_ghostty_surface_snapshot_utf8(ce_ghostty_surface *surface, char *out, size_t cap) {
    (void)surface;
    if (out && cap > 0) out[0] = 0;
    return -1;
}

int ce_ghostty_surface_key_input(ce_ghostty_surface *surface, const uint8_t *bytes, size_t len) {
    (void)surface;
    (void)bytes;
    (void)len;
    return -1;
}

int ce_ghostty_surface_encode_key(
    ce_ghostty_surface *surface,
    const ce_ghostty_key_event *event,
    uint8_t *out,
    size_t cap
) {
    (void)surface;
    (void)event;
    (void)out;
    (void)cap;
    return -1;
}

uint64_t ce_ghostty_surface_generation(const ce_ghostty_surface *surface) {
    (void)surface;
    return 0;
}

#endif /* CODEEDITOR_GHOSTTY_LINKED */

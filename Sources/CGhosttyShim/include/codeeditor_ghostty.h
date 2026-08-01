#pragma once
/**
 * CodeEditor-owned C ABI for Ghostty embedding (TER-001).
 *
 * Direct Ghostty headers are NOT exposed to Swift product surfaces.
 * Pin exact Ghostty revision in Docs/Architecture/GHOSTTY.pin.
 *
 * When CODEEDITOR_GHOSTTY_LINKED is defined, implementations call libghostty.
 * Otherwise a compile-time stub is provided for package evaluation and unit tests
 * of the Swift adapter layer (not a production terminal claim).
 */
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ce_ghostty_surface ce_ghostty_surface;

typedef struct ce_ghostty_config {
    uint32_t cols;
    uint32_t rows;
    uint32_t font_size_milli;
} ce_ghostty_config;

typedef struct ce_ghostty_size {
    uint32_t cols;
    uint32_t rows;
    uint32_t width_px;
    uint32_t height_px;
} ce_ghostty_size;

/** Compile-time feature assertion: bump when shim ABI changes. */
#define CE_GHOSTTY_SHIM_ABI 1

/** Returns CE_GHOSTTY_SHIM_ABI. */
int ce_ghostty_shim_abi(void);

/** True when linked against a real libghostty build. */
bool ce_ghostty_is_linked(void);

/** Create an opaque surface. Returns NULL on failure. */
ce_ghostty_surface *ce_ghostty_surface_create(const ce_ghostty_config *config);

/** Destroy surface; safe on NULL. */
void ce_ghostty_surface_destroy(ce_ghostty_surface *surface);

/** Feed PTY/host bytes into the surface (ordered, no drop). */
int ce_ghostty_surface_write(ce_ghostty_surface *surface, const uint8_t *bytes, size_t len);

/** Read pending terminal→host bytes (keystrokes encoded by Ghostty). */
int ce_ghostty_surface_read(ce_ghostty_surface *surface, uint8_t *out, size_t cap);

/** Resize grid/pixels. */
int ce_ghostty_surface_resize(ce_ghostty_surface *surface, ce_ghostty_size size);

/** Snapshot visible screen as UTF-8 into buffer; returns bytes written or -1. */
int ce_ghostty_surface_snapshot_utf8(ce_ghostty_surface *surface, char *out, size_t cap);

#ifdef __cplusplus
}
#endif

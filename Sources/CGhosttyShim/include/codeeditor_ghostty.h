#pragma once
/**
 * CodeEditor-owned C ABI for Ghostty embedding (TER-N01 / TER-N10).
 *
 * Direct Ghostty headers are NOT exposed to Swift product surfaces.
 * Pin exact Ghostty revision in Docs/Architecture/GHOSTTY.pin.
 *
 * When CODEEDITOR_GHOSTTY_LINKED is defined, implementations call libghostty-vt.
 * Otherwise surface creation fails closed — there is NO production byte-spool
 * fallback (TER-N01). Test-only spool lives under Tests/ only.
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

/** Key action for structured input (mirrors Ghostty key actions). */
typedef enum {
    CE_GHOSTTY_KEY_ACTION_RELEASE = 0,
    CE_GHOSTTY_KEY_ACTION_PRESS = 1,
    CE_GHOSTTY_KEY_ACTION_REPEAT = 2
} ce_ghostty_key_action;

/** Modifier bits for structured key input. */
#define CE_GHOSTTY_MODS_SHIFT (1u << 0)
#define CE_GHOSTTY_MODS_CTRL  (1u << 1)
#define CE_GHOSTTY_MODS_ALT   (1u << 2)
#define CE_GHOSTTY_MODS_SUPER (1u << 3)

/**
 * Structured host key event for Ghostty key encoder (TER-N04).
 * Physical key codes use GhosttyKey numeric values when linked; 0 = unidentified.
 */
typedef struct ce_ghostty_key_event {
    uint32_t key;          /**< Physical key code (GhosttyKey) or 0 */
    uint16_t mods;         /**< CE_GHOSTTY_MODS_* */
    uint8_t action;        /**< ce_ghostty_key_action */
    uint8_t composing;     /**< non-zero while IME composing */
    const char *utf8;      /**< optional layout-dependent text (may be NULL) */
    size_t utf8_len;
} ce_ghostty_key_event;

/**
 * Integration level constants reported by the shim (TER-N02 / TER-N10).
 * 0 = unavailable, 1 = Ghostty VT engine (+ host renderer), 2 = full surface (future).
 */
enum {
    CE_GHOSTTY_INTEGRATION_UNAVAILABLE = 0,
    CE_GHOSTTY_INTEGRATION_VT_ENGINE = 1,
    CE_GHOSTTY_INTEGRATION_FULL_SURFACE = 2
};

/** Compile-time feature assertion: bump when shim ABI changes. */
#define CE_GHOSTTY_SHIM_ABI 2

/** Returns CE_GHOSTTY_SHIM_ABI. */
int ce_ghostty_shim_abi(void);

/** True when linked against a real libghostty-vt build. */
bool ce_ghostty_is_linked(void);

/** Reported integration level (never claims full surface without real link). */
int ce_ghostty_integration_level(void);

/** Create an opaque surface. Returns NULL on failure / when unlinked. */
ce_ghostty_surface *ce_ghostty_surface_create(const ce_ghostty_config *config);

/** Destroy surface; safe on NULL. */
void ce_ghostty_surface_destroy(ce_ghostty_surface *surface);

/** Feed PTY/host bytes into the surface (ordered, no drop). Returns bytes accepted or -1. */
int ce_ghostty_surface_write(ce_ghostty_surface *surface, const uint8_t *bytes, size_t len);

/** Read pending terminal→host bytes (keystrokes / PTY responses). */
int ce_ghostty_surface_read(ce_ghostty_surface *surface, uint8_t *out, size_t cap);

/** Resize grid/pixels. */
int ce_ghostty_surface_resize(ce_ghostty_surface *surface, ce_ghostty_size size);

/**
 * Snapshot visible screen as UTF-8 into buffer; returns bytes written or -1.
 * Derived from Ghostty terminal state when linked — never a raw byte spool.
 */
int ce_ghostty_surface_snapshot_utf8(ce_ghostty_surface *surface, char *out, size_t cap);

/**
 * Legacy raw-byte key path (UTF-8 text only). Prefer encode_key.
 * Returns 0 on success; encoded bytes available via surface_read.
 */
int ce_ghostty_surface_key_input(ce_ghostty_surface *surface, const uint8_t *bytes, size_t len);

/**
 * Structured key encoding via Ghostty key encoder (TER-N04).
 * Encoded host→PTY bytes are queued and drained via surface_read.
 * Returns bytes encoded (>=0) or -1 on failure.
 */
int ce_ghostty_surface_encode_key(
    ce_ghostty_surface *surface,
    const ce_ghostty_key_event *event,
    uint8_t *out,
    size_t cap
);

/** Generation counter incremented on each successful VT write (dirty tracking, TER-N06). */
uint64_t ce_ghostty_surface_generation(const ce_ghostty_surface *surface);

#ifdef __cplusplus
}
#endif

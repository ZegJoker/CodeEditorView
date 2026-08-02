#pragma once
/**
 * Test-only VT-less byte spool (TER-N01).
 *
 * NEVER linked into production products. Used only by CodeEditorTerminalTests
 * / CodeEditorTerminalGhosttyTests harnesses that need a surface-shaped double
 * without building libghostty.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ce_test_spool_surface ce_test_spool_surface;

typedef struct ce_test_spool_config {
    uint32_t cols;
    uint32_t rows;
} ce_test_spool_config;

ce_test_spool_surface *ce_test_spool_create(const ce_test_spool_config *config);
void ce_test_spool_destroy(ce_test_spool_surface *surface);
int ce_test_spool_write(ce_test_spool_surface *surface, const uint8_t *bytes, size_t len);
int ce_test_spool_read(ce_test_spool_surface *surface, uint8_t *out, size_t cap);
int ce_test_spool_snapshot_utf8(ce_test_spool_surface *surface, char *out, size_t cap);
int ce_test_spool_key_input(ce_test_spool_surface *surface, const uint8_t *bytes, size_t len);
uint64_t ce_test_spool_generation(const ce_test_spool_surface *surface);

#ifdef __cplusplus
}
#endif

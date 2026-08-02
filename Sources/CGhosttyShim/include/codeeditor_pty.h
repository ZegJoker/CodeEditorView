#pragma once
/**
 * Async-signal-safe PTY spawn helper (TER-002).
 * No Swift/Foundation in the child: openpty + posix_spawn only.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ce_pty_spawn_result {
    int master_fd;
    pid_t child_pid;
    int error; /* errno-style; 0 on success */
} ce_pty_spawn_result;

/**
 * Spawn `shell` with `argv` (NULL-terminated) as session leader of a PTY.
 * `cwd` may be NULL. Environment is inherited; optional env pairs via
 * `env_keys`/`env_vals` of length `env_count` (applied with setenv in parent
 * before spawn using posix_spawn file actions only — env is passed via envp).
 *
 * On success: master_fd >= 0, child_pid > 0, error == 0.
 * Caller owns master_fd and must waitpid(child_pid).
 */
ce_pty_spawn_result ce_pty_spawn(
    const char *shell,
    char *const argv[],
    const char *cwd,
    char *const envp[],
    uint16_t rows,
    uint16_t cols
);

/** Close master and send SIGTERM to process group of child; waitpid once. */
int ce_pty_terminate(int master_fd, pid_t child_pid);

/** Set window size on master FD. */
int ce_pty_resize(int master_fd, uint16_t rows, uint16_t cols);

#ifdef __cplusplus
}
#endif

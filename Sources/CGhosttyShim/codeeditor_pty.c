#include "codeeditor_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <util.h>
#include <spawn.h>
#else
#include <pty.h>
#include <spawn.h>
#endif

extern char **environ;

ce_pty_spawn_result ce_pty_spawn(
    const char *shell,
    char *const argv[],
    const char *cwd,
    char *const envp[],
    uint16_t rows,
    uint16_t cols
) {
    ce_pty_spawn_result out = {.master_fd = -1, .child_pid = -1, .error = 0};
    if (!shell || !argv || !argv[0]) {
        out.error = EINVAL;
        return out;
    }

    int master = -1;
    int slave = -1;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows ? rows : 24;
    ws.ws_col = cols ? cols : 80;

    if (openpty(&master, &slave, NULL, NULL, &ws) != 0) {
        out.error = errno;
        return out;
    }

    /* Child must be session leader and slave controlling TTY. */
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        out.error = errno;
        close(master);
        close(slave);
        return out;
    }
    if (posix_spawnattr_init(&attr) != 0) {
        out.error = errno;
        posix_spawn_file_actions_destroy(&actions);
        close(master);
        close(slave);
        return out;
    }

    short flags = POSIX_SPAWN_SETSID;
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    posix_spawnattr_setflags(&attr, flags);

    /* stdin/out/err → slave */
    posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, master);
    posix_spawn_file_actions_addclose(&actions, slave);

    /* chdir in child via file actions is not portable; use posix_spawn_file_actions_addchdir_np on Apple */
#if defined(__APPLE__)
    if (cwd && cwd[0]) {
        (void)posix_spawn_file_actions_addchdir_np(&actions, cwd);
    }
#endif

    char *const *use_env = envp ? envp : environ;
    pid_t pid = 0;
    int rc = posix_spawn(&pid, shell, &actions, &attr, argv, use_env);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(slave);

    if (rc != 0) {
        out.error = rc;
        close(master);
        return out;
    }

    /* Make slave the controlling tty for the child: after SETSID, child may need TIOCSCTTY.
     * openpty+posix_spawn on Darwin typically works with slave as stdio; set process group. */
    (void)setpgid(pid, pid);

    out.master_fd = master;
    out.child_pid = pid;
    out.error = 0;
    return out;
}

int ce_pty_terminate(int master_fd, pid_t child_pid) {
    if (child_pid > 0) {
        /* Process group: kill entire tree rooted at session leader. */
        kill(-child_pid, SIGTERM);
        /* Grace: brief wait then SIGKILL group */
        int status = 0;
        pid_t w = waitpid(child_pid, &status, WNOHANG);
        if (w == 0) {
            usleep(50 * 1000);
            w = waitpid(child_pid, &status, WNOHANG);
            if (w == 0) {
                kill(-child_pid, SIGKILL);
                waitpid(child_pid, &status, 0);
            }
        }
    }
    if (master_fd >= 0) {
        close(master_fd);
    }
    return 0;
}

int ce_pty_resize(int master_fd, uint16_t rows, uint16_t cols) {
    if (master_fd < 0) return -1;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows ? rows : 24;
    ws.ws_col = cols ? cols : 80;
    if (ioctl(master_fd, TIOCSWINSZ, &ws) != 0) {
        return -1;
    }
    return 0;
}

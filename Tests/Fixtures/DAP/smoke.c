/* Deterministic DAP fixture for lldb-dap hard gate (DAP-N10).
 * Build: clang -g -O0 -o smoke smoke.c
 * Stop marker lives only on the executable printf line (not in this header).
 */
#include <stdio.h>

int main(void) {
    int x = 42;
    printf("codeeditor-dap-smoke %d\n", x); /* breakpoint_here */
    return 0;
}

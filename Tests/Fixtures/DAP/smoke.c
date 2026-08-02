/* Deterministic DAP fixture for lldb-dap hard gate (DAP-N10).
 * Build: clang -g -O0 -o smoke smoke.c
 * Breakpoint: line with breakpoint_here / int x assignment.
 */
#include <stdio.h>

int main(void) {
    int x = 42; /* breakpoint_here */
    printf("codeeditor-dap-smoke %d\n", x);
    return 0;
}

#include "GUSSignalTrap.h"
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

static int trap_fd = -1;
static const int trapped[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP };

static void on_fatal_signal(int sig) {
    if (trap_fd >= 0) {
        char line[32] = "signal=";
        size_t n = 7;
        char digits[12];
        size_t d = 0;
        int v = sig;
        do { digits[d++] = (char)('0' + v % 10); v /= 10; } while (v > 0 && d < sizeof(digits));
        while (d > 0) line[n++] = digits[--d];
        line[n++] = '\n';
        (void)!write(trap_fd, line, n);
        fsync(trap_fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

int gus_signal_trap_install(const char * path) {
    if (path == NULL) return -1;
    if (trap_fd < 0) {
        trap_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (trap_fd < 0) return -1;
    }
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_fatal_signal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESETHAND;
    for (size_t i = 0; i < sizeof(trapped) / sizeof(trapped[0]); i++) {
        if (sigaction(trapped[i], &action, NULL) != 0) return -1;
    }
    return 0;
}

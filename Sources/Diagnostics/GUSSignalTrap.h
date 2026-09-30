#ifndef GUS_SIGNAL_TRAP_H
#define GUS_SIGNAL_TRAP_H

/// Installs async-signal-safe handlers for fatal signals (SIGABRT from a
/// llama.cpp assert, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP). On a signal the
/// handler writes "signal=<n>\n" to `path` with write(2), then re-raises with
/// the default action so the system crash report is still produced.
/// SIGKILL (jetsam) cannot be caught; the flight recorder infers it instead.
/// Returns 0 on success.
int gus_signal_trap_install(const char * path);

#endif

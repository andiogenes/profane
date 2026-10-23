#ifndef PF_REPL_H
#define PF_REPL_H

#include <stddef.h>

/* Socket REPL wire protocol: the client writes Scheme source; each complete datum is evaluated
 * in the interaction environment and its output and printed values are written back. Closing
 * the write side flushes any trailing datum. Transport lives in the platform shell. */

#define PF_REPL_SOCKET_ENV "PROFANE_REPL_SOCKET"

/* Writes the REPL socket path into OUT: $PROFANE_REPL_SOCKET if set, else
 * ~/Library/Application Support/profane/repl.sock. Returns 0, or -1 if it does not fit
 * (sockaddr_un paths are limited to 104 bytes on macOS). */
int pf_repl_socket_path(char *out, size_t size);

#endif

/* profane-client: talks to a running profane over its socket REPL.
 *
 *   profane-client [--socket PATH] --eval EXPR   evaluate EXPR, print the output, exit
 *   profane-client [--socket PATH]               pipe stdin to the REPL until EOF
 *
 * Later milestones add GIT_EDITOR / SSH_ASKPASS modes (plan §8). */

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "pf_repl.h"

static int usage(void) {
    fprintf(stderr, "usage: profane-client [--socket PATH] [--eval EXPR]\n");
    return 2;
}

static int write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

static int connect_repl(const char *path) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (strlen(path) >= sizeof addr.sun_path) {
        fprintf(stderr, "profane-client: socket path too long\n");
        return -1;
    }
    strcpy(addr.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        fprintf(stderr, "profane-client: %s: %s\n", path, strerror(errno));
        if (fd >= 0) {
            close(fd);
        }
        return -1;
    }
    return fd;
}

/* Copies stdin to the socket (half-closing it at EOF) and the socket to stdout until the
 * server closes the connection. */
static int relay(int sock) {
    char buf[4096];
    int stdin_open = 1;
    for (;;) {
        struct pollfd fds[2] = {{.fd = sock, .events = POLLIN},
                                {.fd = stdin_open ? STDIN_FILENO : -1, .events = POLLIN}};
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
            if (n > 0) {
                if (write_all(sock, buf, (size_t)n) != 0) {
                    return -1;
                }
            } else {
                stdin_open = 0;
                shutdown(sock, SHUT_WR);
            }
        }
        if (fds[0].revents & (POLLIN | POLLHUP)) {
            ssize_t n = read(sock, buf, sizeof buf);
            if (n <= 0) {
                return n == 0 ? 0 : -1;
            }
            if (write_all(STDOUT_FILENO, buf, (size_t)n) != 0) {
                return -1;
            }
        }
    }
}

static int drain(int sock) {
    char buf[4096];
    ssize_t n;
    while ((n = read(sock, buf, sizeof buf)) != 0) {
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (write_all(STDOUT_FILENO, buf, (size_t)n) != 0) {
            return -1;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *socket_path = NULL;
    const char *expr = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            socket_path = argv[++i];
        } else if (strcmp(argv[i], "--eval") == 0 && i + 1 < argc) {
            expr = argv[++i];
        } else {
            return usage();
        }
    }

    char default_path[1024];
    if (!socket_path) {
        if (pf_repl_socket_path(default_path, sizeof default_path) != 0) {
            fprintf(stderr, "profane-client: cannot determine socket path\n");
            return 1;
        }
        socket_path = default_path;
    }

    int sock = connect_repl(socket_path);
    if (sock < 0) {
        return 1;
    }
    int status;
    if (expr) {
        status = write_all(sock, expr, strlen(expr)) == 0 && shutdown(sock, SHUT_WR) == 0
                     ? drain(sock)
                     : -1;
    } else {
        status = relay(sock);
    }
    close(sock);
    return status == 0 ? 0 : 1;
}

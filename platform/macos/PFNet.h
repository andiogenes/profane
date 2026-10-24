#import <Foundation/Foundation.h>

/* Client connections over TCP, optionally with TLS, on Network.framework: the foreign entries
 * behind (profane net). Connecting is asynchronous: everything that happens to a connection is
 * posted to the core's async queue (core/async/pf_async.h) for the token given at connect, in order:
 *
 *   PF_NET_EVENT_OPEN    the connection is ready; data: the negotiated ALPN protocol, UTF-8 (maybe empty)
 *   PF_NET_EVENT_DATA    bytes received
 *   PF_NET_EVENT_CLOSED  the peer closed it or it was closed here; nothing follows
 *   PF_NET_EVENT_ERROR   it failed (refused, unreachable, a certificate that does not verify, ...);
 *                        data: a message, UTF-8; nothing follows
 *
 * Calls may come from the main thread only. */

enum {
    PF_NET_EVENT_OPEN = 1,
    PF_NET_EVENT_DATA = 2,
    PF_NET_EVENT_CLOSED = 3,
    PF_NET_EVENT_ERROR = 4,
};

enum {
    PF_NET_TLS = 1,      /* TLS, verified against the system's trust (and the host name) */
    PF_NET_INSECURE = 2, /* with TLS: accept any certificate (tests, self-signed servers) */
};

/* Output not yet acknowledged (pf_net_consumed) above which receiving pauses. */
#define PF_NET_MAX_OUTSTANDING (256 * 1024)

/* Starts connecting to HOST:PORT. ALPN is a NUL-separated list of protocol names offered in the TLS
 * handshake (may be empty). Returns a connection id (> 0), or -1 for bad arguments. */
int64_t pf_net_connect(const void *host, size_t hlen, int port, int flags, uint64_t token,
                       const void *alpn, size_t alpn_len);
/* Queues BYTES to be sent. Returns 0, or -1 if the id is unknown or the connection is done. */
int pf_net_send(uint32_t conn, const void *bytes, size_t len);
/* Closes the connection (a PF_NET_EVENT_CLOSED follows). */
int pf_net_close(uint32_t conn);
/* Acknowledges N bytes of data events handled, letting receiving go on. */
int pf_net_consumed(uint32_t conn, size_t n);

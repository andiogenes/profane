#import "PFNet.h"

#import <Network/Network.h>

#include "pf_async.h"

@interface PFNetConn : NSObject {
  @public
    nw_connection_t conn;
    uint64_t token;
    BOOL done;
    BOOL receiving; /* a receive is outstanding */
    size_t outstanding;
}
@end
@implementation PFNetConn
@end

static NSMutableDictionary<NSNumber *, PFNetConn *> *table;
static NSLock *lock;
static dispatch_queue_t queue;
static uint32_t next_id = 1;

static void PFNetInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSMutableDictionary dictionary];
        lock = [NSLock new];
        queue = dispatch_queue_create("org.profane.net", DISPATCH_QUEUE_SERIAL);
    });
}

static PFNetConn *lookup(uint32_t id) {
    [lock lock];
    PFNetConn *c = table[@(id)];
    [lock unlock];
    return c;
}

static void post(PFNetConn *c, int kind, const void *data, size_t len) {
    pf_async_post(c->token, kind, data, len);
}

static void post_text(PFNetConn *c, int kind, NSString *text) {
    const char *u = text.UTF8String;
    post(c, kind, u, u ? strlen(u) : 0);
}

/* Ends the connection once: one final event, then forget it. Runs on the net queue. */
static void finish(uint32_t id, PFNetConn *c, int kind, NSString *message) {
    if (c->done) {
        return;
    }
    c->done = YES;
    if (message) {
        post_text(c, kind, message);
    } else {
        post(c, kind, NULL, 0);
    }
    [lock lock];
    [table removeObjectForKey:@(id)];
    [lock unlock];
    nw_connection_cancel(c->conn);
}

static NSString *describe(nw_error_t error) {
    if (!error) {
        return @"unknown error";
    }
    CFErrorRef e = nw_error_copy_cf_error(error);
    NSString *text = e ? CFBridgingRelease(CFErrorCopyDescription(e)) : @"network error";
    NSString *domain = e ? (__bridge NSString *)CFErrorGetDomain(e) : @"";
    long code = e ? (long)CFErrorGetCode(e) : 0;
    if (e) {
        CFRelease(e);
    }
    return [NSString stringWithFormat:@"%@ (%@ %ld)", text, domain, code];
}

static void arm(uint32_t id, PFNetConn *c);

static void on_receive(uint32_t id, PFNetConn *c, dispatch_data_t content,
                       nw_content_context_t context, bool is_complete, nw_error_t error) {
    c->receiving = NO;
    if (content && dispatch_data_get_size(content) > 0) {
        dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer,
                                           size_t size) {
            (void)region;
            (void)offset;
            post(c, PF_NET_EVENT_DATA, buffer, size);
            c->outstanding += size;
            return true;
        });
    }
    if (error) {
        finish(id, c, PF_NET_EVENT_ERROR, describe(error));
    } else if (is_complete && (!context || nw_content_context_get_is_final(context))) {
        finish(id, c, PF_NET_EVENT_CLOSED, nil);
    } else {
        arm(id, c);
    }
}

/* Asks for more data unless too much is waiting for Scheme. */
static void arm(uint32_t id, PFNetConn *c) {
    if (c->done || c->receiving || c->outstanding >= PF_NET_MAX_OUTSTANDING) {
        return;
    }
    c->receiving = YES;
    nw_connection_receive(c->conn, 1, 65536,
                          ^(dispatch_data_t content, nw_content_context_t context, bool is_complete,
                            nw_error_t error) {
                              on_receive(id, c, content, context, is_complete, error);
                          });
}

int64_t pf_net_connect(const void *host, size_t hlen, int port, int flags, uint64_t token,
                       const void *alpn, size_t alpn_len) {
    PFNetInit();
    NSString *h = [[NSString alloc] initWithBytes:host length:hlen encoding:NSUTF8StringEncoding];
    if (h.length == 0 || port < 1 || port > 65535) {
        return -1;
    }
    NSMutableArray<NSString *> *protocols = [NSMutableArray array];
    for (size_t i = 0; i < alpn_len;) {
        size_t n = strnlen((const char *)alpn + i, alpn_len - i);
        if (n > 0) {
            [protocols addObject:[[NSString alloc] initWithBytes:(const char *)alpn + i length:n encoding:NSUTF8StringEncoding]];
        }
        i += n + 1;
    }
    BOOL tls = (flags & PF_NET_TLS) != 0, insecure = (flags & PF_NET_INSECURE) != 0;

    nw_endpoint_t endpoint = nw_endpoint_create_host(h.UTF8String, [NSString stringWithFormat:@"%d", port].UTF8String);
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        tls ? ^(nw_protocol_options_t options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(options);
            for (NSString *p in protocols) {
                sec_protocol_options_add_tls_application_protocol(sec, p.UTF8String);
            }
            if (insecure) {
                sec_protocol_options_set_verify_block(
                    sec,
                    ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                      sec_protocol_verify_complete_t complete) {
                        (void)metadata;
                        (void)trust;
                        complete(true);
                    },
                    queue);
            }
        }
            : NW_PARAMETERS_DISABLE_PROTOCOL,
        ^(nw_protocol_options_t options) {
            nw_tcp_options_set_connection_timeout(options, 20);
            nw_tcp_options_set_no_delay(options, true);
        });
    nw_connection_t conn = nw_connection_create(endpoint, params);
    if (!conn) {
        return -1;
    }
    PFNetConn *c = [PFNetConn new];
    c->conn = conn;
    c->token = token;
    [lock lock];
    uint32_t id = next_id++;
    table[@(id)] = c;
    [lock unlock];

    nw_connection_set_queue(conn, queue);
    nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state, nw_error_t error) {
        switch (state) {
        case nw_connection_state_ready: {
            NSString *negotiated = @"";
            if (tls) {
                nw_protocol_metadata_t meta =
                    nw_connection_copy_protocol_metadata(conn, nw_protocol_copy_tls_definition());
                if (meta && nw_protocol_metadata_is_tls(meta)) {
                    const char *proto = sec_protocol_metadata_get_negotiated_protocol(
                        nw_tls_copy_sec_protocol_metadata(meta));
                    if (proto) {
                        negotiated = @(proto);
                    }
                }
            }
            post_text(c, PF_NET_EVENT_OPEN, negotiated);
            arm(id, c);
            break;
        }
        case nw_connection_state_failed:
            finish(id, c, PF_NET_EVENT_ERROR, describe(error));
            break;
        case nw_connection_state_waiting:
            /* no route, refused, ...: report instead of waiting for the network to come back */
            if (error) {
                finish(id, c, PF_NET_EVENT_ERROR, describe(error));
            }
            break;
        case nw_connection_state_cancelled:
            finish(id, c, PF_NET_EVENT_CLOSED, nil);
            break;
        default:
            break;
        }
    });
    nw_connection_start(conn);
    return id;
}

int pf_net_send(uint32_t id, const void *bytes, size_t len) {
    PFNetInit();
    PFNetConn *c = lookup(id);
    if (!c || c->done) {
        return -1;
    }
    dispatch_data_t data = dispatch_data_create(bytes, len, queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(c->conn, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                       ^(nw_error_t error) {
                           if (error) {
                               finish(id, c, PF_NET_EVENT_ERROR, describe(error));
                           }
                       });
    return 0;
}

int pf_net_close(uint32_t id) {
    PFNetInit();
    PFNetConn *c = lookup(id);
    if (!c) {
        return -1;
    }
    dispatch_async(queue, ^{
        finish(id, c, PF_NET_EVENT_CLOSED, nil);
    });
    return 0;
}

int pf_net_consumed(uint32_t id, size_t n) {
    PFNetInit();
    PFNetConn *c = lookup(id);
    if (!c) {
        return -1;
    }
    dispatch_async(queue, ^{
        c->outstanding = n > c->outstanding ? 0 : c->outstanding - n;
        arm(id, c);
    });
    return 0;
}

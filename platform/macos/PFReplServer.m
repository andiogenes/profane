#import "PFReplServer.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "pf_scheme.h"
#include "pf_utf8.h"

static NSError *posix_error(NSString *what) {
    int code = errno;
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   [NSString stringWithFormat:@"%@: %s", what, strerror(code)]
                           }];
}

static int fill_address(struct sockaddr_un *addr, NSString *path) {
    memset(addr, 0, sizeof *addr);
    addr->sun_family = AF_UNIX;
    const char *p = path.fileSystemRepresentation;
    if (strlen(p) >= sizeof addr->sun_path) {
        errno = ENAMETOOLONG;
        return -1;
    }
    strcpy(addr->sun_path, p);
    return 0;
}

@implementation PFReplServer {
    int _listenFd;
    dispatch_source_t _acceptSource;
    int64_t _nextConnection;
}

- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    if (!(self = [super init])) {
        return nil;
    }
    _path = [path copy];
    _listenFd = -1;

    NSString *dir = path.stringByDeletingLastPathComponent;
    NSError *dirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES
                                                  attributes:@{NSFilePosixPermissions : @0700}
                                                       error:&dirError]) {
        if (error) {
            *error = dirError;
        }
        return nil;
    }

    struct sockaddr_un addr;
    if (fill_address(&addr, path) != 0) {
        if (error) {
            *error = posix_error(@"REPL socket path");
        }
        return nil;
    }

    /* A live socket means another instance owns the REPL; a dead one is stale. */
    int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe >= 0) {
        int live = connect(probe, (struct sockaddr *)&addr, sizeof addr) == 0;
        close(probe);
        if (live) {
            errno = EADDRINUSE;
            if (error) {
                *error = posix_error(path);
            }
            return nil;
        }
    }
    unlink(addr.sun_path);

    _listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_listenFd < 0 || bind(_listenFd, (struct sockaddr *)&addr, sizeof addr) != 0 ||
        chmod(addr.sun_path, 0600) != 0 || listen(_listenFd, 8) != 0) {
        if (error) {
            *error = posix_error(@"REPL socket");
        }
        [self stop];
        return nil;
    }

    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_listenFd, 0,
                                           dispatch_get_main_queue());
    __weak PFReplServer *weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        [weakSelf acceptConnection];
    });
    int fd = _listenFd;
    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(fd);
    });
    dispatch_resume(_acceptSource);
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)stop {
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource); /* the cancel handler closes the fd */
        _acceptSource = nil;
        unlink(_path.fileSystemRepresentation);
    } else if (_listenFd >= 0) {
        close(_listenFd);
    }
    _listenFd = -1;
}

- (void)acceptConnection {
    int fd = accept(_listenFd, NULL, NULL);
    if (fd < 0) {
        return;
    }
    int64_t cid = ++_nextConnection;
    pf_scheme_arg open = PF_SCHEME_INT(cid);
    if (pf_scheme_call("pf-repl-open", &open, 1, NULL) != 0) {
        close(fd);
        return;
    }

    dispatch_queue_t main = dispatch_get_main_queue();
    dispatch_io_t channel = dispatch_io_create(DISPATCH_IO_STREAM, fd, main, ^(int err) {
        (void)err;
        close(fd);
    });
    /* Bytes of a UTF-8 sequence split across reads, held until the rest arrives. */
    NSMutableData *carry = [NSMutableData data];

    void (^send)(const pf_scheme_result *) = ^(const pf_scheme_result *r) {
        if (!r->text || r->len == 0) {
            return;
        }
        dispatch_data_t out =
            dispatch_data_create(r->text, r->len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        dispatch_io_write(channel, 0, out, main, ^(bool done, dispatch_data_t rest, int err) {
            (void)done, (void)rest, (void)err;
        });
    };
    void (^feed)(const char *, size_t) = ^(const char *bytes, size_t len) {
        pf_scheme_arg args[] = {PF_SCHEME_INT(cid), PF_SCHEME_STRING(bytes, len)};
        pf_scheme_result r;
        if (pf_scheme_call("pf-repl-input", args, 2, &r) == 0) {
            send(&r);
            pf_scheme_result_free(&r);
        }
    };

    dispatch_io_read(channel, 0, SIZE_MAX, main, ^(bool done, dispatch_data_t data, int err) {
        if (data && dispatch_data_get_size(data) > 0) {
            dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset,
                                            const void *buffer, size_t size) {
                (void)region, (void)offset;
                [carry appendBytes:buffer length:size];
                return true;
            });
            size_t ready = pf_utf8_complete_prefix(carry.bytes, carry.length);
            if (ready > 0) {
                feed(carry.bytes, ready);
                [carry replaceBytesInRange:NSMakeRange(0, ready) withBytes:NULL length:0];
            }
        }
        if (done) {
            (void)err;
            if (carry.length > 0) {
                feed(carry.bytes, carry.length); /* invalid tail: decoded as U+FFFD */
            }
            pf_scheme_arg close_arg = PF_SCHEME_INT(cid);
            pf_scheme_result r;
            if (pf_scheme_call("pf-repl-close", &close_arg, 1, &r) == 0) {
                send(&r);
                pf_scheme_result_free(&r);
            }
            dispatch_io_close(channel, 0); /* lets queued writes finish first */
        }
    });
}

@end

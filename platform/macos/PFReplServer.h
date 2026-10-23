#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Unix-domain socket REPL (see pf_repl.h for the protocol). Accepts and reads on the main
 * queue and evaluates through (profane repl), so evaluation always happens on the Scheme
 * thread. The socket directory is 0700 and the socket 0600: same-user access only. */
@interface PFReplServer : NSObject

@property (nonatomic, readonly) NSString *path;

- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
- (void)stop;

@end

NS_ASSUME_NONNULL_END

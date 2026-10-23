#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Boots Chez from the app bundle (Resources/boot, Resources/scheme) and registers the shell's
 * foreign entries. Returns 0 on success. */
int PFSchemeBoot(void);

/* Calls a zero-argument Scheme entry point and returns its string result, or nil. */
NSString *_Nullable PFSchemeCallString(const char *proc);

/* Foreign entry: asks the app to terminate once the current Scheme call has returned. */
void pf_app_quit(void);

/* Foreign entry: the system alert sound (unbound keys, failed commands). */
void pf_app_beep(void);

NS_ASSUME_NONNULL_END

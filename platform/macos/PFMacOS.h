#import <Foundation/Foundation.h>

/* Foreign entries behind (profane macos): the pasteboard, opening URLs, AppleScript and other
 * apps' window bounds. Main thread only. Calls that produce text return its byte length and
 * keep the bytes until pf_app_stash_copy takes them (so Scheme can size its buffer without
 * running anything twice). */

/* Length of the text kept by the last call (an error message after a failed one). */
int64_t pf_app_stash_length(void);

/* Copies up to CAP bytes of the text kept by the last call into BUF. */
void pf_app_stash_copy(void *buf, size_t cap);

/* The pasteboard's string: length (>= 0, text kept), or -1 if it holds none. The pasteboard is
 * the general one, or the one named by $PROFANE_PASTEBOARD (so tests leave the clipboard alone). */
int64_t pf_app_pasteboard_string(void);
/* Replaces the pasteboard's contents by a string; returns the new change count. */
int64_t pf_app_pasteboard_set(const void *bytes, size_t len);
int64_t pf_app_pasteboard_count(void);

/* Opens a URL (a file URL opens the file) in its default app. ACTIVATE 0 keeps the app in the
 * background. Returns 1 if URL parsed and was handed to the system, else 0. */
int pf_app_open_url(const void *url, size_t len, int activate);

/* Runs AppleScript source in this process. Returns the length of the result's text (>= 0), or
 * minus the length of the error message (< 0); the text is kept. */
int64_t pf_app_applescript(const void *source, size_t len);

/* On-screen windows of the app named QUERY (or whose pid is QUERY), front to back, one per line
 * as "x y w h" in points from the top left of the main display. Returns the text's length. */
int64_t pf_app_window_bounds(const void *query, size_t len);

/* Keychain generic passwords (login keychain), identified by SERVICE and ACCOUNT (UTF-8). All
 * return -1 for "no such item" and -2 for any other failure, with the system's message kept as
 * text. pf_app_secret_get returns the value's length (>= 0, text kept); pf_app_secret_set adds or
 * replaces an item and returns 0; pf_app_secret_delete returns 0 if it deleted one. */
int64_t pf_app_secret_get(const void *service, size_t slen, const void *account, size_t alen);
int64_t pf_app_secret_set(const void *service, size_t slen, const void *account, size_t alen,
                          const void *value, size_t vlen);
int64_t pf_app_secret_delete(const void *service, size_t slen, const void *account, size_t alen);

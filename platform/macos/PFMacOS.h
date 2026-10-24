#import <Foundation/Foundation.h>

/* Foreign entries behind (profane macos): the pasteboard, opening URLs, AppleScript and other
 * apps' window bounds. Main thread only. Calls that produce text return its byte length and
 * keep the bytes until pf_app_stash_copy takes them (so Scheme can size its buffer without
 * running anything twice). */

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

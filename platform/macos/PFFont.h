#import <CoreText/CoreText.h>

#include "pf_font.h"

/* Core Text side of the font registry (pf_font.h). */

/* The registered font at its nominal size (borrowed), or NULL. Thread-safe. */
CTFontRef _Nullable PFFontGet(pf_font_id font);

/* Id for FONT, registering it if new (e.g. a fallback font Core Text picked while shaping).
 * Main thread. */
pf_font_id PFFontIdForCTFont(CTFontRef _Nonnull font);

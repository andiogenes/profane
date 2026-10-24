#ifndef PF_INPUT_H
#define PF_INPUT_H

#include <stddef.h>

/* Input state the shell needs from Scheme's command loop. Main thread only. */

/* Set while a key sequence is unfinished (after C-x, ...). The shell then sends the next plain
 * key as a key named from the ASCII-capable layout, not as text through the input method, so
 * "C-x o" runs other-window (under any layout) instead of inserting "o". */
void pf_input_set_prefix_pending(int pending);
int pf_input_prefix_pending(void);

/* Set while a command that outlived its time slice is suspended, waiting to be resumed (engines,
 * plan §0). The shell then keeps running its event loop between slices so C-g can reach Scheme. */
void pf_input_set_busy(int busy);
int pf_input_busy(void);

/* Keys for which macOS's press-and-hold accent picker stays on (it is off for every other key,
 * so holding a key repeats it). KEYS is UTF-8, one key name per line, as PFKeyDescription
 * spells them ("e"). Replaces the previous set. */
void pf_input_set_press_and_hold(const char *keys, size_t len);
int pf_input_press_and_hold(const char *key);

#endif

#ifndef PF_INPUT_H
#define PF_INPUT_H

/* Input state the shell needs from Scheme's command loop. Main thread only. */

/* Set while a key sequence is unfinished (after C-x, ...). The shell then sends the next plain
 * key as a key named from the ASCII-capable layout, not as text through the input method, so
 * "C-x o" runs other-window (under any layout) instead of inserting "o". */
void pf_input_set_prefix_pending(int pending);
int pf_input_prefix_pending(void);

#endif

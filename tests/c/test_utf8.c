#include "pf_test.h"
#include "pf_utf8.h"

#define PREFIX(lit) pf_utf8_complete_prefix((const unsigned char *)(lit), sizeof(lit) - 1)

int main(void) {
    PF_CHECK_EQ_SIZE(pf_utf8_complete_prefix(NULL, 0), 0);
    PF_CHECK_EQ_SIZE(PREFIX("(+ 1 2)"), 7);

    /* "é" = C3 A9, "—" = E2 80 94, "😀" = F0 9F 98 80 */
    PF_CHECK_EQ_SIZE(PREFIX("a\xC3\xA9"), 3);
    PF_CHECK_EQ_SIZE(PREFIX("a\xC3"), 1);
    PF_CHECK_EQ_SIZE(PREFIX("a\xE2\x80\x94"), 4);
    PF_CHECK_EQ_SIZE(PREFIX("a\xE2\x80"), 1);
    PF_CHECK_EQ_SIZE(PREFIX("a\xE2"), 1);
    PF_CHECK_EQ_SIZE(PREFIX("\xF0\x9F\x98\x80"), 4);
    PF_CHECK_EQ_SIZE(PREFIX("\xF0\x9F\x98"), 0);
    PF_CHECK_EQ_SIZE(PREFIX("\xF0\x9F"), 0);
    PF_CHECK_EQ_SIZE(PREFIX("\xF0"), 0);

    /* Invalid bytes pass through for the decoder to replace. */
    PF_CHECK_EQ_SIZE(PREFIX("a\x80"), 2);
    PF_CHECK_EQ_SIZE(PREFIX("a\x80\x80\x80\x80"), 5);
    PF_CHECK_EQ_SIZE(PREFIX("a\xFF"), 2);

    return PF_TEST_RESULT();
}

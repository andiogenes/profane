#include "pf_display_ffi.h"

#include "pf_face.h"
#include "pf_props.h"
#include "pf_text.h"

void pf_face_define(uint32_t id, uint32_t flags, uint32_t fg, uint32_t bg, uint32_t underline,
                    uint32_t font) {
    pf_face f = {flags, fg, bg, underline, font};
    pf_face_set(id, &f);
}

void pf_face_role_set(int role, uint32_t id) {
    pf_face_set_role((pf_face_role)role, id);
}

uint32_t pf_face_default_background(void) {
    const pf_face *f = pf_face_get(pf_face_role_id(PF_ROLE_DEFAULT));
    return f->flags & PF_FACE_HAS_BG ? f->bg : 0xFFFFFFFF;
}

int pf_buf_put_prop(pf_handle buf, uint32_t prop, size_t start, size_t end, uint32_t value) {
    pf_text *t = pf_handle_get(buf, PF_HANDLE_TEXT);
    if (!t) {
        return -2;
    }
    return pf_props_put(pf_text_props(t), prop, start, end, value);
}

int64_t pf_buf_get_prop(pf_handle buf, uint32_t prop, size_t pos) {
    pf_text *t = pf_handle_get(buf, PF_HANDLE_TEXT);
    return t ? (int64_t)pf_props_get(pf_text_props(t), prop, pos) : -2;
}

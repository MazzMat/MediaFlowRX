#include "mfrx_caption.h"

// libcaption headers define unused static helpers and use old prototypes.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wstrict-prototypes"
#pragma clang diagnostic ignored "-Wdocumentation"
#include "caption.h"
#pragma clang diagnostic pop

#include <stdlib.h>
#include <string.h>

struct mfrx_captions {
    caption_frame_t frame;
};

mfrx_captions *mfrx_captions_create(void) {
    mfrx_captions *decoder = calloc(1, sizeof(mfrx_captions));
    if (decoder) {
        caption_frame_init(&decoder->frame);
    }
    return decoder;
}

void mfrx_captions_free(mfrx_captions *decoder) {
    free(decoder);
}

void mfrx_captions_reset(mfrx_captions *decoder) {
    if (decoder) {
        caption_frame_init(&decoder->frame);
    }
}

int mfrx_captions_decode(mfrx_captions *decoder, uint8_t byte1, uint8_t byte2) {
    if (!decoder) {
        return 0;
    }
    uint16_t cc_data = (uint16_t)((byte1 << 8) | byte2);
    return caption_frame_decode(&decoder->frame, cc_data, 0) == LIBCAPTION_READY;
}

int mfrx_captions_rollup(mfrx_captions *decoder) {
    return decoder ? caption_frame_rollup(&decoder->frame) : 0;
}

int mfrx_captions_cell(mfrx_captions *decoder, int row, int col, char *text, int *style, int *underline) {
    text[0] = '\0';
    if (!decoder) {
        return 0;
    }
    eia608_style_t cell_style = eia608_style_white;
    int cell_underline = 0;
    const utf8_char_t *c = caption_frame_read_char(&decoder->frame, row, col, &cell_style, &cell_underline);
    size_t length = c ? utf8_char_length(c) : 0;
    if (length == 0 || length > 4) {
        return 0;
    }
    memcpy(text, c, length);
    text[length] = '\0';
    if (style) {
        *style = (int)cell_style;
    }
    if (underline) {
        *underline = cell_underline;
    }
    return (int)length;
}

#ifndef MFRX_CAPTION_H
#define MFRX_CAPTION_H

#include <stdint.h>

#define MFRX_CAPTION_ROWS 15
#define MFRX_CAPTION_COLS 32

/// libcaption styles: 0 white, 1 green, 2 blue, 3 cyan, 4 red, 5 yellow, 6 magenta, 7 white italics.
#define MFRX_CAPTION_STYLE_ITALICS 7

/// One CEA-608 decoder for a single data channel. The caller filters the channel:
/// libcaption decodes every byte pair it receives.
typedef struct mfrx_captions mfrx_captions;

mfrx_captions *mfrx_captions_create(void);
void mfrx_captions_free(mfrx_captions *decoder);
void mfrx_captions_reset(mfrx_captions *decoder);
/// Bytes as they come in cc_data, parity bit included. Returns 1 when the displayed screen may have changed.
int mfrx_captions_decode(mfrx_captions *decoder, uint8_t byte1, uint8_t byte2);
/// Rows of the roll-up window, 0 in pop-on and paint-on.
int mfrx_captions_rollup(mfrx_captions *decoder);
/// Copies the displayed character as UTF-8 into text, which holds at least 5 bytes.
/// Returns the byte count, 0 for an empty cell.
int mfrx_captions_cell(mfrx_captions *decoder, int row, int col, char *text, int *style, int *underline);

#endif

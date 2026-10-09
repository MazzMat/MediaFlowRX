#ifndef MFRX_H
#define MFRX_H

#include <stddef.h>
#include <stdint.h>

#define MFRX_KIND_RTMP 0
#define MFRX_KIND_SRT 1
#define MFRX_KIND_RTSP 2

#define MFRX_CODEC_OTHER 0
#define MFRX_CODEC_H264 1
#define MFRX_CODEC_H265 2
#define MFRX_CODEC_AAC 3

typedef struct mfrx_config {
    int kind;
    uint16_t port;
    const char *slug;
    const char *key;
    const char *username;
    const char *password;
    int grace_ms;
    const char *record_directory;
} mfrx_config;

typedef struct mfrx_frame {
    int codec;
    int is_video;
    int is_key;
    int is_config;
    int prefix_size;
    const uint8_t *data;
    size_t size;
    uint64_t pts_ms;
    uint64_t dts_ms;
    int width;
    int height;
    int sample_rate;
    int channels;
    int fps;
    int bit_rate;
    int sample_bits;
    int gop_ms;
} mfrx_frame;

int mfrx_start(const mfrx_config *config, void *ctx);
void mfrx_stop(void);
int mfrx_set_recording(int enabled);
void mfrx_set_grace_ms(int grace_ms);
void mfrx_set_record_directory(const char *directory);
const char *mfrx_last_error(void);
/// Copies the last publisher IP into dest. Returns 0 when none is known.
int mfrx_copy_publisher(char *dest, size_t dest_len);

#endif

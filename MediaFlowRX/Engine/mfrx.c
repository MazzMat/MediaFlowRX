#include "mfrx.h"

// ZLMediaKit headers carry duplicate Doxygen comments and old prototypes.
// That code is not ours, so those warnings stay off for these includes only.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#pragma clang diagnostic ignored "-Wstrict-prototypes"
#include "mk_common.h"
#include "mk_events.h"
#include "mk_frame.h"
#include "mk_recorder.h"
#include "mk_tcp.h"
#include "mk_track.h"
#pragma clang diagnostic pop

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;

static int g_inited = 0;
static atomic_int g_running = 0;
static int g_recording = 0;
static int g_record_inflight = 0;
static int g_source_count = 0;
static int g_slice = 0;
static int64_t g_last_frame_ms = 0;

static int g_kind = MFRX_KIND_RTMP;
static char g_slug[256];
static char g_key[256];
static char g_user[256];
static char g_pass[256];
static char g_vhost[256];
static char g_app[256];
static char g_stream[256];
static char g_record_dir[1024];
static char g_base_name[512];
static char g_error[512];
static char g_peer[128];
static void *g_ctx = NULL;

extern void mfrx_swift_on_state(void *ctx, int state);
extern void mfrx_swift_on_frame(void *ctx, const mfrx_frame *frame);
extern void mfrx_swift_on_file(void *ctx, const char *path);
extern void mfrx_swift_on_error(void *ctx, const char *message);

static int64_t now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static void set_error(const char *message) {
    snprintf(g_error, sizeof(g_error), "%s", message ? message : "");
}

static void copy_text(char *dest, size_t dest_len, const char *src) {
    if (!src) {
        src = "";
    }
    snprintf(dest, dest_len, "%s", src);
}

static const char *expected_schema(void) {
    switch (g_kind) {
        case MFRX_KIND_SRT: return "srt";
        case MFRX_KIND_RTSP: return "rtsp";
        default: return "rtmp";
    }
}

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void percent_decode(const char *src, size_t len, char *dest, size_t dest_len) {
    size_t w = 0;
    for (size_t i = 0; i < len && w + 1 < dest_len; i++) {
        if (src[i] == '%' && i + 2 < len) {
            int hi = hex_nibble(src[i + 1]);
            int lo = hex_nibble(src[i + 2]);
            if (hi >= 0 && lo >= 0) {
                dest[w++] = (char)((hi << 4) | lo);
                i += 2;
                continue;
            }
        }
        if (src[i] == '+') {
            dest[w++] = ' ';
            continue;
        }
        dest[w++] = src[i];
    }
    dest[w] = '\0';
}

static int query_value(const char *params, const char *key, char *dest, size_t dest_len) {
    if (!params || !key) {
        return 0;
    }
    size_t key_len = strlen(key);
    const char *p = params;
    while (*p) {
        const char *amp = strchr(p, '&');
        size_t part_len = amp ? (size_t)(amp - p) : strlen(p);
        const char *eq = memchr(p, '=', part_len);
        size_t name_len = eq ? (size_t)(eq - p) : part_len;
        if (name_len == key_len && strncmp(p, key, key_len) == 0) {
            if (eq) {
                percent_decode(eq + 1, part_len - name_len - 1, dest, dest_len);
            } else if (dest_len) {
                dest[0] = '\0';
            }
            return 1;
        }
        if (!amp) {
            break;
        }
        p = amp + 1;
    }
    return 0;
}

static int credentials_ok(const char *params) {
    if (g_user[0] == '\0' && g_pass[0] == '\0') {
        return 1;
    }
    if (g_kind == MFRX_KIND_SRT) {
        return 1;
    }
    if (g_kind == MFRX_KIND_RTSP) {
        return 1;
    }
    char user[256];
    char pass[256];
    user[0] = '\0';
    pass[0] = '\0';
    query_value(params, "user", user, sizeof(user));
    if (user[0] == '\0') {
        query_value(params, "username", user, sizeof(user));
    }
    query_value(params, "pass", pass, sizeof(pass));
    if (pass[0] == '\0') {
        query_value(params, "password", pass, sizeof(pass));
    }
    return strcmp(user, g_user) == 0 && strcmp(pass, g_pass) == 0;
}

static int identity_ok(const char *app, const char *stream) {
    return app && stream && strcmp(app, g_slug) == 0 && strcmp(stream, g_key) == 0;
}

static void option_set(const char *key, const char *value) {
    if (mk_get_option(key)) {
        mk_set_option(key, value);
    }
}

static void apply_options_with_grace(int grace_ms) {
    char grace[32];
    if (grace_ms < 0) {
        grace_ms = 0;
    }
    snprintf(grace, sizeof(grace), "%d", grace_ms);
    option_set("protocol.continue_push_ms", grace);
    option_set("protocol.modify_stamp", "0");
    option_set("protocol.enable_audio", "1");
    option_set("protocol.add_mute_audio", "0");
    option_set("protocol.auto_close", "0");
    option_set("protocol.enable_hls", "0");
    option_set("protocol.enable_hls_fmp4", "0");
    option_set("protocol.enable_mp4", "0");
    option_set("protocol.enable_rtsp", "0");
    option_set("protocol.enable_rtmp", "0");
    option_set("protocol.enable_ts", g_kind == MFRX_KIND_SRT ? "1" : "0");
    option_set("protocol.enable_fmp4", "0");
    option_set("protocol.mp4_max_second", "86400");
    option_set("protocol.mp4_as_player", "0");
    option_set("record.fastStart", "1");
    option_set("record.enableFmp4", "0");
    option_set("general.listen_ip", "0.0.0.0");
    option_set("rtmp.directProxy", "0");
    option_set("rtsp.directProxy", "0");
}

static void remove_empty_parents(const char *file_path, const char *stop_dir) {
    char dir[1024];
    snprintf(dir, sizeof(dir), "%s", file_path ? file_path : "");
    size_t stop_len = stop_dir ? strlen(stop_dir) : 0;
    for (;;) {
        char *slash = strrchr(dir, '/');
        if (!slash || slash == dir) {
            break;
        }
        *slash = '\0';
        if (stop_len == 0 || strcmp(dir, stop_dir) == 0 || strncmp(dir, stop_dir, stop_len) != 0) {
            break;
        }
        if (rmdir(dir) != 0) {
            break;
        }
    }
}

static void ensure_dir(const char *path) {
    if (!path || path[0] == '\0') {
        return;
    }
    mkdir(path, 0755);
}

static void unique_destination(const char *directory, const char *base_name, int slice, char *dest, size_t dest_len) {
    char candidate[1024];
    if (slice <= 0) {
        snprintf(candidate, sizeof(candidate), "%s/%s", directory, base_name);
    } else {
        char stem[512];
        snprintf(stem, sizeof(stem), "%s", base_name);
        char *dot = strrchr(stem, '.');
        if (dot) {
            *dot = '\0';
        }
        snprintf(candidate, sizeof(candidate), "%s/%s-%d.mp4", directory, stem, slice + 1);
    }
    if (access(candidate, F_OK) != 0) {
        snprintf(dest, dest_len, "%s", candidate);
        return;
    }
    for (int n = 2; n < 1000; n++) {
        char stem[512];
        snprintf(stem, sizeof(stem), "%s", base_name);
        char *dot = strrchr(stem, '.');
        if (dot) {
            *dot = '\0';
        }
        snprintf(candidate, sizeof(candidate), "%s/%s-%d.mp4", directory, stem, n);
        if (access(candidate, F_OK) != 0) {
            snprintf(dest, dest_len, "%s", candidate);
            return;
        }
    }
    snprintf(dest, dest_len, "%s", candidate);
}

static void on_record(const mk_record_info info) {
    const char *src = mk_record_info_get_file_path(info);
    char dest[1024];
    char directory[1024];
    char base[512];
    int slice = 0;
    void *ctx = NULL;
    dest[0] = '\0';
    pthread_mutex_lock(&g_mu);
    snprintf(directory, sizeof(directory), "%s", g_record_dir);
    snprintf(base, sizeof(base), "%s", g_base_name);
    slice = g_slice++;
    ctx = g_ctx;
    pthread_mutex_unlock(&g_mu);
    if (src && src[0] && directory[0] && base[0]) {
        unique_destination(directory, base, slice, dest, sizeof(dest));
        if (rename(src, dest) == 0) {
            remove_empty_parents(src, directory);
        } else {
            snprintf(dest, sizeof(dest), "%s", src);
        }
    }
    pthread_mutex_lock(&g_mu);
    if (g_record_inflight) {
        g_record_inflight = 0;
        pthread_cond_signal(&g_cv);
    }
    char vhost[256];
    char app[256];
    char stream[256];
    snprintf(vhost, sizeof(vhost), "%s", g_vhost);
    snprintf(app, sizeof(app), "%s", g_app);
    snprintf(stream, sizeof(stream), "%s", g_stream);
    pthread_mutex_unlock(&g_mu);
    if (vhost[0] == '\0' || app[0] == '\0' || stream[0] == '\0' || !mk_recorder_is_recording(1, vhost, app, stream)) {
        pthread_mutex_lock(&g_mu);
        g_recording = 0;
        pthread_mutex_unlock(&g_mu);
    }
    if (ctx && dest[0]) {
        mfrx_swift_on_file(ctx, dest);
    }
}

typedef struct {
    mk_track track;
    int is_video;
    int codec;
} TrackCtx;

static void free_track(void *user_data) {
    TrackCtx *ctx = user_data;
    if (!ctx) {
        return;
    }
    if (ctx->track) {
        mk_track_unref(ctx->track);
    }
    free(ctx);
}

static void on_frame(void *user_data, mk_frame frame) {
    TrackCtx *track = user_data;
    void *ctx = NULL;
    if (!atomic_load(&g_running) || !track || !frame) {
        return;
    }
    mfrx_frame out;
    memset(&out, 0, sizeof(out));
    out.codec = track->codec;
    out.is_video = track->is_video;
    uint32_t flags = mk_frame_get_flags(frame);
    out.is_key = (flags & MK_FRAME_FLAG_IS_KEY) ? 1 : 0;
    out.is_config = (flags & MK_FRAME_FLAG_IS_CONFIG) ? 1 : 0;
    out.prefix_size = (int)mk_frame_get_data_prefix_size(frame);
    out.data = (const uint8_t *)mk_frame_get_data(frame);
    out.size = mk_frame_get_data_size(frame);
    out.pts_ms = mk_frame_get_pts(frame);
    out.dts_ms = mk_frame_get_dts(frame);
    if (track->track) {
        out.bit_rate = mk_track_bit_rate(track->track);
        if (track->is_video) {
            out.width = mk_track_video_width(track->track);
            out.height = mk_track_video_height(track->track);
            out.fps = mk_track_video_fps(track->track);
            out.gop_ms = mk_track_video_gop_interval_ms(track->track);
        } else {
            out.sample_rate = mk_track_audio_sample_rate(track->track);
            out.channels = mk_track_audio_channel(track->track);
            out.sample_bits = mk_track_audio_sample_bit(track->track);
        }
    }
    pthread_mutex_lock(&g_mu);
    g_last_frame_ms = now_ms();
    ctx = g_ctx;
    pthread_mutex_unlock(&g_mu);
    if (ctx && out.data && out.size > 0) {
        mfrx_swift_on_frame(ctx, &out);
    }
}

static int codec_of(mk_track track, int *is_video) {
    int codec_id = mk_track_codec_id(track);
    *is_video = mk_track_is_video(track);
    if (codec_id == MKCodecH264) return MFRX_CODEC_H264;
    if (codec_id == MKCodecH265) return MFRX_CODEC_H265;
    if (codec_id == MKCodecAAC) return MFRX_CODEC_AAC;
    return MFRX_CODEC_OTHER;
}

static void on_media_changed(int regist, const mk_media_source sender) {
    if (!sender) {
        return;
    }
    const char *schema = mk_media_source_get_schema(sender);
    const char *app = mk_media_source_get_app(sender);
    const char *stream = mk_media_source_get_stream(sender);
    const char *vhost = mk_media_source_get_vhost(sender);
    char wanted_schema[16];
    char wanted_slug[256];
    char wanted_key[256];
    int accept_ts = 0;
    pthread_mutex_lock(&g_mu);
    snprintf(wanted_schema, sizeof(wanted_schema), "%s", expected_schema());
    snprintf(wanted_slug, sizeof(wanted_slug), "%s", g_slug);
    snprintf(wanted_key, sizeof(wanted_key), "%s", g_key);
    accept_ts = g_kind == MFRX_KIND_SRT;
    pthread_mutex_unlock(&g_mu);
    int schema_ok = schema && strcmp(schema, wanted_schema) == 0;
    if (!schema_ok && accept_ts && schema && strcmp(schema, "ts") == 0) {
        schema_ok = 1;
    }
    if (!schema_ok || !app || !stream || strcmp(app, wanted_slug) != 0 || strcmp(stream, wanted_key) != 0) {
        return;
    }
    void *ctx = NULL;
    int state = 0;
    pthread_mutex_lock(&g_mu);
    if (regist) {
        copy_text(g_vhost, sizeof(g_vhost), vhost ? vhost : "__defaultVhost__");
        copy_text(g_app, sizeof(g_app), app);
        copy_text(g_stream, sizeof(g_stream), stream);
        g_source_count += 1;
        g_last_frame_ms = now_ms();
        state = 1;
    } else if (g_source_count > 0) {
        g_source_count -= 1;
        state = g_source_count == 0 ? 0 : 1;
    }
    ctx = g_ctx;
    pthread_mutex_unlock(&g_mu);
    if (regist) {
        int count = mk_media_source_get_track_count(sender);
        for (int i = 0; i < count; i++) {
            mk_track track = mk_media_source_get_track(sender, i);
            if (!track) {
                continue;
            }
            TrackCtx *info = calloc(1, sizeof(TrackCtx));
            if (!info) {
                mk_track_unref(track);
                continue;
            }
            info->track = track;
            info->codec = codec_of(track, &info->is_video);
            mk_track_add_delegate2(track, on_frame, info, free_track);
        }
    }
    if (ctx && atomic_load(&g_running)) {
        mfrx_swift_on_state(ctx, state);
    }
}

static void on_publish(const mk_media_info url_info, const mk_publish_auth_invoker invoker, const mk_sock_info sender) {
    // mk_sock_info_peer_ip does an unbounded strcpy, so the buffer has to fit an IPv6 address.
    char peer[128];
    peer[0] = '\0';
    if (sender) {
        mk_sock_info_peer_ip(sender, peer);
    }
    const char *app = mk_media_info_get_app(url_info);
    const char *stream = mk_media_info_get_stream(url_info);
    const char *params = mk_media_info_get_params(url_info);
    const char *schema = mk_media_info_get_schema(url_info);
    int reject = 0;
    const char *reason = "rifiutato";
    pthread_mutex_lock(&g_mu);
    if (!schema || strcmp(schema, expected_schema()) != 0 || !identity_ok(app, stream) || !credentials_ok(params)) {
        reject = 1;
        reason = "slug, key o credenziali non validi";
    } else if (g_source_count > 0 && (now_ms() - g_last_frame_ms) < 1500) {
        reject = 1;
        reason = "flusso gia in onda";
    }
    if (!reject) {
        copy_text(g_peer, sizeof(g_peer), peer);
    }
    pthread_mutex_unlock(&g_mu);
    mk_publish_auth_invoker_do(invoker, reject ? reason : NULL, 0, 0);
}

static void on_play(const mk_media_info url_info, const mk_auth_invoker invoker, const mk_sock_info sender) {
    (void)url_info;
    (void)sender;
    mk_auth_invoker_do(invoker, "solo anteprima locale");
}

static int on_not_found(const mk_media_info url_info, const mk_sock_info sender) {
    (void)url_info;
    (void)sender;
    return 1;
}

static void on_rtsp_realm(const mk_media_info url_info, const mk_rtsp_get_realm_invoker invoker, const mk_sock_info sender) {
    (void)sender;
    const char *app = mk_media_info_get_app(url_info);
    const char *stream = mk_media_info_get_stream(url_info);
    int require = 0;
    pthread_mutex_lock(&g_mu);
    require = g_kind == MFRX_KIND_RTSP && (g_user[0] != '\0' || g_pass[0] != '\0') && identity_ok(app, stream);
    pthread_mutex_unlock(&g_mu);
    mk_rtsp_get_realm_invoker_do(invoker, require ? "MediaFlowRX" : "");
}

static void on_rtsp_auth(const mk_media_info url_info,
                         const char *realm,
                         const char *user_name,
                         int must_no_encrypt,
                         const mk_rtsp_auth_invoker invoker,
                         const mk_sock_info sender) {
    (void)url_info;
    (void)realm;
    (void)must_no_encrypt;
    (void)sender;
    char password[256];
    password[0] = '\0';
    pthread_mutex_lock(&g_mu);
    if (user_name && strcmp(user_name, g_user) == 0) {
        copy_text(password, sizeof(password), g_pass);
    } else {
        copy_text(password, sizeof(password), "invalid");
    }
    pthread_mutex_unlock(&g_mu);
    mk_rtsp_auth_invoker_do(invoker, 0, password);
}

static void install_events(void) {
    mk_events events;
    memset(&events, 0, sizeof(events));
    events.on_mk_media_changed = on_media_changed;
    events.on_mk_media_publish = on_publish;
    events.on_mk_media_play = on_play;
    events.on_mk_media_not_found = on_not_found;
    events.on_mk_rtsp_get_realm = on_rtsp_realm;
    events.on_mk_rtsp_auth = on_rtsp_auth;
    events.on_mk_record_mp4 = on_record;
    mk_events_listen(&events);
}

static void wait_for_record(void) {
    if (!g_recording) {
        return;
    }
    g_recording = 0;
    pthread_mutex_lock(&g_mu);
    g_record_inflight = 1;
    char vhost[256];
    char app[256];
    char stream[256];
    snprintf(vhost, sizeof(vhost), "%s", g_vhost);
    snprintf(app, sizeof(app), "%s", g_app);
    snprintf(stream, sizeof(stream), "%s", g_stream);
    pthread_mutex_unlock(&g_mu);
    int stopped = 0;
    if (vhost[0] && app[0] && stream[0]) {
        stopped = mk_recorder_stop(1, vhost, app, stream);
    }
    if (!stopped) {
        pthread_mutex_lock(&g_mu);
        g_record_inflight = 0;
        pthread_mutex_unlock(&g_mu);
        return;
    }
    pthread_mutex_lock(&g_mu);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 8;
    while (g_record_inflight) {
        if (pthread_cond_timedwait(&g_cv, &g_mu, &ts) != 0) {
            break;
        }
    }
    g_record_inflight = 0;
    pthread_mutex_unlock(&g_mu);
}

static void stamp_name(void) {
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char when[64];
    strftime(when, sizeof(when), "%Y-%m-%d_%H-%M-%S", &tm);
    snprintf(g_base_name, sizeof(g_base_name), "%s_%s.mp4", g_slug, when);
    g_slice = 0;
}

const char *mfrx_last_error(void) {
    return g_error;
}

int mfrx_copy_publisher(char *dest, size_t dest_len) {
    if (!dest || dest_len == 0) {
        return 0;
    }
    pthread_mutex_lock(&g_mu);
    snprintf(dest, dest_len, "%s", g_peer);
    pthread_mutex_unlock(&g_mu);
    return dest[0] != '\0';
}

void mfrx_set_grace_ms(int grace_ms) {
    if (grace_ms < 0) {
        grace_ms = 0;
    }
    if (g_inited) {
        char grace[32];
        snprintf(grace, sizeof(grace), "%d", grace_ms);
        option_set("protocol.continue_push_ms", grace);
    }
}

void mfrx_set_record_directory(const char *directory) {
    pthread_mutex_lock(&g_mu);
    copy_text(g_record_dir, sizeof(g_record_dir), directory);
    pthread_mutex_unlock(&g_mu);
    ensure_dir(directory);
}

int mfrx_set_recording(int enabled) {
    if (!enabled) {
        wait_for_record();
        return 1;
    }
    pthread_mutex_lock(&g_mu);
    int have_source = g_source_count > 0;
    int already = g_recording;
    char vhost[256];
    char app[256];
    char stream[256];
    char directory[1024];
    snprintf(vhost, sizeof(vhost), "%s", g_vhost);
    snprintf(app, sizeof(app), "%s", g_app);
    snprintf(stream, sizeof(stream), "%s", g_stream);
    snprintf(directory, sizeof(directory), "%s", g_record_dir);
    if (have_source && !already) {
        stamp_name();
    }
    pthread_mutex_unlock(&g_mu);
    if (!have_source) {
        set_error("No stream to record");
        return 0;
    }
    if (already) {
        return 1;
    }
    ensure_dir(directory);
    size_t len = strlen(directory);
    if (len > 0 && directory[len - 1] != '/') {
        if (len + 1 < sizeof(directory)) {
            directory[len] = '/';
            directory[len + 1] = '\0';
        }
    }
    int started = mk_recorder_start(1, vhost, app, stream, directory, 86400);
    if (!started) {
        set_error("Recording did not start");
        return 0;
    }
    pthread_mutex_lock(&g_mu);
    g_recording = 1;
    pthread_mutex_unlock(&g_mu);
    set_error("");
    return 1;
}

void mfrx_stop(void) {
    atomic_store(&g_running, 0);
    wait_for_record();
    if (g_inited) {
        mk_stop_all_server();
    }
    pthread_mutex_lock(&g_mu);
    g_source_count = 0;
    pthread_mutex_unlock(&g_mu);
}

int mfrx_start(const mfrx_config *config, void *ctx) {
    if (!config || !config->slug || !config->key || config->slug[0] == '\0' || config->key[0] == '\0' || config->port == 0) {
        set_error("Slug, key and port are required");
        return -1;
    }
    mfrx_stop();
    pthread_mutex_lock(&g_mu);
    g_peer[0] = '\0';
    pthread_mutex_unlock(&g_mu);
    pthread_mutex_lock(&g_mu);
    g_kind = config->kind;
    copy_text(g_slug, sizeof(g_slug), config->slug);
    copy_text(g_key, sizeof(g_key), config->key);
    copy_text(g_user, sizeof(g_user), config->username);
    copy_text(g_pass, sizeof(g_pass), config->password);
    copy_text(g_record_dir, sizeof(g_record_dir), config->record_directory);
    copy_text(g_vhost, sizeof(g_vhost), "__defaultVhost__");
    copy_text(g_app, sizeof(g_app), config->slug);
    copy_text(g_stream, sizeof(g_stream), config->key);
    g_ctx = ctx;
    g_source_count = 0;
    g_last_frame_ms = 0;
    pthread_mutex_unlock(&g_mu);
    ensure_dir(config->record_directory);
    if (!g_inited) {
        mk_config cfg;
        memset(&cfg, 0, sizeof(cfg));
        cfg.thread_num = 4;
        cfg.log_level = 2;
        cfg.log_mask = LOG_CONSOLE;
        cfg.log_file_path = NULL;
        cfg.log_file_days = 0;
        cfg.ini_is_path = 0;
        cfg.ini = NULL;
        cfg.ssl = NULL;
        cfg.ssl_pwd = NULL;
        mk_env_init(&cfg);
        install_events();
        g_inited = 1;
    }
    int grace_ms = config->grace_ms > 0 ? config->grace_ms : 10000;
    apply_options_with_grace(grace_ms);
    uint16_t bound = 0;
    if (config->kind == MFRX_KIND_SRT) {
        bound = mk_srt_server_start(config->port);
    } else if (config->kind == MFRX_KIND_RTSP) {
        bound = mk_rtsp_server_start(config->port, 0);
    } else {
        bound = mk_rtmp_server_start(config->port, 0);
    }
    if (bound == 0) {
        char message[128];
        snprintf(message, sizeof(message), "Could not open port %u", config->port);
        set_error(message);
        if (ctx) {
            mfrx_swift_on_error(ctx, g_error);
        }
        return -2;
    }
    atomic_store(&g_running, 1);
    set_error("");
    if (ctx) {
        mfrx_swift_on_state(ctx, 0);
    }
    return 0;
}

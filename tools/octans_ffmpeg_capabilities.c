#define _GNU_SOURCE

/*
 * Octans FFmpeg capability helper.
 *
 * This binary is intentionally a fact collector. Playback policy remains in
 * the Octans backend.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <libavutil/buffer.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/mem.h>
#include <libavutil/pixdesc.h>
#include <va/va.h>

#define OCTANS_HELPER_SCHEMA_VERSION 1
#define OCTANS_HELPER_VERSION "1"
#define MAX_CAPTURE_BYTES (256 * 1024)

typedef struct CaptureBuffer {
    char *data;
    size_t length;
    size_t capacity;
    bool truncated;
} CaptureBuffer;

typedef struct ProbeResult {
    int exit_code;
    bool exited;
    bool signaled;
    int signal_number;
    bool ok;
    bool truncated;
    char *stdout_text;
    char *stderr_text;
    char *error_text;
} ProbeResult;

typedef struct HelperOptions {
    const char *ffmpeg;
    const char *ffprobe;
    const char *vaapi_device;
    bool run_opencl_vaapi_interop_smoke;
    bool show_help;
} HelperOptions;

typedef struct VaapiProfileProbe {
    const char *codec;
    const char *codec_profile;
    const char *va_profile_name;
    VAProfile va_profile;
    const char *entrypoint_name;
    VAEntrypoint entrypoint;
} VaapiProfileProbe;

static const char *filter_help_names[] = {
    "tonemapx",
    "tonemap_vaapi",
    "tonemap_opencl",
    "scale_vaapi",
    "overlay_vaapi",
    "pan",
    "volume",
    "aresample",
    "loudnorm",
    "dynaudnorm",
    "acompressor",
    "alimiter"
};

static const VaapiProfileProbe vaapi_decode_profiles[] = {
    { "mpeg2video", "simple", "VAProfileMPEG2Simple", VAProfileMPEG2Simple, "VLD", VAEntrypointVLD },
    { "mpeg2video", "main", "VAProfileMPEG2Main", VAProfileMPEG2Main, "VLD", VAEntrypointVLD },
    { "vc1", "simple", "VAProfileVC1Simple", VAProfileVC1Simple, "VLD", VAEntrypointVLD },
    { "vc1", "main", "VAProfileVC1Main", VAProfileVC1Main, "VLD", VAEntrypointVLD },
    { "vc1", "advanced", "VAProfileVC1Advanced", VAProfileVC1Advanced, "VLD", VAEntrypointVLD },
    { "h264", "constrained-baseline", "VAProfileH264ConstrainedBaseline", VAProfileH264ConstrainedBaseline, "VLD", VAEntrypointVLD },
    { "h264", "main", "VAProfileH264Main", VAProfileH264Main, "VLD", VAEntrypointVLD },
    { "h264", "high", "VAProfileH264High", VAProfileH264High, "VLD", VAEntrypointVLD },
    { "hevc", "main", "VAProfileHEVCMain", VAProfileHEVCMain, "VLD", VAEntrypointVLD },
    { "hevc", "main10", "VAProfileHEVCMain10", VAProfileHEVCMain10, "VLD", VAEntrypointVLD },
    { "vp9", "profile0", "VAProfileVP9Profile0", VAProfileVP9Profile0, "VLD", VAEntrypointVLD },
    { "vp9", "profile1", "VAProfileVP9Profile1", VAProfileVP9Profile1, "VLD", VAEntrypointVLD },
    { "vp9", "profile2", "VAProfileVP9Profile2", VAProfileVP9Profile2, "VLD", VAEntrypointVLD },
    { "vp9", "profile3", "VAProfileVP9Profile3", VAProfileVP9Profile3, "VLD", VAEntrypointVLD },
    /* AV1: Profile0 is the common Main profile path; Profile1/2 are probed when the driver exposes them. */
    { "av1", "profile0", "VAProfileAV1Profile0", VAProfileAV1Profile0, "VLD", VAEntrypointVLD },
    { "av1", "profile1", "VAProfileAV1Profile1", VAProfileAV1Profile1, "VLD", VAEntrypointVLD },
    { "av1", "profile2", "VAProfileAV1Profile2", VAProfileAV1Profile2, "VLD", VAEntrypointVLD },
};

static const VaapiProfileProbe vaapi_encode_profiles[] = {
    { "h264", "main", "VAProfileH264Main", VAProfileH264Main, "EncSlice", VAEntrypointEncSlice },
    { "h264", "high", "VAProfileH264High", VAProfileH264High, "EncSlice", VAEntrypointEncSlice },
    { "h264", "main", "VAProfileH264Main", VAProfileH264Main, "EncSliceLP", VAEntrypointEncSliceLP },
    { "h264", "high", "VAProfileH264High", VAProfileH264High, "EncSliceLP", VAEntrypointEncSliceLP },
    { "hevc", "main", "VAProfileHEVCMain", VAProfileHEVCMain, "EncSlice", VAEntrypointEncSlice },
    { "hevc", "main10", "VAProfileHEVCMain10", VAProfileHEVCMain10, "EncSlice", VAEntrypointEncSlice },
    { "hevc", "main", "VAProfileHEVCMain", VAProfileHEVCMain, "EncSliceLP", VAEntrypointEncSliceLP },
    { "hevc", "main10", "VAProfileHEVCMain10", VAProfileHEVCMain10, "EncSliceLP", VAEntrypointEncSliceLP },
    { "vp9", "profile0", "VAProfileVP9Profile0", VAProfileVP9Profile0, "EncSliceLP", VAEntrypointEncSliceLP },
    { "vp9", "profile1", "VAProfileVP9Profile1", VAProfileVP9Profile1, "EncSliceLP", VAEntrypointEncSliceLP },
    { "vp9", "profile2", "VAProfileVP9Profile2", VAProfileVP9Profile2, "EncSliceLP", VAEntrypointEncSliceLP },
    { "vp9", "profile3", "VAProfileVP9Profile3", VAProfileVP9Profile3, "EncSliceLP", VAEntrypointEncSliceLP },
    /* AV1 encode: include both EncSlice and EncSliceLP; unsupported entrypoints stay supported=false. */
    { "av1", "profile0", "VAProfileAV1Profile0", VAProfileAV1Profile0, "EncSlice", VAEntrypointEncSlice },
    { "av1", "profile0", "VAProfileAV1Profile0", VAProfileAV1Profile0, "EncSliceLP", VAEntrypointEncSliceLP },
    { "av1", "profile1", "VAProfileAV1Profile1", VAProfileAV1Profile1, "EncSlice", VAEntrypointEncSlice },
    { "av1", "profile1", "VAProfileAV1Profile1", VAProfileAV1Profile1, "EncSliceLP", VAEntrypointEncSliceLP },
};

static void free_probe_result(ProbeResult *result)
{
    if (!result) {
        return;
    }

    free(result->stdout_text);
    free(result->stderr_text);
    free(result->error_text);
    memset(result, 0, sizeof(*result));
}

static bool buffer_reserve(CaptureBuffer *buffer, size_t required)
{
    if (required <= buffer->capacity) {
        return true;
    }

    size_t next = buffer->capacity == 0 ? 4096 : buffer->capacity;
    while (next < required) {
        next *= 2;
    }

    char *data = realloc(buffer->data, next);
    if (!data) {
        return false;
    }

    buffer->data = data;
    buffer->capacity = next;
    return true;
}

static void buffer_append(CaptureBuffer *buffer, const char *data, size_t length)
{
    if (length == 0 || buffer->truncated) {
        return;
    }

    size_t remaining = MAX_CAPTURE_BYTES > buffer->length
        ? MAX_CAPTURE_BYTES - buffer->length
        : 0;
    if (length > remaining) {
        length = remaining;
        buffer->truncated = true;
    }

    if (length == 0) {
        return;
    }

    if (!buffer_reserve(buffer, buffer->length + length + 1)) {
        buffer->truncated = true;
        return;
    }

    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
}

static char *buffer_steal(CaptureBuffer *buffer)
{
    if (!buffer->data) {
        return strdup("");
    }

    char *data = buffer->data;
    buffer->data = NULL;
    buffer->length = 0;
    buffer->capacity = 0;
    return data;
}

static char *format_string(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    va_list copy;
    va_copy(copy, args);
    int needed = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (needed < 0) {
        va_end(args);
        return strdup("format error");
    }

    char *value = malloc((size_t)needed + 1);
    if (!value) {
        va_end(args);
        return strdup("out of memory");
    }

    vsnprintf(value, (size_t)needed + 1, format, args);
    va_end(args);
    return value;
}

static void set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
}

static void close_fd(int *fd)
{
    if (*fd >= 0) {
        close(*fd);
        *fd = -1;
    }
}

static ProbeResult probe_failed(const char *error)
{
    ProbeResult result = { 0 };
    result.exit_code = -1;
    result.stdout_text = strdup("");
    result.stderr_text = strdup("");
    result.error_text = strdup(error ? error : "probe failed");
    return result;
}

static ProbeResult run_process(const char *executable, char *const argv[], const char *stdin_text)
{
    int stdout_pipe[2] = { -1, -1 };
    int stderr_pipe[2] = { -1, -1 };
    int stdin_pipe[2] = { -1, -1 };

    if (pipe(stdout_pipe) != 0 || pipe(stderr_pipe) != 0) {
        return probe_failed(strerror(errno));
    }

    if (stdin_text && pipe(stdin_pipe) != 0) {
        close_fd(&stdout_pipe[0]);
        close_fd(&stdout_pipe[1]);
        close_fd(&stderr_pipe[0]);
        close_fd(&stderr_pipe[1]);
        return probe_failed(strerror(errno));
    }

    pid_t pid = fork();
    if (pid < 0) {
        close_fd(&stdout_pipe[0]);
        close_fd(&stdout_pipe[1]);
        close_fd(&stderr_pipe[0]);
        close_fd(&stderr_pipe[1]);
        close_fd(&stdin_pipe[0]);
        close_fd(&stdin_pipe[1]);
        return probe_failed(strerror(errno));
    }

    if (pid == 0) {
        if (stdin_text) {
            dup2(stdin_pipe[0], STDIN_FILENO);
        }
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);

        close_fd(&stdout_pipe[0]);
        close_fd(&stdout_pipe[1]);
        close_fd(&stderr_pipe[0]);
        close_fd(&stderr_pipe[1]);
        close_fd(&stdin_pipe[0]);
        close_fd(&stdin_pipe[1]);

        execv(executable, argv);
        _exit(127);
    }

    close_fd(&stdout_pipe[1]);
    close_fd(&stderr_pipe[1]);
    if (stdin_text) {
        close_fd(&stdin_pipe[0]);
        ssize_t ignored = write(stdin_pipe[1], stdin_text, strlen(stdin_text));
        (void)ignored;
        close_fd(&stdin_pipe[1]);
    }

    set_nonblocking(stdout_pipe[0]);
    set_nonblocking(stderr_pipe[0]);

    CaptureBuffer stdout_buffer = { 0 };
    CaptureBuffer stderr_buffer = { 0 };
    bool stdout_open = true;
    bool stderr_open = true;
    bool child_done = false;
    int wait_status = 0;

    while (stdout_open || stderr_open || !child_done) {
        struct pollfd fds[2];
        nfds_t nfds = 0;
        if (stdout_open) {
            fds[nfds].fd = stdout_pipe[0];
            fds[nfds].events = POLLIN | POLLHUP;
            fds[nfds].revents = 0;
            nfds++;
        }
        if (stderr_open) {
            fds[nfds].fd = stderr_pipe[0];
            fds[nfds].events = POLLIN | POLLHUP;
            fds[nfds].revents = 0;
            nfds++;
        }

        if (nfds > 0) {
            int ready = poll(fds, nfds, 100);
            if (ready > 0) {
                for (nfds_t i = 0; i < nfds; i++) {
                    char chunk[4096];
                    for (;;) {
                        ssize_t read_count = read(fds[i].fd, chunk, sizeof(chunk));
                        if (read_count > 0) {
                            if (fds[i].fd == stdout_pipe[0]) {
                                buffer_append(&stdout_buffer, chunk, (size_t)read_count);
                            } else {
                                buffer_append(&stderr_buffer, chunk, (size_t)read_count);
                            }
                            continue;
                        }

                        if (read_count == 0) {
                            if (fds[i].fd == stdout_pipe[0]) {
                                stdout_open = false;
                                close_fd(&stdout_pipe[0]);
                            } else {
                                stderr_open = false;
                                close_fd(&stderr_pipe[0]);
                            }
                        }

                        break;
                    }
                }
            }
        }

        if (!child_done) {
            pid_t wait_result = waitpid(pid, &wait_status, WNOHANG);
            if (wait_result == pid) {
                child_done = true;
            }
        }
    }

    if (!child_done) {
        waitpid(pid, &wait_status, 0);
    }

    ProbeResult result = { 0 };
    result.stdout_text = buffer_steal(&stdout_buffer);
    result.stderr_text = buffer_steal(&stderr_buffer);
    result.truncated = stdout_buffer.truncated || stderr_buffer.truncated;
    result.exited = WIFEXITED(wait_status);
    result.signaled = WIFSIGNALED(wait_status);
    result.signal_number = result.signaled ? WTERMSIG(wait_status) : 0;
    result.exit_code = result.exited ? WEXITSTATUS(wait_status) : -1;
    result.ok = result.exited && result.exit_code == 0;
    return result;
}

static void json_string(FILE *out, const char *value)
{
    fputc('"', out);
    if (value) {
        for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
            switch (*p) {
                case '"':
                    fputs("\\\"", out);
                    break;
                case '\\':
                    fputs("\\\\", out);
                    break;
                case '\b':
                    fputs("\\b", out);
                    break;
                case '\f':
                    fputs("\\f", out);
                    break;
                case '\n':
                    fputs("\\n", out);
                    break;
                case '\r':
                    fputs("\\r", out);
                    break;
                case '\t':
                    fputs("\\t", out);
                    break;
                default:
                    if (*p < 0x20) {
                        fprintf(out, "\\u%04x", *p);
                    } else {
                        fputc(*p, out);
                    }
                    break;
            }
        }
    }
    fputc('"', out);
}

static void json_nullable_string(FILE *out, const char *value)
{
    if (value) {
        json_string(out, value);
    } else {
        fputs("null", out);
    }
}

static void json_probe_result(FILE *out, const char *name, const ProbeResult *result, bool trailing_comma)
{
    json_string(out, name);
    fputs(":{", out);
    fprintf(out, "\"ok\":%s,", result->ok ? "true" : "false");
    if (result->exited) {
        fprintf(out, "\"exitCode\":%d,", result->exit_code);
    } else {
        fputs("\"exitCode\":null,", out);
    }
    fprintf(out, "\"signaled\":%s,", result->signaled ? "true" : "false");
    if (result->signaled) {
        fprintf(out, "\"signal\":%d,", result->signal_number);
    } else {
        fputs("\"signal\":null,", out);
    }
    fprintf(out, "\"truncated\":%s,", result->truncated ? "true" : "false");
    fputs("\"stdout\":", out);
    json_string(out, result->stdout_text ? result->stdout_text : "");
    fputs(",\"stderr\":", out);
    json_string(out, result->stderr_text ? result->stderr_text : "");
    fputs(",\"error\":", out);
    json_nullable_string(out, result->error_text);
    fputc('}', out);
    if (trailing_comma) {
        fputc(',', out);
    }
}

static void json_string_array_from_pix_fmts(FILE *out, enum AVPixelFormat *formats)
{
    fputc('[', out);
    bool first = true;
    if (formats) {
        for (int i = 0; formats[i] != AV_PIX_FMT_NONE; i++) {
            const char *name = av_get_pix_fmt_name(formats[i]);
            if (!name) {
                continue;
            }
            if (!first) {
                fputc(',', out);
            }
            json_string(out, name);
            first = false;
        }
    }
    fputc(']', out);
}

static void json_constraint_number(FILE *out, int value, bool is_max)
{
    if (value <= 0 || (is_max && value == INT_MAX)) {
        fputs("null", out);
    } else {
        fprintf(out, "%d", value);
    }
}

static void json_vaapi_profile(
    FILE *out,
    AVBufferRef *device_ref,
    VADisplay display,
    const VaapiProfileProbe *probe,
    bool trailing_comma)
{
    VAConfigID config_id = VA_INVALID_ID;
    VAStatus status = vaCreateConfig(
        display,
        probe->va_profile,
        probe->entrypoint,
        NULL,
        0,
        &config_id);

    fputc('{', out);
    fputs("\"codec\":", out);
    json_string(out, probe->codec);
    fputs(",\"codecProfile\":", out);
    json_string(out, probe->codec_profile);
    fputs(",\"vaProfile\":", out);
    json_string(out, probe->va_profile_name);
    fputs(",\"entrypoint\":", out);
    json_string(out, probe->entrypoint_name);
    fputs(",\"source\":\"av_hwdevice_get_hwframe_constraints\"", out);

    if (status != VA_STATUS_SUCCESS) {
        fputs(",\"supported\":false,\"surface\":{\"known\":false,\"reason\":", out);
        char *reason = format_string("vaCreateConfig failed: %s", vaErrorStr(status));
        json_string(out, reason);
        free(reason);
        fputs("}}", out);
        if (trailing_comma) {
            fputc(',', out);
        }
        return;
    }

    AVVAAPIHWConfig *hwconfig = av_hwdevice_hwconfig_alloc(device_ref);
    if (!hwconfig) {
        vaDestroyConfig(display, config_id);
        fputs(",\"supported\":true,\"surface\":{\"known\":false,\"reason\":\"av_hwdevice_hwconfig_alloc failed\"}}", out);
        if (trailing_comma) {
            fputc(',', out);
        }
        return;
    }

    hwconfig->config_id = config_id;
    AVHWFramesConstraints *constraints = av_hwdevice_get_hwframe_constraints(device_ref, hwconfig);
    if (!constraints) {
        av_free(hwconfig);
        vaDestroyConfig(display, config_id);
        fputs(",\"supported\":true,\"surface\":{\"known\":false,\"reason\":\"driver did not return hwframe constraints for this profile\"}}", out);
        if (trailing_comma) {
            fputc(',', out);
        }
        return;
    }

    fputs(",\"supported\":true,\"surface\":{\"known\":true", out);
    fputs(",\"minWidth\":", out);
    json_constraint_number(out, constraints->min_width, false);
    fputs(",\"minHeight\":", out);
    json_constraint_number(out, constraints->min_height, false);
    fputs(",\"maxWidth\":", out);
    json_constraint_number(out, constraints->max_width, true);
    fputs(",\"maxHeight\":", out);
    json_constraint_number(out, constraints->max_height, true);
    fputs(",\"hwFormats\":", out);
    json_string_array_from_pix_fmts(out, constraints->valid_hw_formats);
    fputs(",\"swFormats\":", out);
    json_string_array_from_pix_fmts(out, constraints->valid_sw_formats);
    fputs("}}", out);

    av_hwframe_constraints_free(&constraints);
    av_free(hwconfig);
    vaDestroyConfig(display, config_id);

    if (trailing_comma) {
        fputc(',', out);
    }
}

static void json_vaapi_profiles(
    FILE *out,
    const char *name,
    AVBufferRef *device_ref,
    VADisplay display,
    const VaapiProfileProbe *probes,
    size_t probe_count,
    bool trailing_comma)
{
    json_string(out, name);
    fputs(":[", out);
    for (size_t i = 0; i < probe_count; i++) {
        json_vaapi_profile(out, device_ref, display, &probes[i], i + 1 < probe_count);
    }
    fputc(']', out);
    if (trailing_comma) {
        fputc(',', out);
    }
}

static void json_vaapi_device(FILE *out, const char *device)
{
    fputs("\"vaapi\":{", out);
    fputs("\"device\":", out);
    json_nullable_string(out, device && device[0] ? device : NULL);

    if (!device || !device[0]) {
        fputs(",\"available\":false,\"reason\":\"vaapi render device not configured\",\"driver\":null,\"apiVersion\":null,\"decodeProfiles\":[],\"encodeProfiles\":[]}", out);
        return;
    }

    AVBufferRef *device_ref = NULL;
    int create_result = av_hwdevice_ctx_create(&device_ref, AV_HWDEVICE_TYPE_VAAPI, device, NULL, 0);
    if (create_result < 0 || !device_ref) {
        fputs(",\"available\":false,\"reason\":", out);
        char *reason = format_string("av_hwdevice_ctx_create failed: %d", create_result);
        json_string(out, reason);
        free(reason);
        fputs(",\"driver\":null,\"apiVersion\":null,\"decodeProfiles\":[],\"encodeProfiles\":[]}", out);
        return;
    }

    AVHWDeviceContext *device_ctx = (AVHWDeviceContext *)device_ref->data;
    AVVAAPIDeviceContext *vaapi_ctx = (AVVAAPIDeviceContext *)device_ctx->hwctx;
    VADisplay display = vaapi_ctx->display;
    const char *vendor = vaQueryVendorString(display);

    fputs(",\"available\":true,\"reason\":null,\"driver\":", out);
    json_nullable_string(out, vendor);
    fputs(",\"apiVersion\":null", out);
    fputc(',', out);
    json_vaapi_profiles(
        out,
        "decodeProfiles",
        device_ref,
        display,
        vaapi_decode_profiles,
        sizeof(vaapi_decode_profiles) / sizeof(vaapi_decode_profiles[0]),
        true);
    json_vaapi_profiles(
        out,
        "encodeProfiles",
        device_ref,
        display,
        vaapi_encode_profiles,
        sizeof(vaapi_encode_profiles) / sizeof(vaapi_encode_profiles[0]),
        false);
    fputc('}', out);

    av_buffer_unref(&device_ref);
}

static ProbeResult run_simple_probe(const char *executable, const char *const *args, size_t arg_count, const char *stdin_text)
{
    char **argv = calloc(arg_count + 2, sizeof(char *));
    if (!argv) {
        return probe_failed("out of memory");
    }

    argv[0] = (char *)executable;
    for (size_t i = 0; i < arg_count; i++) {
        argv[i + 1] = (char *)args[i];
    }
    argv[arg_count + 1] = NULL;

    ProbeResult result = run_process(executable, argv, stdin_text);
    free(argv);
    return result;
}

static ProbeResult run_opencl_vaapi_interop_smoke(const char *ffmpeg, const char *device)
{
    if (!device || !device[0]) {
        return probe_failed("vaapi render device not configured");
    }

    char vaapi_device_arg[PATH_MAX + 16];
    snprintf(vaapi_device_arg, sizeof(vaapi_device_arg), "vaapi=va:%s", device);

    const char *args[] = {
        "-hide_banner", "-y",
        "-init_hw_device", vaapi_device_arg,
        "-init_hw_device", "opencl=ocl@va",
        "-filter_hw_device", "ocl",
        "-f", "lavfi",
        "-i", "testsrc2=duration=0.2:size=16x16:rate=1",
        "-vf",
        "format=p010,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv,hwupload=derive_device=vaapi,hwmap=derive_device=opencl,tonemap_opencl=tonemap=bt2390:tonemap_mode=auto:tradeoff=auto:peak=0:desat=0:threshold=0.2:t=bt709:m=bt709:p=bt709:format=nv12:apply_dovi=false,hwmap=derive_device=vaapi:reverse=1,scale_vaapi=format=nv12,setsar=1",
        "-frames:v", "1",
        "-f", "null",
        "-"
    };

    return run_simple_probe(ffmpeg, args, sizeof(args) / sizeof(args[0]), NULL);
}

static void usage(FILE *out)
{
    fputs(
        "Usage: octans-ffmpeg-capabilities --format json [options]\n"
        "\n"
        "Options:\n"
        "  --ffmpeg PATH        FFmpeg executable. Defaults to /opt/octans-ffmpeg/bin/ffmpeg.\n"
        "  --ffprobe PATH       FFprobe executable. Defaults to /opt/octans-ffmpeg/bin/ffprobe.\n"
        "  --vaapi-device PATH  VAAPI render device to probe.\n"
        "  --opencl-vaapi-interop-smoke\n"
        "                       Run the lightweight VAAPI/OpenCL frame mapping smoke.\n"
        "  --format json        Output JSON. Required for forward compatibility.\n"
        "  -h, --help           Show this help.\n",
        out);
}

static bool parse_args(int argc, char **argv, HelperOptions *options)
{
    options->ffmpeg = "/opt/octans-ffmpeg/bin/ffmpeg";
    options->ffprobe = "/opt/octans-ffmpeg/bin/ffprobe";
    options->vaapi_device = NULL;
    options->run_opencl_vaapi_interop_smoke = false;
    options->show_help = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            options->show_help = true;
            return true;
        }

        if (strcmp(argv[i], "--format") == 0) {
            if (i + 1 >= argc || strcmp(argv[i + 1], "json") != 0) {
                fprintf(stderr, "--format only supports json\n");
                return false;
            }
            i++;
            continue;
        }

        if (strcmp(argv[i], "--ffmpeg") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--ffmpeg requires a path\n");
                return false;
            }
            options->ffmpeg = argv[++i];
            continue;
        }

        if (strcmp(argv[i], "--ffprobe") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--ffprobe requires a path\n");
                return false;
            }
            options->ffprobe = argv[++i];
            continue;
        }

        if (strcmp(argv[i], "--vaapi-device") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--vaapi-device requires a path\n");
                return false;
            }
            options->vaapi_device = argv[++i];
            continue;
        }

        if (strcmp(argv[i], "--opencl-vaapi-interop-smoke") == 0) {
            options->run_opencl_vaapi_interop_smoke = true;
            continue;
        }

        fprintf(stderr, "unknown option: %s\n", argv[i]);
        return false;
    }

    return true;
}

static void json_opencl_device(FILE *out, const ProbeResult *interop_smoke, bool smoke_requested)
{
    fputs("\"opencl\":{", out);
    if (!smoke_requested) {
        fputs("\"available\":false,\"reason\":\"opencl provider inventory deferred; interop smoke not requested\",", out);
    } else if (interop_smoke && interop_smoke->ok) {
        fputs("\"available\":true,\"reason\":null,", out);
    } else {
        fputs("\"available\":false,\"reason\":", out);
        const char *reason = NULL;
        if (interop_smoke) {
            reason = interop_smoke->error_text && interop_smoke->error_text[0]
                ? interop_smoke->error_text
                : interop_smoke->stderr_text;
        }
        json_string(out, reason && reason[0] ? reason : "opencl vaapi interop smoke failed");
        fputc(',', out);
    }

    fputs("\"interop\":{\"vaapi\":{\"frameMapping\":", out);
    if (!smoke_requested || !interop_smoke) {
        fputs("{\"available\":false,\"probeError\":\"not requested\"}", out);
    } else {
        fputs("{\"available\":", out);
        fputs(interop_smoke->ok ? "true" : "false", out);
        fputs(",\"probeError\":", out);
        if (interop_smoke->ok) {
            fputs("null", out);
        } else if (interop_smoke->error_text && interop_smoke->error_text[0]) {
            json_string(out, interop_smoke->error_text);
        } else if (interop_smoke->stderr_text && interop_smoke->stderr_text[0]) {
            json_string(out, interop_smoke->stderr_text);
        } else {
            json_string(out, "opencl vaapi interop smoke failed");
        }
        fputc('}', out);
    }
    fputs("}}}", out);
}

int main(int argc, char **argv)
{
    HelperOptions options;
    if (!parse_args(argc, argv, &options)) {
        usage(stderr);
        return 2;
    }

    if (options.show_help) {
        usage(stdout);
        return 0;
    }

    const char *version_args[] = { "-hide_banner", "-version" };
    ProbeResult ffmpeg_version = run_simple_probe(options.ffmpeg, version_args, sizeof(version_args) / sizeof(version_args[0]), NULL);
    ProbeResult ffprobe_version = run_simple_probe(options.ffprobe, version_args, sizeof(version_args) / sizeof(version_args[0]), NULL);

    bool core_available = ffmpeg_version.ok && ffprobe_version.ok;

    ProbeResult buildconf = { 0 };
    ProbeResult filters = { 0 };
    ProbeResult encoders = { 0 };
    ProbeResult decoders = { 0 };
    ProbeResult muxers = { 0 };
    ProbeResult hwaccels = { 0 };
    ProbeResult h264_vaapi_encoder_help = { 0 };
    ProbeResult hevc_metadata_bsf_help = { 0 };
    ProbeResult segment_muxer_help = { 0 };
    ProbeResult segment_negative_time_delta_smoke = { 0 };
    ProbeResult webvtt_reference_stream_smoke = { 0 };
    ProbeResult runtime_control_help = { 0 };
    ProbeResult opencl_vaapi_interop_smoke = { 0 };
    ProbeResult filter_help[sizeof(filter_help_names) / sizeof(filter_help_names[0])] = { 0 };

    if (core_available) {
        const char *buildconf_args[] = { "-hide_banner", "-buildconf" };
        const char *filters_args[] = { "-hide_banner", "-filters" };
        const char *encoders_args[] = { "-hide_banner", "-encoders" };
        const char *decoders_args[] = { "-hide_banner", "-decoders" };
        const char *muxers_args[] = { "-hide_banner", "-muxers" };
        const char *hwaccels_args[] = { "-hide_banner", "-hwaccels" };
        const char *h264_vaapi_encoder_args[] = { "-hide_banner", "-h", "encoder=h264_vaapi" };
        const char *hevc_metadata_bsf_args[] = { "-hide_banner", "-h", "bsf=hevc_metadata" };
        const char *segment_muxer_args[] = { "-hide_banner", "-h", "muxer=segment" };
        const char *runtime_control_args[] = {
            "-hide_banner",
            "-f", "lavfi",
            "-i", "nullsrc=s=1x1:d=10000",
            "-f", "null",
            "-"
        };

        buildconf = run_simple_probe(options.ffmpeg, buildconf_args, sizeof(buildconf_args) / sizeof(buildconf_args[0]), NULL);
        filters = run_simple_probe(options.ffmpeg, filters_args, sizeof(filters_args) / sizeof(filters_args[0]), NULL);
        encoders = run_simple_probe(options.ffmpeg, encoders_args, sizeof(encoders_args) / sizeof(encoders_args[0]), NULL);
        decoders = run_simple_probe(options.ffmpeg, decoders_args, sizeof(decoders_args) / sizeof(decoders_args[0]), NULL);
        muxers = run_simple_probe(options.ffmpeg, muxers_args, sizeof(muxers_args) / sizeof(muxers_args[0]), NULL);
        hwaccels = run_simple_probe(options.ffmpeg, hwaccels_args, sizeof(hwaccels_args) / sizeof(hwaccels_args[0]), NULL);
        h264_vaapi_encoder_help = run_simple_probe(options.ffmpeg, h264_vaapi_encoder_args, sizeof(h264_vaapi_encoder_args) / sizeof(h264_vaapi_encoder_args[0]), NULL);
        hevc_metadata_bsf_help = run_simple_probe(options.ffmpeg, hevc_metadata_bsf_args, sizeof(hevc_metadata_bsf_args) / sizeof(hevc_metadata_bsf_args[0]), NULL);
        segment_muxer_help = run_simple_probe(options.ffmpeg, segment_muxer_args, sizeof(segment_muxer_args) / sizeof(segment_muxer_args[0]), NULL);
        segment_negative_time_delta_smoke = probe_failed("not probed on slim runtime");
        webvtt_reference_stream_smoke = probe_failed("not probed on slim runtime");
        runtime_control_help = run_simple_probe(options.ffmpeg, runtime_control_args, sizeof(runtime_control_args) / sizeof(runtime_control_args[0]), "?q");

        for (size_t i = 0; i < sizeof(filter_help_names) / sizeof(filter_help_names[0]); i++) {
            const char *filter_args[] = { "-hide_banner", "-h", NULL };
            char filter_arg[128];
            snprintf(filter_arg, sizeof(filter_arg), "filter=%s", filter_help_names[i]);
            filter_args[2] = filter_arg;
            filter_help[i] = run_simple_probe(options.ffmpeg, filter_args, sizeof(filter_args) / sizeof(filter_args[0]), NULL);
        }

        if (options.run_opencl_vaapi_interop_smoke) {
            opencl_vaapi_interop_smoke = run_opencl_vaapi_interop_smoke(options.ffmpeg, options.vaapi_device);
        }
    }

    fputs("{", stdout);
    fprintf(stdout, "\"schemaVersion\":%d,", OCTANS_HELPER_SCHEMA_VERSION);
    fputs("\"identity\":{", stdout);
    fputs("\"tool\":\"octans-ffmpeg-capabilities\",", stdout);
    fputs("\"version\":\"" OCTANS_HELPER_VERSION "\",", stdout);
    fputs("\"ffmpegExecutable\":", stdout);
    json_string(stdout, options.ffmpeg);
    fputs(",\"ffprobeExecutable\":", stdout);
    json_string(stdout, options.ffprobe);
    fputs("},", stdout);
    fputs("\"fatalError\":", stdout);
    if (core_available) {
        fputs("null", stdout);
    } else if (!ffmpeg_version.ok) {
        json_string(stdout, "ffmpeg -version failed");
    } else {
        json_string(stdout, "ffprobe -version failed");
    }
    fputs(",\"raw\":{\"probes\":{", stdout);
    json_probe_result(stdout, "ffmpegVersion", &ffmpeg_version, true);
    json_probe_result(stdout, "ffprobeVersion", &ffprobe_version, core_available);

    if (core_available) {
        json_probe_result(stdout, "buildconf", &buildconf, true);
        json_probe_result(stdout, "filters", &filters, true);
        json_probe_result(stdout, "encoders", &encoders, true);
        json_probe_result(stdout, "decoders", &decoders, true);
        json_probe_result(stdout, "muxers", &muxers, true);
        json_probe_result(stdout, "hwaccels", &hwaccels, true);
        json_probe_result(stdout, "h264VaapiEncoderHelp", &h264_vaapi_encoder_help, true);
        json_probe_result(stdout, "hevcMetadataBitstreamFilterHelp", &hevc_metadata_bsf_help, true);
        json_probe_result(stdout, "segmentMuxerHelp", &segment_muxer_help, true);
        json_probe_result(stdout, "segmentNegativeTimeDeltaSmoke", &segment_negative_time_delta_smoke, true);
        json_probe_result(stdout, "webVttReferenceStreamSmoke", &webvtt_reference_stream_smoke, true);
        json_probe_result(stdout, "runtimeControlHelp", &runtime_control_help, true);
        fputs("\"filterHelp\":{", stdout);
        for (size_t i = 0; i < sizeof(filter_help_names) / sizeof(filter_help_names[0]); i++) {
            json_probe_result(stdout, filter_help_names[i], &filter_help[i], i + 1 < sizeof(filter_help_names) / sizeof(filter_help_names[0]));
        }
        fputs("},", stdout);
        json_probe_result(stdout, "openClVaapiInteropToneMapSmoke", &opencl_vaapi_interop_smoke, false);
    }

    fputs("},\"hardwareDevices\":{", stdout);
    json_vaapi_device(stdout, options.vaapi_device);
    fputc(',', stdout);
    json_opencl_device(
        stdout,
        options.run_opencl_vaapi_interop_smoke ? &opencl_vaapi_interop_smoke : NULL,
        options.run_opencl_vaapi_interop_smoke);
    fputs("}}}", stdout);
    fputc('\n', stdout);

    free_probe_result(&ffmpeg_version);
    free_probe_result(&ffprobe_version);
    free_probe_result(&buildconf);
    free_probe_result(&filters);
    free_probe_result(&encoders);
    free_probe_result(&decoders);
    free_probe_result(&muxers);
    free_probe_result(&hwaccels);
    free_probe_result(&h264_vaapi_encoder_help);
    free_probe_result(&hevc_metadata_bsf_help);
    free_probe_result(&segment_muxer_help);
    free_probe_result(&segment_negative_time_delta_smoke);
    free_probe_result(&webvtt_reference_stream_smoke);
    free_probe_result(&runtime_control_help);
    free_probe_result(&opencl_vaapi_interop_smoke);
    for (size_t i = 0; i < sizeof(filter_help_names) / sizeof(filter_help_names[0]); i++) {
        free_probe_result(&filter_help[i]);
    }

    return core_available ? 0 : 1;
}

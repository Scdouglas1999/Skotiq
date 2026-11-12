/*
 * A fake ToupTek camera SDK (libtoupcam.so, Toupcam_ prefix) written from toupcam.h
 * 60.33015.20261024 (indi-3rdparty libtoupcam), the SDK manual en.html 59.28926 and the
 * INDI toupbase and NINA ToupTekAlike drivers, separately from Skotiq's driver and from
 * TOUPTEK_FAKE_SDK, so that a misreading of the documents in one is caught by the other.
 * th:<line> cites toupcam.h.
 *
 * Control entry points (FakeToup_*) let a test describe the connected cameras and the
 * state each camera kept from an earlier session (the SDK dumps its configuration when
 * a camera stops, th:1122 OPTION_DUMP_CFG default 1), and read a log of every call.
 */
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int32_t HRESULT;
#define S_OK 0
#define S_FALSE 1
#define E_UNEXPECTED ((HRESULT)0x8000ffff)
#define E_NOTIMPL ((HRESULT)0x80004001)
#define E_INVALIDARG ((HRESULT)0x80070057)
#define E_POINTER ((HRESULT)0x80004003)
#define E_WRONG_THREAD ((HRESULT)0x8001010e)
#define E_PENDING ((HRESULT)0x8000000a)

/* th:134-196 */
#define F_ROI_HARDWARE 0x8ULL
#define F_MONO 0x10ULL
#define F_TEC 0x80ULL
#define F_GETTEMPERATURE 0x400ULL
#define F_TEC_ONOFF 0x20000ULL
#define F_TRIGGER_SOFTWARE 0x80000ULL
#define F_BLACKLEVEL 0x400000ULL
#define F_CG 0x4000000ULL
#define F_CGHDR 0x800000000ULL

/* th:973-1282 */
#define O_NOFRAME_TIMEOUT 0x01
#define O_RAW 0x04
#define O_BITDEPTH 0x06
#define O_FAN 0x07
#define O_TEC 0x08
#define O_TRIGGER 0x0b
#define O_TECTARGET 0x0f
#define O_BLACKLEVEL 0x15
#define O_BINNING 0x17
#define O_ROTATE 0x18
#define O_CG 0x19
#define O_PIXEL_FORMAT 0x1a
#define O_TEC_VOLTAGE 0x20
#define O_TEC_VOLTAGE_MAX 0x21
#define O_UPSIDE_DOWN 0x23
#define O_BANDWIDTH 0x2e
#define O_FLUSH 0x3d
#define O_TECTARGET_RANGE 0x6d
#define O_TRIGGER_CANCEL_MODE 0x75
#define O_ZERO_PADDING 0x78

#define EV_IMAGE 0x0004
#define EV_TRIGGERFAIL 0x0007
#define EV_ERROR 0x0080
#define EV_DISCONNECTED 0x0081

typedef struct { unsigned width, height; } Res;
typedef struct {
    const char *name;
    unsigned long long flag;
    unsigned maxspeed, preview, still, maxfanspeed, ioctrol;
    float xpixsz, ypixsz;
    Res res[16];
} ModelV2; /* th:307-322, non-Windows layout */
typedef struct {
    char displayname[64];
    char id[64];
    const ModelV2 *model;
} DeviceV2; /* th:324-333 */
typedef struct {
    unsigned width, height, flag, seq;
    unsigned long long timestamp;
    unsigned shutterseq, expotime;
    unsigned short expogain, blacklevel;
} FrameInfoV3; /* th:449-458 */
typedef void (*EventCb)(unsigned, void *);

/* What a camera keeps between sessions. */
typedef struct {
    int raw, bitdepth, trigger, upside_down, zero_padding, cg, blacklevel, binning;
    int tec, tectarget, cancel_mode, speed, autoexpo;
    unsigned roi_x, roi_y, roi_w, roi_h; /* 0 size = full sensor */
    unsigned short gain;
    unsigned expotime;
} Persist;

typedef struct {
    ModelV2 model;
    char name[64], id[64];
    int maxbits;          /* get_MaxBitDepth */
    unsigned fourcc;
    int upside_locked;    /* an SDK that does not know OPTION_UPSIDE_DOWN */
    short temperature;
    unsigned expo_min, expo_max;
    unsigned short gain_min, gain_max, gain_def;
    int tec_range, tec_vmax, tec_v;
    int frame_info_flags; /* which FrameInfoV3 fields the model fills */
    int auto_frames;      /* deliver a frame after each Trigger(1) */
    int deliver_ms;       /* delay before the frame arrives */
    int cancel_ms;        /* delay before a cancelled frame arrives (cancel mode 1) */
    Persist p;
} Camera;

#define MAXCAM 8
static Camera cams[MAXCAM];
static int ncams;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

/* The open camera (one at a time is enough for these checks). */
static Camera *open_cam;
static int running;
static EventCb cb;
static void *cb_ctx;
static pthread_t cb_thread;
static int cb_thread_valid;
static int pending_triggers;
static int queued;                /* frames waiting in the SDK */
static FrameInfoV3 queued_info[16];
static Persist queued_state[16];
static unsigned seq;
static int generation;            /* bumped by Trigger(0), Stop, Close */

static char logbuf[1 << 20];
static size_t loglen;

static void logf_(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    if (loglen < sizeof(logbuf) - 256) {
        int n = vsnprintf(logbuf + loglen, sizeof(logbuf) - loglen, fmt, ap);
        if (n > 0) loglen += (size_t)n;
        logbuf[loglen++] = '\n';
        logbuf[loglen] = 0;
    }
    va_end(ap);
}

static int in_callback(void) {
    return cb_thread_valid && pthread_equal(pthread_self(), cb_thread);
}

static unsigned fourcc(const char *s) {
    return (unsigned)(unsigned char)s[0] | ((unsigned)(unsigned char)s[1] << 8) |
           ((unsigned)(unsigned char)s[2] << 16) | ((unsigned)(unsigned char)s[3] << 24);
}

/* ---------------- control API ---------------- */

void FakeToup_reset(void) {
    pthread_mutex_lock(&mu);
    memset(cams, 0, sizeof(cams));
    ncams = 0;
    open_cam = NULL;
    running = 0;
    queued = 0;
    pending_triggers = 0;
    loglen = 0;
    logbuf[0] = 0;
    generation++;
    pthread_mutex_unlock(&mu);
}

/* Adds a camera with the SDK's defaults (th notes per field) and returns its index. */
int FakeToup_add(const char *name, const char *id, unsigned long long flags, unsigned w,
                 unsigned h, int maxbits) {
    pthread_mutex_lock(&mu);
    Camera *c = &cams[ncams];
    memset(c, 0, sizeof(*c));
    snprintf(c->name, sizeof(c->name), "%s", name);
    snprintf(c->id, sizeof(c->id), "%s", id);
    c->model.name = c->name;
    c->model.flag = flags;
    c->model.maxspeed = 2;
    c->model.preview = 1;
    c->model.xpixsz = c->model.ypixsz = 3.76f;
    c->model.res[0].width = w;
    c->model.res[0].height = h;
    c->maxbits = maxbits;
    c->fourcc = (flags & F_MONO) ? fourcc("YYYY") : fourcc("RGGB");
    c->temperature = 215;
    c->expo_min = 10;
    c->expo_max = 3600u * 1000000u;
    c->gain_min = 100;
    c->gain_max = 5000;
    c->gain_def = 100;
    c->tec_range = (unsigned short)(short)-500 | (400 << 16);
    c->tec_vmax = 120;
    c->tec_v = 60;
    c->frame_info_flags = 0x04 | 0x08 | 0x10;
    c->auto_frames = 1;
    c->deliver_ms = 0;
    c->p.raw = 0;          /* th:979 default 0 */
    c->p.bitdepth = 0;     /* 8 bits */
    c->p.trigger = 0;      /* th:991 default video */
    c->p.upside_down = 0;  /* th:1070 default 0 on Linux; tests set 1 for Windows */
    c->p.zero_padding = 0; /* th:1282 default high */
    c->p.cg = 0;
    c->p.blacklevel = 0;
    c->p.binning = 1;
    c->p.tec = 1;
    c->p.tectarget = -100;
    c->p.cancel_mode = 0;  /* th:1279 default no frame */
    c->p.gain = 100;
    c->p.expotime = 100000;
    int idx = ncams++;
    pthread_mutex_unlock(&mu);
    return idx;
}

/* key=value tweaks of a camera's model or kept state. Returns 0 on an unknown key. */
int FakeToup_set(int idx, const char *key, long long v) {
    Camera *c = &cams[idx];
#define K(n, field) if (!strcmp(key, n)) { field = v; return 1; }
    K("upside_down", c->p.upside_down) if (!strcmp(key, "upside_locked")) { c->upside_locked = v; if (v) c->p.upside_down = 0; return 1; }
    K("cg", c->p.cg) K("blacklevel", c->p.blacklevel) K("binning", c->p.binning)
    K("bitdepth", c->p.bitdepth) K("raw", c->p.raw) K("zero_padding", c->p.zero_padding)
    K("tec", c->p.tec) K("tectarget", c->p.tectarget) K("cancel_mode", c->p.cancel_mode)
    K("roi_x", c->p.roi_x) K("roi_y", c->p.roi_y) K("roi_w", c->p.roi_w) K("roi_h", c->p.roi_h)
    K("auto_frames", c->auto_frames) K("cancel_ms", c->cancel_ms) K("deliver_ms", c->deliver_ms)
    K("frame_info_flags", c->frame_info_flags) K("expo_max", c->expo_max)
    K("temperature", c->temperature) K("maxfanspeed", c->model.maxfanspeed)
#undef K
    return 0;
}

const char *FakeToup_log(void) { return logbuf; }
void FakeToup_clear_log(void) { pthread_mutex_lock(&mu); loglen = 0; logbuf[0] = 0; pthread_mutex_unlock(&mu); }
int FakeToup_get(int idx, const char *key) {
    Camera *c = &cams[idx];
    if (!strcmp(key, "blacklevel")) return c->p.blacklevel;
    if (!strcmp(key, "cg")) return c->p.cg;
    if (!strcmp(key, "binning")) return c->p.binning;
    if (!strcmp(key, "upside_down")) return c->p.upside_down;
    if (!strcmp(key, "queued")) return queued;
    return -999999;
}

/* ---------------- frame production ---------------- */

static unsigned sensor_pixel(unsigned r, unsigned c, int bits) {
    unsigned v = ((r & 0x3f) << 5) | (c & 0x1f);
    return v & ((1u << bits) - 1);
}

static void final_size(const Camera *c, const Persist *p, unsigned *w, unsigned *h) {
    unsigned rw = p->roi_w ? p->roi_w : c->model.res[0].width;
    unsigned rh = p->roi_h ? p->roi_h : c->model.res[0].height;
    int n = p->binning & 0x0f;
    if (n < 1) n = 1;
    /* th:1016-1022: final size rounded down to an even number */
    *w = (rw / n) & ~1u;
    *h = (rh / n) & ~1u;
}

static void emit(unsigned ev) {
    if (cb) {
        cb_thread = pthread_self();
        cb_thread_valid = 1;
        cb(ev, cb_ctx);
        cb_thread_valid = 0;
    }
}

typedef struct { int gen; int ms; Persist at; } Job;
static Persist last_trigger; /* the settings the frame being exposed was triggered with */

static void *deliver(void *arg) {
    Job job = *(Job *)arg;
    free(arg);
    if (job.ms > 0) usleep((useconds_t)job.ms * 1000);
    pthread_mutex_lock(&mu);
    if (job.gen != generation || !running || !open_cam || pending_triggers <= 0) {
        pthread_mutex_unlock(&mu);
        return NULL;
    }
    pending_triggers--;
    if (queued < 16) {
        FrameInfoV3 info;
        memset(&info, 0, sizeof(info));
        final_size(open_cam, &job.at, &info.width, &info.height);
        info.flag = (unsigned)open_cam->frame_info_flags | 0x01;
        info.seq = ++seq;
        info.expotime = job.at.expotime;
        info.expogain = job.at.gain;
        info.blacklevel = (unsigned short)job.at.blacklevel;
        queued_info[queued] = info;
        queued_state[queued] = job.at;
        queued++;
    }
    pthread_mutex_unlock(&mu);
    emit(EV_IMAGE);
    return NULL;
}

void FakeToup_fire(unsigned ev) { emit(ev); }

/* ---------------- SDK ---------------- */

const char *Toupcam_Version(void) { return "60.33015.20261024"; }

unsigned Toupcam_EnumV2(DeviceV2 *arr) {
    pthread_mutex_lock(&mu);
    logf_("EnumV2");
    if (arr) {
        for (int i = 0; i < ncams; ++i) {
            memset(&arr[i], 0, sizeof(arr[i]));
            snprintf(arr[i].displayname, 64, "%s", cams[i].name);
            snprintf(arr[i].id, 64, "%s", cams[i].id);
            arr[i].model = &cams[i].model;
        }
    }
    int n = ncams;
    pthread_mutex_unlock(&mu);
    return (unsigned)n;
}

void *Toupcam_Open(const char *id) {
    pthread_mutex_lock(&mu);
    logf_("Open %s", id ? id : "(null)");
    void *h = NULL;
    for (int i = 0; i < ncams; ++i)
        if (id && !strcmp(cams[i].id, id)) { open_cam = &cams[i]; h = (void *)&cams[i]; }
    running = 0;
    queued = 0;
    pthread_mutex_unlock(&mu);
    return h;
}

#define CAM(h) ((Camera *)(h))
#define GUARD(h) if (!(h) || CAM(h) != open_cam) return E_UNEXPECTED

HRESULT Toupcam_Stop(void *h) {
    if (in_callback()) { fprintf(stderr, "faketoup: Stop from the callback deadlocks (th:428)\n"); abort(); }
    pthread_mutex_lock(&mu);
    logf_("Stop");
    running = 0;
    generation++;
    pthread_mutex_unlock(&mu);
    return S_OK;
}

void Toupcam_Close(void *h) {
    if (in_callback()) { fprintf(stderr, "faketoup: Close from the callback deadlocks (th:428)\n"); abort(); }
    pthread_mutex_lock(&mu);
    logf_("Close");
    running = 0;
    generation++;
    open_cam = NULL;
    cb = NULL;
    pthread_mutex_unlock(&mu);
}

HRESULT Toupcam_StartPullModeWithCallback(void *h, EventCb fun, void *ctx) {
    GUARD(h);
    pthread_mutex_lock(&mu);
    logf_("StartPullModeWithCallback");
    if (running) { pthread_mutex_unlock(&mu); return E_UNEXPECTED; }
    cb = fun;
    cb_ctx = ctx;
    running = 1;
    pthread_mutex_unlock(&mu);
    return S_OK;
}

HRESULT Toupcam_put_Option(void *h, unsigned opt, int v) {
    GUARD(h);
    Camera *c = CAM(h);
    unsigned long long f = c->model.flag;
    /* th:429-430 */
    if (in_callback() && (opt == O_TRIGGER || opt == O_BITDEPTH || opt == O_PIXEL_FORMAT ||
                          opt == O_BINNING || opt == O_ROTATE))
        return E_WRONG_THREAD;
    pthread_mutex_lock(&mu);
    logf_("put_Option 0x%02x %d running=%d", opt, v, running);
    HRESULT rc = S_OK;
    switch (opt) {
    case O_RAW:
        /* INDI toupbase stops the camera around a RAW change (indi_toupbase.cpp:2367-2375) */
        if (running) rc = E_UNEXPECTED;
        else if (v != 0 && v != 1 && v != -1) rc = E_INVALIDARG;
        else c->p.raw = v;
        break;
    case O_BITDEPTH:
        /* indi_toupbase.cpp:2346-2354 stops around a bit depth change */
        if (running) rc = E_UNEXPECTED;
        else if (v != 0 && v != 1) rc = E_INVALIDARG;
        else if (v == 1 && c->maxbits <= 8) rc = E_NOTIMPL;
        else c->p.bitdepth = v;
        break;
    case O_TRIGGER:
        if (v < 0 || v > 4) rc = E_INVALIDARG;
        else if (v == 1 && !(f & F_TRIGGER_SOFTWARE)) rc = E_NOTIMPL;
        else c->p.trigger = v;
        break;
    case O_UPSIDE_DOWN:
        if (c->upside_locked) rc = E_NOTIMPL;
        else if (running) rc = E_UNEXPECTED;
        else c->p.upside_down = v ? 1 : 0;
        break;
    case O_ZERO_PADDING: c->p.zero_padding = v ? 1 : 0; break;
    case O_CG:
        if (!(f & (F_CG | F_CGHDR))) rc = E_NOTIMPL;
        else if (v < 0 || v > ((f & F_CGHDR) ? 2 : 1)) rc = E_INVALIDARG;
        else c->p.cg = v;
        break;
    case O_BLACKLEVEL: {
        /* th:227-233: maximum 31 << (bitdepth - 8) */
        int max = 31 << (c->maxbits - 8);
        if (!(f & F_BLACKLEVEL)) rc = E_NOTIMPL;
        else if (v < 0 || v > max) rc = E_INVALIDARG;
        else c->p.blacklevel = v;
        break;
    }
    case O_BINNING: {
        /* th:1016-1022: 1..8, 0x40|n, 0x80|n; digital, no model flag */
        int n = v & 0x0f, mode = v & 0xf0;
        if (n < 1 || n > 8 || (mode != 0 && mode != 0x40 && mode != 0x80)) rc = E_INVALIDARG;
        else c->p.binning = v;
        break;
    }
    case O_TEC:
        if (!(f & F_TEC_ONOFF)) rc = E_NOTIMPL; else c->p.tec = v ? 1 : 0;
        break;
    case O_TECTARGET:
        if (!(f & F_TEC_ONOFF)) rc = E_NOTIMPL; else c->p.tectarget = v;
        break;
    case O_FLUSH:
        if (v < 1 || v > 3) rc = E_INVALIDARG;
        else { rc = (v & 2) ? queued : 0; queued = 0; } /* th:1114-1120 */
        break;
    case O_TRIGGER_CANCEL_MODE: c->p.cancel_mode = v ? 1 : 0; break;
    case O_NOFRAME_TIMEOUT: break;
    case O_FAN: break;
    case O_BANDWIDTH: break;
    default: rc = E_NOTIMPL;
    }
    pthread_mutex_unlock(&mu);
    return rc;
}

HRESULT Toupcam_get_Option(void *h, unsigned opt, int *v) {
    GUARD(h);
    if (!v) return E_POINTER;
    Camera *c = CAM(h);
    unsigned long long f = c->model.flag;
    pthread_mutex_lock(&mu);
    logf_("get_Option 0x%02x", opt);
    HRESULT rc = S_OK;
    switch (opt) {
    case O_RAW: *v = c->p.raw; break;
    case O_BITDEPTH: *v = c->p.bitdepth; break;
    case O_TRIGGER: *v = c->p.trigger; break;
    case O_UPSIDE_DOWN: if (c->upside_locked) rc = E_NOTIMPL; else *v = c->p.upside_down; break;
    case O_ZERO_PADDING: *v = c->p.zero_padding; break;
    case O_CG: if (!(f & (F_CG | F_CGHDR))) rc = E_NOTIMPL; else *v = c->p.cg; break;
    case O_BLACKLEVEL: if (!(f & F_BLACKLEVEL)) rc = E_NOTIMPL; else *v = c->p.blacklevel; break;
    case O_BINNING: *v = c->p.binning; break;
    case O_TEC: if (!(f & F_TEC_ONOFF)) rc = E_NOTIMPL; else *v = c->p.tec; break;
    case O_TECTARGET: if (!(f & F_TEC_ONOFF)) rc = E_NOTIMPL; else *v = c->p.tectarget; break;
    case O_TECTARGET_RANGE: if (!(f & F_TEC_ONOFF)) rc = E_NOTIMPL; else *v = c->tec_range; break;
    case O_TEC_VOLTAGE_MAX: if (!(f & F_TEC_ONOFF)) rc = E_NOTIMPL; else *v = c->tec_vmax; break;
    case O_TEC_VOLTAGE: if (!(f & F_TEC_ONOFF)) rc = E_NOTIMPL; else *v = c->p.tec ? c->tec_v : 0; break;
    case O_TRIGGER_CANCEL_MODE: *v = c->p.cancel_mode; break;
    case O_BANDWIDTH: *v = 100; break;
    default: rc = E_NOTIMPL;
    }
    pthread_mutex_unlock(&mu);
    return rc;
}

HRESULT Toupcam_get_MaxBitDepth(void *h) { GUARD(h); return CAM(h)->maxbits; }

HRESULT Toupcam_get_RawFormat(void *h, unsigned *fcc, unsigned *bits) {
    GUARD(h);
    Camera *c = CAM(h);
    pthread_mutex_lock(&mu);
    logf_("get_RawFormat");
    if (fcc) *fcc = c->fourcc;
    if (bits) *bits = c->p.bitdepth ? (unsigned)c->maxbits : 8u;
    pthread_mutex_unlock(&mu);
    return S_OK;
}

HRESULT Toupcam_put_AutoExpoEnable(void *h, int m) { GUARD(h); logf_("put_AutoExpoEnable %d", m); CAM(h)->p.autoexpo = m; return S_OK; }
HRESULT Toupcam_put_Speed(void *h, unsigned short s) {
    GUARD(h); logf_("put_Speed %u", s);
    if (s > CAM(h)->model.maxspeed) return E_INVALIDARG;
    CAM(h)->p.speed = s; return S_OK;
}

HRESULT Toupcam_put_ExpoTime(void *h, unsigned t) {
    GUARD(h);
    Camera *c = CAM(h);
    logf_("put_ExpoTime %u", t);
    if (t < c->expo_min || t > c->expo_max) return E_INVALIDARG;
    c->p.expotime = t;
    return S_OK;
}
HRESULT Toupcam_get_ExpTimeRange(void *h, unsigned *mn, unsigned *mx, unsigned *df) {
    GUARD(h);
    Camera *c = CAM(h);
    if (mn) *mn = c->expo_min;
    if (mx) *mx = c->expo_max;
    if (df) *df = 100000;
    return S_OK;
}
HRESULT Toupcam_get_ExpoAGain(void *h, unsigned short *g) { GUARD(h); if (!g) return E_POINTER; *g = CAM(h)->p.gain; return S_OK; }
HRESULT Toupcam_put_ExpoAGain(void *h, unsigned short g) {
    GUARD(h);
    Camera *c = CAM(h);
    logf_("put_ExpoAGain %u", g);
    if (g < c->gain_min || g > c->gain_max) return E_INVALIDARG;
    c->p.gain = g;
    return S_OK;
}
HRESULT Toupcam_get_ExpoAGainRange(void *h, unsigned short *mn, unsigned short *mx, unsigned short *df) {
    GUARD(h);
    Camera *c = CAM(h);
    if (mn) *mn = c->gain_min;
    if (mx) *mx = c->gain_max;
    if (df) *df = c->gain_def;
    return S_OK;
}
HRESULT Toupcam_get_Temperature(void *h, short *t) {
    GUARD(h);
    if (!(CAM(h)->model.flag & F_GETTEMPERATURE)) return E_NOTIMPL; /* th:883 */
    *t = CAM(h)->temperature;
    return S_OK;
}
HRESULT Toupcam_put_Temperature(void *h, short t) {
    GUARD(h);
    logf_("put_Temperature %d", t);
    if (!(CAM(h)->model.flag & F_TEC_ONOFF)) return E_NOTIMPL; /* th:889 */
    CAM(h)->p.tectarget = t;
    return S_OK;
}
HRESULT Toupcam_get_Size(void *h, int *w, int *hh) {
    GUARD(h);
    *w = (int)CAM(h)->model.res[0].width;
    *hh = (int)CAM(h)->model.res[0].height;
    return S_OK;
}
HRESULT Toupcam_get_FinalSize(void *h, int *w, int *hh) {
    GUARD(h);
    unsigned fw, fh;
    final_size(CAM(h), &CAM(h)->p, &fw, &fh);
    *w = (int)fw;
    *hh = (int)fh;
    return S_OK;
}
HRESULT Toupcam_put_Roi(void *h, unsigned x, unsigned y, unsigned w, unsigned hh) {
    GUARD(h);
    Camera *c = CAM(h);
    logf_("put_Roi %u %u %u %u", x, y, w, hh);
    if (x == 0 && y == 0 && w == 0 && hh == 0) { c->p.roi_x = c->p.roi_y = c->p.roi_w = c->p.roi_h = 0; return S_OK; }
    /* th:1365-1367: even numbers, minimum 8 (the 59.28926 manual says 16); th:41-44:
       coordinates in the original resolution */
    if ((x | y | w | hh) & 1) return E_INVALIDARG;
    if (w < 8 || hh < 8) return E_INVALIDARG;
    if (x + w > c->model.res[0].width || y + hh > c->model.res[0].height) return E_INVALIDARG;
    c->p.roi_x = x; c->p.roi_y = y; c->p.roi_w = w; c->p.roi_h = hh;
    return S_OK;
}
HRESULT Toupcam_get_SerialNumber(void *h, char sn[32]) {
    GUARD(h);
    snprintf(sn, 32, "TP%029d", 42);
    return S_OK;
}

HRESULT Toupcam_Trigger(void *h, unsigned short n) {
    GUARD(h);
    Camera *c = CAM(h);
    pthread_mutex_lock(&mu);
    logf_("Trigger %u running=%d trigger=%d", n, running, c->p.trigger);
    if (!running || c->p.trigger != 1) { pthread_mutex_unlock(&mu); return E_UNEXPECTED; }
    if (n == 0) {
        /* th:1279: cancel mode 1 outputs the frame that was being exposed */
        int output = c->p.cancel_mode && pending_triggers > 0;
        pending_triggers = output ? 1 : 0;
        generation++;
        Job *job = output ? malloc(sizeof(Job)) : NULL;
        if (job) { job->gen = generation; job->ms = c->cancel_ms ? c->cancel_ms : 1; job->at = last_trigger; }
        pthread_mutex_unlock(&mu);
        if (job) {
            pthread_t t;
            pthread_create(&t, NULL, deliver, job);
            pthread_detach(t);
        }
        return S_OK;
    }
    pending_triggers += n;
    int deliver_now = c->auto_frames;
    Job *job = malloc(sizeof(Job));
    job->gen = generation;
    job->ms = c->deliver_ms ? c->deliver_ms : (int)(c->p.expotime / 1000);
    job->at = c->p;
    last_trigger = c->p;
    pthread_mutex_unlock(&mu);
    if (deliver_now) {
        pthread_t t;
        pthread_create(&t, NULL, deliver, job);
        pthread_detach(t);
    } else {
        free(job);
    }
    return S_OK;
}

/* Delivers the frame the last Trigger(1) asked for right now (for tests that turn auto off). */
void FakeToup_deliver(void) {
    Job *job = malloc(sizeof(Job));
    job->gen = generation;
    job->ms = 0;
    job->at = last_trigger;
    deliver(job);
}

HRESULT Toupcam_PullImageV3(void *h, void *buf, int bStill, int bits, int rowPitch, FrameInfoV3 *info) {
    GUARD(h);
    Camera *c = CAM(h);
    pthread_mutex_lock(&mu);
    logf_("PullImageV3 still=%d bits=%d pitch=%d", bStill, bits, rowPitch);
    if (bStill || queued == 0) { pthread_mutex_unlock(&mu); return E_PENDING; }
    FrameInfoV3 fi = queued_info[0];
    Persist p = queued_state[0];
    memmove(queued_info, queued_info + 1, sizeof(FrameInfoV3) * (size_t)(queued - 1));
    memmove(queued_state, queued_state + 1, sizeof(Persist) * (size_t)(queued - 1));
    queued--;
    pthread_mutex_unlock(&mu);
    if (!p.raw) return E_UNEXPECTED; /* this fake only produces RAW */
    int depth = p.bitdepth ? c->maxbits : 8;
    int bytes = p.bitdepth ? 2 : 1;
    int n = p.binning & 0x0f;
    int add_unsat = (p.binning & 0x40) != 0, avg = (p.binning & 0x80) != 0;
    unsigned H = c->model.res[0].height;
    unsigned rx = p.roi_w ? p.roi_x : 0, ry = p.roi_w ? p.roi_y : 0;
    unsigned max = (1u << depth) - 1;
    for (unsigned r = 0; r < fi.height; ++r) {
        for (unsigned col = 0; col < fi.width; ++col) {
            unsigned long sum = 0;
            for (int dy = 0; dy < n; ++dy)
                for (int dx = 0; dx < n; ++dx) {
                    /* ROI y is counted in the delivered row order (th:43) */
                    unsigned delivered_row = ry + r * (unsigned)n + (unsigned)dy;
                    unsigned sensor_row = p.upside_down ? H - 1 - delivered_row : delivered_row;
                    sum += sensor_pixel(sensor_row, rx + col * (unsigned)n + (unsigned)dx, depth);
                }
            unsigned v = avg ? (unsigned)(sum / (unsigned long)(n * n)) : (add_unsat ? (unsigned)sum : (unsigned)(sum > max ? max : sum));
            if (bytes == 2) {
                if (p.zero_padding) v <<= (16 - depth);
                ((uint16_t *)buf)[r * fi.width + col] = (uint16_t)v;
            } else {
                ((uint8_t *)buf)[r * fi.width + col] = (uint8_t)v;
            }
        }
    }
    (void)bits;
    (void)rowPitch;
    if (info) *info = fi;
    return S_OK;
}

/* The fake sensor pattern, for tests: value of sensor pixel (row, column) at a bit depth. */
unsigned FakeToup_sensor_pixel(unsigned r, unsigned c, int bits) { return sensor_pixel(r, c, bits); }

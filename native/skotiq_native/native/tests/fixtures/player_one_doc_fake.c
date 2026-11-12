/*
 * A Player One camera and Phoenix filter-wheel SDK written from Player One's own headers
 * (PlayerOneCamera.h and PlayerOnePW.h as shipped in indi-3rdparty/libplayerone, SDK
 * v3.10.0 / PW v1.2.3), not from Skotiq's driver. It is compiled against those headers, so
 * every struct the driver reads has the vendor's layout.
 *
 * One library answers both SDKs: build it once and link libPlayerOnePW.so to the same file,
 * so the two names share one state and one overlap counter.
 *
 *   cc -shared -fPIC -O1 -I<libplayerone> player_one_doc_fake.c -o libPlayerOneCamera.so -lpthread
 *   ln -sf libPlayerOneCamera.so libPlayerOnePW.so
 *
 * Where the headers leave a behavior open, this fake does what the x64 SDK 3.10.1 binary
 * in indi-3rdparty does (read from its disassembly), as noted at each place.
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "PlayerOneCamera.h"
#include "PlayerOnePW.h"

/* ---- bookkeeping the test reads ---------------------------------------------------- */

static atomic_int in_call;
static atomic_int overlaps;
static pthread_mutex_t log_mutex = PTHREAD_MUTEX_INITIALIZER;
static char log_buf[1 << 20];
static size_t log_len;

static void note(const char *fmt, ...)
{
    pthread_mutex_lock(&log_mutex);
    if (log_len < sizeof(log_buf) - 256) {
        va_list ap;
        va_start(ap, fmt);
        int n = vsnprintf(log_buf + log_len, sizeof(log_buf) - log_len - 1, fmt, ap);
        va_end(ap);
        if (n > 0)
            log_len += (size_t)n;
        log_buf[log_len++] = '\n';
        log_buf[log_len] = 0;
    }
    pthread_mutex_unlock(&log_mutex);
}

/* Every SDK entry point runs between enter() and leave(): a second call that starts while
 * one is running, from either SDK, counts as an overlap. */
static void enter(void)
{
    if (atomic_fetch_add(&in_call, 1) != 0)
        atomic_fetch_add(&overlaps, 1);
}
static void leave(void) { atomic_fetch_sub(&in_call, 1); }

#define RETURN(v) do { __typeof__(v) r__ = (v); leave(); return r__; } while (0)

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* ---- cameras ------------------------------------------------------------------------ */

/* Two cameras whose IDs differ from their indexes, so an index used as an ID shows. */
#define CAMERAS 2
static const int camera_ids[CAMERAS] = {7, 3};
#define MAX_W 128
#define MAX_H 96

typedef struct {
    int opened, inited;
    int bin;
    int x, y, w, h; /* binned pixels */
    POAImgFormat format;
    int exposing, single, frame_ready;
    double started, exposure_s;
    long gain, offset, target_temp, heater, fan, usb;
    POABool cooler, mono_bin;
    int sensor_mode;
} Camera;

static Camera cams[CAMERAS];

static Camera *cam_by_id(int id)
{
    for (int i = 0; i < CAMERAS; i++)
        if (camera_ids[i] == id)
            return &cams[i];
    return NULL;
}

static int old_sdk(void) { const char *v = getenv("FAKE_POA_NO_EXP"); return v && *v == '1'; }

static void fill_properties(int index, POACameraProperties *p)
{
    memset(p, 0, sizeof(*p));
    p->cameraID = camera_ids[index];
    snprintf(p->cameraModelName, sizeof(p->cameraModelName), index == 0 ? "Uranus-C Pro" : "Neptune-M");
    snprintf(p->SN, sizeof(p->SN), "PO-FAKE-%04d", camera_ids[index]);
    p->maxWidth = MAX_W;
    p->maxHeight = MAX_H;
    p->bitDepth = 12;
    p->isColorCamera = index == 0 ? POA_TRUE : POA_FALSE;
    p->isHasST4Port = POA_TRUE;
    p->isHasCooler = index == 0 ? POA_TRUE : POA_FALSE;
    p->isUSB3Speed = POA_TRUE;
    p->bayerPattern = index == 0 ? POA_BAYER_GR : POA_BAYER_MONO;
    p->pixelSize = 2.9;
    snprintf(p->sensorModelName, sizeof(p->sensorModelName), "IMX585");
    int bins[] = {1, 2, 3, 4, 0, 0, 0, 0};
    memcpy(p->bins, bins, sizeof(bins));
    POAImgFormat f[] = {POA_RAW8, POA_RAW16, POA_RGB24, POA_MONO8, POA_END, POA_END, POA_END, POA_END};
    memcpy(p->imgFormats, f, sizeof(f));
    p->isSupportHardBin = POA_FALSE;
    p->pID = 0x1234;
}

int POAGetCameraCount(void) { enter(); note("POAGetCameraCount()"); RETURN(CAMERAS); }

POAErrors POAGetCameraProperties(int index, POACameraProperties *p)
{
    enter();
    note("POAGetCameraProperties(%d)", index);
    if (!p) RETURN(POA_ERROR_POINTER);
    if (index < 0 || index >= CAMERAS) RETURN(POA_ERROR_INVALID_INDEX);
    fill_properties(index, p);
    RETURN(POA_OK);
}

POAErrors POAGetCameraPropertiesByID(int id, POACameraProperties *p)
{
    enter();
    note("POAGetCameraPropertiesByID(%d)", id);
    if (!p) RETURN(POA_ERROR_POINTER);
    for (int i = 0; i < CAMERAS; i++)
        if (camera_ids[i] == id) { fill_properties(i, p); RETURN(POA_OK); }
    RETURN(POA_ERROR_INVALID_ID);
}

POAErrors POAOpenCamera(int id)
{
    enter();
    note("POAOpenCamera(%d)", id);
    Camera *c = cam_by_id(id);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    memset(c, 0, sizeof(*c));
    c->opened = 1;
    RETURN(POA_OK);
}

POAErrors POAInitCamera(int id)
{
    enter();
    note("POAInitCamera(%d)", id);
    Camera *c = cam_by_id(id);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    c->inited = 1;
    c->bin = 1;
    c->w = MAX_W;
    c->h = MAX_H;
    c->format = POA_RAW8; /* open: the power-on format is not documented; RAW8 makes a missed SetImageFormat show */
    c->exposure_s = 0.01;
    c->gain = 100;
    c->offset = 12;
    c->usb = 90;
    RETURN(POA_OK);
}

POAErrors POACloseCamera(int id)
{
    enter();
    note("POACloseCamera(%d)", id);
    Camera *c = cam_by_id(id);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    /* POACamera::CloseCamera stops a running exposure itself (SDK 3.10.1, x64). */
    c->opened = c->inited = c->exposing = c->frame_ready = 0;
    RETURN(POA_OK);
}

/* The attribute table, from the POAConfig comments in PlayerOneCamera.h. */
typedef struct {
    POAConfig id;
    POAValueType type;
    int writable;
    double min, max, def;
    const char *name;
} Attr;

static const Attr attrs[] = {
    {POA_EXPOSURE, VAL_INT, 1, 10, 2000000000.0, 10000, "Exposure"},
    {POA_GAIN, VAL_INT, 1, 0, 600, 100, "Gain"},
    {POA_HARDWARE_BIN, VAL_BOOL, 1, 0, 1, 0, "HardwareBin"},
    {POA_TEMPERATURE, VAL_FLOAT, 0, -100, 100, 0, "Temperature"},
    {POA_OFFSET, VAL_INT, 1, 0, 254, 12, "Offset"},
    {POA_EGAIN, VAL_FLOAT, 0, 0, 100, 1, "eGain"},
    {POA_COOLER_POWER, VAL_INT, 0, 0, 100, 0, "CoolerPower"},
    {POA_TARGET_TEMP, VAL_INT, 1, -50, 50, 0, "TargetTemp"},
    {POA_COOLER, VAL_BOOL, 1, 0, 1, 0, "Cooler"},
    {POA_HEATER_POWER, VAL_INT, 1, 0, 100, 0, "HeaterPower"},
    {POA_FAN_POWER, VAL_INT, 1, 0, 100, 0, "FanPower"},
    {POA_USB_BANDWIDTH_LIMIT, VAL_INT, 1, 35, 100, 90, "USBBandWidthLimit"},
    {POA_PIXEL_BIN_SUM, VAL_BOOL, 1, 0, 1, 0, "PixelBinSum"},
    {POA_MONO_BIN, VAL_BOOL, 1, 0, 1, 0, "MonoBin"},
    {POA_EXP, VAL_FLOAT, 1, 0.00001, 7200.0, 0.01, "Exp"},
};

static const Attr *attr_of(POAConfig id, int color)
{
    if (id == POA_EXP && old_sdk())
        return NULL;
    if (!color && (id == POA_COOLER || id == POA_COOLER_POWER || id == POA_TARGET_TEMP))
        return NULL;
    for (size_t i = 0; i < sizeof(attrs) / sizeof(attrs[0]); i++)
        if (attrs[i].id == id)
            return &attrs[i];
    return NULL;
}

static int is_color(int id) { return id == camera_ids[0]; }

static void put(POAValueType t, double v, POAConfigValue *out)
{
    memset(out, 0, sizeof(*out));
    if (t == VAL_INT) out->intValue = (long)v;
    else if (t == VAL_FLOAT) out->floatValue = v;
    else out->boolValue = v != 0 ? POA_TRUE : POA_FALSE;
}

POAErrors POAGetConfigValueType(POAConfig id, POAValueType *t)
{
    enter();
    if (!t) RETURN(POA_ERROR_POINTER);
    const Attr *a = attr_of(id, 1);
    if (!a) RETURN(POA_ERROR_INVALID_CONFIG);
    *t = a->type;
    RETURN(POA_OK);
}

static void fill_attr(const Attr *a, POAConfigAttributes *out)
{
    memset(out, 0, sizeof(*out));
    out->isSupportAuto = POA_FALSE;
    out->isWritable = a->writable ? POA_TRUE : POA_FALSE;
    out->isReadable = POA_TRUE;
    out->configID = a->id;
    out->valueType = a->type;
    put(a->type, a->max, &out->maxValue);
    put(a->type, a->min, &out->minValue);
    put(a->type, a->def, &out->defaultValue);
    snprintf(out->szConfName, sizeof(out->szConfName), "%s", a->name);
}

POAErrors POAGetConfigAttributesByConfigID(int id, POAConfig conf, POAConfigAttributes *out)
{
    enter();
    note("POAGetConfigAttributesByConfigID(%d,%d)", id, conf);
    Camera *c = cam_by_id(id);
    if (!out) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    const Attr *a = attr_of(conf, is_color(id));
    if (!a) RETURN(POA_ERROR_INVALID_CONFIG);
    fill_attr(a, out);
    RETURN(POA_OK);
}

POAErrors POAGetConfigsCount(int id, int *n)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!n) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    *n = (int)(sizeof(attrs) / sizeof(attrs[0]));
    RETURN(POA_OK);
}

POAErrors POAGetConfigAttributes(int id, int index, POAConfigAttributes *out)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!out) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (index < 0 || index >= (int)(sizeof(attrs) / sizeof(attrs[0]))) RETURN(POA_ERROR_INVALID_INDEX);
    fill_attr(&attrs[index], out);
    RETURN(POA_OK);
}

static double clamp(double v, const Attr *a)
{
    /* The header does not say what POASetConfig does with a value outside the attribute
     * range. SDK 3.10.1 (x64) clamps it and answers POA_OK (POACamera::SetExposure takes
     * the nearer bound), so this fake does the same for every control. */
    return v < a->min ? a->min : (v > a->max ? a->max : v);
}

static double value_of(Camera *c, POAConfig conf)
{
    switch (conf) {
    case POA_EXPOSURE: return (double)(long)(c->exposure_s * 1e6 + 0.5);
    case POA_EXP: return c->exposure_s;
    case POA_GAIN: return (double)c->gain;
    case POA_OFFSET: return (double)c->offset;
    case POA_TEMPERATURE: return -10.5;
    case POA_EGAIN: return 0.83;
    case POA_COOLER_POWER: return c->cooler ? 42 : 0;
    case POA_TARGET_TEMP: return (double)c->target_temp;
    case POA_COOLER: return c->cooler == POA_TRUE;
    case POA_HEATER_POWER: return (double)c->heater;
    case POA_FAN_POWER: return (double)c->fan;
    case POA_USB_BANDWIDTH_LIMIT: return (double)c->usb;
    case POA_MONO_BIN: return c->mono_bin == POA_TRUE;
    default: return 0;
    }
}

POAErrors POASetConfig(int id, POAConfig conf, POAConfigValue v, POABool isAuto)
{
    enter();
    Camera *c = cam_by_id(id);
    const Attr *a = c ? attr_of(conf, is_color(id)) : NULL;
    double value = 0;
    if (a) {
        if (a->type == VAL_INT) value = (double)v.intValue;
        else if (a->type == VAL_FLOAT) value = v.floatValue;
        else value = v.boolValue == POA_TRUE;
    }
    note("POASetConfig(%d,%d,%.9g,%d)", id, conf, value, isAuto);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (!a) RETURN(POA_ERROR_INVALID_CONFIG);
    if (!a->writable) RETURN(POA_ERROR_CONF_CANNOT_WRITE);
    value = clamp(value, a);
    switch (conf) {
    case POA_EXPOSURE: c->exposure_s = value / 1e6; break;
    case POA_EXP: c->exposure_s = value; break;
    case POA_GAIN: c->gain = (long)value; break;
    case POA_OFFSET: c->offset = (long)value; break;
    case POA_TARGET_TEMP: c->target_temp = (long)value; break;
    case POA_COOLER: c->cooler = value != 0 ? POA_TRUE : POA_FALSE; break;
    case POA_HEATER_POWER: c->heater = (long)value; break;
    case POA_FAN_POWER: c->fan = (long)value; break;
    case POA_USB_BANDWIDTH_LIMIT: c->usb = (long)value; break;
    case POA_MONO_BIN: c->mono_bin = value != 0 ? POA_TRUE : POA_FALSE; break;
    default: break;
    }
    RETURN(POA_OK);
}

POAErrors POAGetConfig(int id, POAConfig conf, POAConfigValue *v, POABool *isAuto)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!v || !isAuto) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    const Attr *a = attr_of(conf, is_color(id));
    if (!a) RETURN(POA_ERROR_INVALID_CONFIG);
    put(a->type, value_of(c, conf), v);
    *isAuto = POA_FALSE;
    RETURN(POA_OK);
}

static int binned_w(Camera *c) { return MAX_W / c->bin; }
static int binned_h(Camera *c) { return MAX_H / c->bin; }

POAErrors POASetImageBin(int id, int bin)
{
    enter();
    note("POASetImageBin(%d,%d)", id, bin);
    Camera *c = cam_by_id(id);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (c->exposing) RETURN(POA_ERROR_EXPOSING); /* "should stop exposure first" */
    if (bin < 1 || bin > 4) RETURN(POA_ERROR_INVALID_ARGU);
    /* "the image size and start position will be changed": as POACamera::SetBin in SDK
     * 3.10.1 (x64), the ROI keeps its sensor area, so a size or start set before the bin
     * lands in the wrong place. */
    int old = c->bin;
    c->bin = bin;
    c->x = c->x * old / bin;
    c->y = c->y * old / bin;
    c->w = (c->w * old / bin) & ~3;
    c->h = (c->h * old / bin) & ~1;
    if (c->w < 4) c->w = 4;
    if (c->h < 2) c->h = 2;
    if (c->x + c->w > binned_w(c)) c->x = binned_w(c) - c->w;
    if (c->y + c->h > binned_h(c)) c->y = binned_h(c) - c->h;
    RETURN(POA_OK);
}

POAErrors POAGetImageBin(int id, int *bin)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!bin) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    *bin = c->bin;
    RETURN(POA_OK);
}

POAErrors POASetImageSize(int id, int w, int h)
{
    enter();
    note("POASetImageSize(%d,%d,%d)", id, w, h);
    Camera *c = cam_by_id(id);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (c->exposing) RETURN(POA_ERROR_EXPOSING);
    if (w < 0 || h < 0) RETURN(POA_ERROR_INVALID_ARGU);
    /* As POACamera::SetImgSize in SDK 3.10.1 (x64): a size past the sensor or of 0 becomes
     * the whole binned sensor; the width is cut to a multiple of 4 and the height of 2; a
     * new size re-centers the ROI, so a start set before it is lost. */
    if (w == 0 || w > binned_w(c)) w = binned_w(c);
    if (h == 0 || h > binned_h(c)) h = binned_h(c);
    w = w & ~3;
    h = h & ~1;
    if (w < 4) w = 4;
    if (h < 2) h = 2;
    if (w != c->w || h != c->h) {
        c->w = w;
        c->h = h;
        c->x = ((binned_w(c) - w) / 2) & ~1;
        c->y = ((binned_h(c) - h) / 2) & ~1;
    }
    RETURN(POA_OK);
}

POAErrors POAGetImageSize(int id, int *w, int *h)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!w || !h) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    *w = c->w;
    *h = c->h;
    RETURN(POA_OK);
}

POAErrors POASetImageStartPos(int id, int x, int y)
{
    enter();
    note("POASetImageStartPos(%d,%d,%d)", id, x, y);
    Camera *c = cam_by_id(id);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (x < 0 || y < 0) RETURN(POA_ERROR_INVALID_ARGU);
    /* As POACamera::SetImgStartPixel in SDK 3.10.1 (x64): a start that would push the ROI
     * off the sensor is moved back, and every start is made even, on mono sensors too. */
    if (x + c->w > binned_w(c)) x = binned_w(c) - c->w;
    if (y + c->h > binned_h(c)) y = binned_h(c) - c->h;
    c->x = x & ~1;
    c->y = y & ~1;
    RETURN(POA_OK);
}

POAErrors POAGetImageStartPos(int id, int *x, int *y)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!x || !y) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    *x = c->x;
    *y = c->y;
    RETURN(POA_OK);
}

POAErrors POASetImageFormat(int id, POAImgFormat f)
{
    enter();
    note("POASetImageFormat(%d,%d)", id, f);
    Camera *c = cam_by_id(id);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (c->exposing) RETURN(POA_ERROR_EXPOSING);
    if (f < POA_RAW8 || f > POA_MONO8) RETURN(POA_ERROR_INVALID_ARGU);
    c->format = f;
    RETURN(POA_OK);
}

POAErrors POAGetImageFormat(int id, POAImgFormat *f)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!f) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    *f = c->format;
    RETURN(POA_OK);
}

/* Advances an exposure by the clock: a single frame ends the exposure when its frame is
 * ready; video mode keeps exposing and makes a frame every period. */
static void tick(Camera *c)
{
    if (!c->exposing)
        return;
    if (now_s() - c->started >= c->exposure_s) {
        c->frame_ready = 1;
        if (c->single)
            c->exposing = 0;
        else
            c->started = now_s();
    }
}

POAErrors POAStartExposure(int id, POABool single)
{
    enter();
    note("POAStartExposure(%d,%d)", id, single);
    Camera *c = cam_by_id(id);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (!c->inited) RETURN(POA_ERROR_OPERATION_FAILED);
    tick(c);
    if (c->exposing) RETURN(POA_ERROR_EXPOSING);
    c->exposing = 1;
    c->single = single == POA_TRUE;
    c->frame_ready = 0;
    c->started = now_s();
    RETURN(POA_OK);
}

POAErrors POAStopExposure(int id)
{
    enter();
    note("POAStopExposure(%d)", id);
    Camera *c = cam_by_id(id);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    c->exposing = 0;
    c->frame_ready = 0;
    RETURN(POA_OK);
}

POAErrors POAGetCameraState(int id, POACameraState *s)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!s) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    tick(c);
    *s = !c->opened ? STATE_CLOSED : (c->exposing ? STATE_EXPOSING : STATE_OPENED);
    RETURN(POA_OK);
}

POAErrors POAImageReady(int id, POABool *ready)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!ready) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    tick(c);
    *ready = c->frame_ready ? POA_TRUE : POA_FALSE;
    RETURN(POA_OK);
}

static int bytes_per_pixel(POAImgFormat f) { return f == POA_RAW16 ? 2 : (f == POA_RGB24 ? 3 : 1); }

/* Each sample is (y << 8) | x of the binned pixel it comes from on the whole binned
 * sensor, so the test can tell where the frame starts and how it was binned. */
POAErrors POAGetImageData(int id, unsigned char *buf, long size, int timeout_ms)
{
    enter();
    note("POAGetImageData(%d,%ld,%d)", id, size, timeout_ms);
    Camera *c = cam_by_id(id);
    if (!buf) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (size < 0) RETURN(POA_ERROR_INVALID_ARGU);
    long need = (long)c->w * c->h * bytes_per_pixel(c->format);
    if (size < need) RETURN(POA_ERROR_SIZE_LESS);
    double deadline = now_s() + (timeout_ms < 0 ? 1e9 : timeout_ms / 1000.0);
    tick(c);
    while (!c->frame_ready && c->exposing && now_s() < deadline) {
        usleep(1000);
        tick(c);
    }
    if (!c->frame_ready) RETURN(POA_ERROR_TIMEOUT);
    for (int j = 0; j < c->h; j++)
        for (int i = 0; i < c->w; i++) {
            unsigned v = (unsigned)(((c->y + j) << 8) | (c->x + i));
            long k = (long)j * c->w + i;
            if (c->format == POA_RAW16) {
                buf[2 * k] = (unsigned char)(v & 0xff);
                buf[2 * k + 1] = (unsigned char)(v >> 8);
            } else {
                buf[k * bytes_per_pixel(c->format)] = (unsigned char)(v & 0xff);
            }
        }
    c->frame_ready = 0;
    RETURN(POA_OK);
}

POAErrors POAGetDroppedImagesCount(int id, int *n)
{
    enter();
    if (!n) RETURN(POA_ERROR_POINTER);
    if (!cam_by_id(id)) RETURN(POA_ERROR_INVALID_ID);
    *n = 0;
    RETURN(POA_OK);
}

static const char *mode_names[] = {"Normal", "LowNoise"};

POAErrors POAGetSensorModeCount(int id, int *n)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!n) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    *n = is_color(id) ? 2 : 0; /* "0 means camera don't supported mode selection" */
    RETURN(POA_OK);
}

POAErrors POAGetSensorModeInfo(int id, int index, POASensorModeInfo *info)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!info) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (!is_color(id)) RETURN(POA_ERROR_ACCESS_DENIED);
    if (index < 0 || index > 1) RETURN(POA_ERROR_INVALID_ARGU);
    memset(info, 0, sizeof(*info));
    snprintf(info->name, sizeof(info->name), "%s", mode_names[index]);
    snprintf(info->desc, sizeof(info->desc), "%s readout", mode_names[index]);
    RETURN(POA_OK);
}

POAErrors POASetSensorMode(int id, int index)
{
    enter();
    note("POASetSensorMode(%d,%d)", id, index);
    Camera *c = cam_by_id(id);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (!is_color(id)) RETURN(POA_ERROR_ACCESS_DENIED);
    if (index < 0 || index > 1) RETURN(POA_ERROR_INVALID_ARGU);
    c->sensor_mode = index;
    RETURN(POA_OK);
}

POAErrors POAGetSensorMode(int id, int *index)
{
    enter();
    Camera *c = cam_by_id(id);
    if (!index) RETURN(POA_ERROR_POINTER);
    if (!c) RETURN(POA_ERROR_INVALID_ID);
    if (!c->opened) RETURN(POA_ERROR_NOT_OPENED);
    if (!is_color(id)) RETURN(POA_ERROR_ACCESS_DENIED);
    *index = c->sensor_mode;
    RETURN(POA_OK);
}

const char *POAGetErrorString(POAErrors err) { (void)err; return "fake error"; }
int POAGetAPIVersion(void) { return 20250101; }
const char *POAGetSDKVersion(void) { return "3.10.0"; }

/* ---- Phoenix filter wheel -------------------------------------------------------------- */

#define PW_HANDLE 5
#define PW_SLOTS 7

static struct {
    int opened;
    int position;
    double moving_until;
    char alias[PW_SLOTS][MAX_NAME_LEN];
    int alias_len[PW_SLOTS];
} pw;

static int pw_homing_ms(void) { const char *v = getenv("FAKE_PW_HOMING_MS"); return v ? atoi(v) : 0; }
static int pw_moving(void) { return now_s() < pw.moving_until; }

int POAGetPWCount(void) { enter(); note("POAGetPWCount()"); RETURN(1); }

static void fill_pw(PWProperties *p)
{
    memset(p, 0, sizeof(*p));
    snprintf(p->Name, sizeof(p->Name), "PhoenixWheel");
    p->Handle = PW_HANDLE;
    p->PositionCount = PW_SLOTS;
    snprintf(p->SN, sizeof(p->SN), "PW-FAKE-01");
}

PWErrors POAGetPWProperties(int index, PWProperties *p)
{
    enter();
    note("POAGetPWProperties(%d)", index);
    if (!p) RETURN(PW_ERROR_POINTER);
    if (index != 0) RETURN(PW_ERROR_INVALID_INDEX);
    fill_pw(p);
    RETURN(PW_OK);
}

PWErrors POAGetPWPropertiesByHandle(int handle, PWProperties *p)
{
    enter();
    note("POAGetPWPropertiesByHandle(%d)", handle);
    if (!p) RETURN(PW_ERROR_POINTER);
    if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE);
    fill_pw(p);
    RETURN(PW_OK);
}

PWErrors POAOpenPW(int handle)
{
    enter();
    note("POAOpenPW(%d)", handle);
    if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE);
    pw.opened = 1;
    /* The wheel turns to find its home after it is opened (INDI's WAIT_AFTER_OPEN_DEVICE,
     * NINA's Connect wait). */
    pw.moving_until = now_s() + pw_homing_ms() / 1000.0;
    pw.position = 0;
    RETURN(PW_OK);
}

PWErrors POAClosePW(int handle)
{
    enter();
    note("POAClosePW(%d)", handle);
    if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE);
    pw.opened = 0;
    RETURN(PW_OK);
}

PWErrors POAGetCurrentPosition(int handle, int *pos)
{
    enter();
    if (!pos) RETURN(PW_ERROR_POINTER);
    if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE);
    if (!pw.opened) RETURN(PW_ERROR_NOT_OPENED);
    if (pw_moving()) RETURN(PW_ERROR_IS_MOVING);
    *pos = pw.position;
    RETURN(PW_OK);
}

PWErrors POAGotoPosition(int handle, int pos)
{
    enter();
    note("POAGotoPosition(%d,%d)", handle, pos);
    if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE);
    if (!pw.opened) RETURN(PW_ERROR_NOT_OPENED);
    if (pos < 0 || pos >= PW_SLOTS) RETURN(PW_ERROR_INVALID_ARGU);
    if (pw_moving()) RETURN(PW_ERROR_IS_MOVING);
    pw.position = pos;
    pw.moving_until = now_s() + 0.3;
    RETURN(PW_OK);
}

PWErrors POAGetPWState(int handle, PWState *state)
{
    enter();
    if (!state) RETURN(PW_ERROR_POINTER);
    if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE);
    *state = !pw.opened ? PW_STATE_CLOSED : (pw_moving() ? PW_STATE_MOVING : PW_STATE_OPENED);
    RETURN(PW_OK);
}

PWErrors POAGetPWFilterAlias(int handle, int pos, char *buf, int len)
{
    enter();
    note("POAGetPWFilterAlias(%d,%d,%d)", handle, pos, len);
    if (!buf) RETURN(PW_ERROR_POINTER);
    if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE);
    if (!pw.opened) RETURN(PW_ERROR_NOT_OPENED);
    if (pos < 0 || pos >= PW_SLOTS) RETURN(PW_ERROR_INVALID_ARGU);
    if (len < MAX_NAME_LEN) RETURN(PW_ERROR_INVALID_ARGU); /* "should NOT be less than 24" */
    memset(buf, 0, (size_t)len);
    memcpy(buf, pw.alias[pos], (size_t)pw.alias_len[pos]);
    RETURN(PW_OK);
}

PWErrors POASetPWFilterAlias(int handle, int pos, const char *buf, int len)
{
    enter();
    note("POASetPWFilterAlias(%d,%d,%d)", handle, pos, len);
    if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE);
    if (!pw.opened) RETURN(PW_ERROR_NOT_OPENED);
    if (pos < 0 || pos >= PW_SLOTS) RETURN(PW_ERROR_INVALID_ARGU);
    if (!buf || len == 0) { pw.alias_len[pos] = 0; RETURN(PW_OK); } /* clears */
    if (len < 0 || len >= MAX_NAME_LEN) RETURN(PW_ERROR_INVALID_ARGU); /* "should be less than 24" */
    /* The SDK takes `len` bytes; it does not look for a NUL. */
    memcpy(pw.alias[pos], buf, (size_t)len);
    pw.alias_len[pos] = len;
    RETURN(PW_OK);
}

PWErrors POAGetOneWay(int handle, int *one_way) { enter(); if (!one_way) RETURN(PW_ERROR_POINTER); if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE); *one_way = 0; RETURN(PW_OK); }
PWErrors POASetOneWay(int handle, int one_way) { enter(); (void)one_way; if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE); RETURN(PW_OK); }
PWErrors POAResetPW(int handle) { enter(); note("POAResetPW(%d)", handle); if (handle != PW_HANDLE) RETURN(PW_ERROR_INVALID_HANDLE); RETURN(PW_OK); }
const char *POAGetPWErrorString(PWErrors err) { (void)err; return "fake pw error"; }
int POAGetPWAPIVer(void) { return 20250101; }
const char *POAGetPWSDKVer(void) { return "1.2.3"; }

/* ---- what the test reads --------------------------------------------------------------- */

const char *fake_poa_log(void) { return log_buf; }
void fake_poa_clear_log(void) { pthread_mutex_lock(&log_mutex); log_len = 0; log_buf[0] = 0; pthread_mutex_unlock(&log_mutex); }
int fake_poa_overlaps(void) { return atomic_load(&overlaps); }
int fake_poa_format(int id) { Camera *c = cam_by_id(id); return c ? (int)c->format : -1; }
int fake_poa_exposing(int id) { Camera *c = cam_by_id(id); if (!c) return -1; tick(c); return c->exposing; }
int fake_pw_alias(int pos, char *out, int len)
{
    if (pos < 0 || pos >= PW_SLOTS || len <= pw.alias_len[pos]) return -1;
    memcpy(out, pw.alias[pos], (size_t)pw.alias_len[pos]);
    out[pw.alias_len[pos]] = 0;
    return pw.alias_len[pos];
}

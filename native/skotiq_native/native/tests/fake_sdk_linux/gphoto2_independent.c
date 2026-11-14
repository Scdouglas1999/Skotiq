/*
 * An independent fake libgphoto2, written from libgphoto2 2.5.34 (the headers in
 * /usr/include/gphoto2 and the sources of libgphoto2/gphoto2-widget.c,
 * gphoto2-abilities-list.c, gphoto2-camera.c and camlibs/ptp2/{config.c,library.c})
 * and the INDI gphoto driver, separately from the Skotiq driver and from
 * tests/fake_sdk/gphoto2.rs.
 *
 * It models the parts of libgphoto2 a capture program sees:
 * - gp_camera_autodetect lists "<Maker> <model>" (the abilities model with its
 *   first ':' replaced by a space, gphoto2-abilities-list.c:540) and a "usb:BBB,DDD"
 *   port; gp_abilities_list_lookup_model matches case-insensitively; a camera is
 *   opened on the port given with gp_camera_set_port_info, else the first one.
 * - widgets: gp_widget_get_value hands a char* for TEXT/RADIO/MENU, an int for
 *   TOGGLE/DATE, a float for RANGE; gp_widget_set_value marks a widget changed only
 *   when the value differs (gphoto2-widget.c:385-424); gp_camera_set_config applies
 *   only changed widgets.
 * - Canon EOS: shutterspeed "bulb","30","1/4000" (canon_shutterspeed); iso "Auto"
 *   and numbers; eosremoterelease with the 2.5.34 choices ("Press Full MF" ..
 *   "Release"), whose "None" does nothing; capturetarget "Internal RAM" /
 *   "Memory card" (capturetargets); RAM captures are "/capt0000.cr2", deleting a
 *   "capt" file is a no-op (library.c delete_file_func).
 * - Nikon: shutterspeed2 "1/250","30","Bulb","Time","x 200"; shutterspeed
 *   "0.0040s"; longexpnr "Off"/"On"; bulb toggle.
 * - gp_camera_capture waits the shutter time and answers the first file; for
 *   RAW+JPEG the other file follows as GP_EVENT_FILE_ADDED (library.c: "for RAW+JPG
 *   mode capture, we just return the first image").
 * - gp_camera_wait_for_event hands a malloc'd CameraFilePath for FILE_ADDED and
 *   leaves eventdata unchanged on timeout.
 * - a raw file is a small DNG whose EXIF ExposureTime and ISO are what the fake
 *   camera did (timed speed, or the time the bulb shutter was held open).
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define GP_OK 0
#define GP_ERROR -1
#define GP_ERROR_BAD_PARAMETERS -2
#define GP_ERROR_UNKNOWN_PORT -5
#define GP_ERROR_NOT_SUPPORTED -6
#define GP_ERROR_IO_USB_FIND -52
#define GP_ERROR_MODEL_NOT_FOUND -105
#define GP_ERROR_FILE_NOT_FOUND -108
#define GP_ERROR_CAMERA_BUSY -110

enum { W_WINDOW, W_SECTION, W_TEXT, W_RANGE, W_TOGGLE, W_RADIO, W_MENU, W_BUTTON, W_DATE };
enum { EV_UNKNOWN, EV_TIMEOUT, EV_FILE_ADDED, EV_FOLDER_ADDED, EV_CAPTURE_COMPLETE, EV_FILE_CHANGED };

typedef struct { char name[128]; char folder[1024]; } CameraFilePath;

typedef struct {
    char model[128]; int status; int port; int speed[64]; int operations; int file_operations;
    int folder_operations; int usb_vendor, usb_product, usb_class, usb_subclass, usb_protocol;
    char library[1024]; char id[1024]; int device_type; int reserved[7];
} CameraAbilities;

/* ---------------------------------------------------------------- log */
static char LOG[1 << 16];
static void logf_(const char *fmt, ...) {
    size_t len = strlen(LOG);
    if (len > sizeof(LOG) - 512) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(LOG + len, sizeof(LOG) - len, fmt, ap);
    va_end(ap);
    strcat(LOG, "\n");
}

static double now_s(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

/* ---------------------------------------------------------------- widgets */
typedef struct W {
    char *name, *label;
    int type;
    char *sval;
    int ival;
    float fval;
    char *choices[96];
    int nchoices;
    struct W *children[48];
    int nchildren;
    int changed;
} W;

static W *wnew(int type, const char *name, const char *label) {
    W *w = calloc(1, sizeof(W));
    w->type = type;
    w->name = strdup(name);
    w->label = strdup(label);
    return w;
}
static void wadd(W *parent, W *child) { parent->children[parent->nchildren++] = child; }
static void wchoice(W *w, const char *c) { w->choices[w->nchoices++] = strdup(c); }
static void wsets(W *w, const char *v) { free(w->sval); w->sval = v ? strdup(v) : NULL; }
static W *wradio(W *parent, const char *name, const char *label, const char **choices, const char *value) {
    W *w = wnew(W_RADIO, name, label);
    for (; *choices; choices++) wchoice(w, *choices);
    wsets(w, value);
    wadd(parent, w);
    return w;
}
static W *wtext(W *parent, const char *name, const char *label, const char *value) {
    W *w = wnew(W_TEXT, name, label);
    wsets(w, value);
    wadd(parent, w);
    return w;
}
static void wfree(W *w) {
    if (!w) return;
    for (int i = 0; i < w->nchildren; i++) wfree(w->children[i]);
    for (int i = 0; i < w->nchoices; i++) free(w->choices[i]);
    free(w->name); free(w->label); free(w->sval); free(w);
}
static W *wfind(W *w, const char *name) {
    if (!strcmp(w->name, name)) return w;
    for (int i = 0; i < w->nchildren; i++) { W *f = wfind(w->children[i], name); if (f) return f; }
    return NULL;
}
static int whas_choice(W *w, const char *v) {
    for (int i = 0; i < w->nchoices; i++) if (!strcmp(w->choices[i], v)) return 1;
    return 0;
}

int gp_widget_get_child_by_name(W *w, const char *name, W **child) {
    if (!w || !name || !child) return GP_ERROR_BAD_PARAMETERS;
    for (int i = 0; i < w->nchildren; i++) {
        W *f = wfind(w->children[i], name);
        if (f) { *child = f; return GP_OK; }
    }
    return GP_ERROR_BAD_PARAMETERS;
}
int gp_widget_get_type(W *w, int *t) { *t = w->type; return GP_OK; }
int gp_widget_get_name(W *w, const char **n) { *n = w->name; return GP_OK; }
int gp_widget_get_label(W *w, const char **l) { *l = w->label; return GP_OK; }
int gp_widget_count_children(W *w) { return w->nchildren; }
int gp_widget_get_child(W *w, int i, W **c) {
    if (i < 0 || i >= w->nchildren) return GP_ERROR_BAD_PARAMETERS;
    *c = w->children[i];
    return GP_OK;
}
int gp_widget_get_value(W *w, void *value) {
    switch (w->type) {
    case W_TEXT: case W_RADIO: case W_MENU: *(char **)value = w->sval; return GP_OK;
    case W_TOGGLE: case W_DATE: *(int *)value = w->ival; return GP_OK;
    case W_RANGE: *(float *)value = w->fval; return GP_OK;
    default: return GP_ERROR_BAD_PARAMETERS;
    }
}
int gp_widget_set_value(W *w, const void *value) {
    if (!w || !value) return GP_ERROR_BAD_PARAMETERS;
    switch (w->type) {
    case W_TEXT: case W_RADIO: case W_MENU:
        if (!w->sval || strcmp(w->sval, (const char *)value)) w->changed = 1;
        wsets(w, (const char *)value);
        return GP_OK;
    case W_TOGGLE: case W_DATE:
        if (w->ival != *(const int *)value) { w->ival = *(const int *)value; w->changed = 1; }
        return GP_OK;
    case W_RANGE:
        if (w->fval != *(const float *)value) { w->fval = *(const float *)value; w->changed = 1; }
        return GP_OK;
    default: return GP_ERROR_BAD_PARAMETERS;
    }
}
int gp_widget_count_choices(W *w) { return w->nchoices; }
int gp_widget_get_choice(W *w, int i, const char **c) {
    if (i < 0 || i >= w->nchoices) return GP_ERROR_BAD_PARAMETERS;
    *c = w->choices[i];
    return GP_OK;
}
int gp_widget_get_range(W *w, float *min, float *max, float *inc) { *min = 0; *max = 0; *inc = 0; (void)w; return GP_OK; }
int gp_widget_free(W *w) { wfree(w); return GP_OK; }

/* ---------------------------------------------------------------- cameras */
typedef struct { CameraFilePath path; int raw; double exposure; int iso; } File;

typedef struct {
    char maker[16];     /* canon | nikon */
    char model[128];    /* abilities model, "Canon:EOS 6D" */
    char port[64];
    char serial[32];
    /* settings as the body holds them */
    char iso[16];
    char shutter[16];
    char format[48];
    char target[16];    /* "Internal RAM" | "Memory card" | "" (no widget) */
    char longexpnr[8];  /* "" (no widget) | "On" | "Off" */
    int longexpnr_stuck;
    int jpeg_first;
    int no_bulb_choice; /* the mode dial is on a mode whose list has no bulb */
    int no_pure_raw;    /* the format list has RAW only paired with a JPEG */
    int capcnt;         /* SDRAM names count every object (library.c params->capcnt++) */
    /* bulb */
    double bulb_open;
    int bulb_is_open;
    /* storage and events */
    File files[64]; int nfiles;
    CameraFilePath events[64]; int nevents;
    int counter;
    int session_open;
} Body;

static Body BODIES[4];
static int NBODIES;
static int ATTACHED[4];

typedef struct { int body; int abilities_set; char want_model[128]; char want_port[64]; } Cam;

void fake_reset(void) {
    memset(BODIES, 0, sizeof(BODIES));
    memset(ATTACHED, 0, sizeof(ATTACHED));
    NBODIES = 0;
    LOG[0] = 0;
}

int fake_add_camera(const char *maker, const char *model, const char *port) {
    Body *b = &BODIES[NBODIES];
    memset(b, 0, sizeof(*b));
    snprintf(b->maker, sizeof b->maker, "%s", maker);
    snprintf(b->model, sizeof b->model, "%s", model);
    snprintf(b->port, sizeof b->port, "%s", port);
    snprintf(b->serial, sizeof b->serial, "%s%d", "SN0000", NBODIES + 1);
    if (!strcmp(maker, "canon")) {
        strcpy(b->iso, "800");
        strcpy(b->shutter, "1/100");
        strcpy(b->format, "Large Fine JPEG");
        strcpy(b->target, "Internal RAM");
    } else {
        strcpy(b->iso, "800");
        strcpy(b->shutter, "1/100");
        strcpy(b->format, "JPEG Fine");
        strcpy(b->target, "Memory card");
        strcpy(b->longexpnr, "On");
    }
    ATTACHED[NBODIES] = 1;
    return NBODIES++;
}

/* fake_set(body, key, value): the body's own state, as its buttons would set it. */
int fake_set(int body, const char *key, const char *value) {
    Body *b = &BODIES[body];
    if (!strcmp(key, "iso")) snprintf(b->iso, sizeof b->iso, "%s", value);
    else if (!strcmp(key, "shutter")) snprintf(b->shutter, sizeof b->shutter, "%s", value);
    else if (!strcmp(key, "format")) snprintf(b->format, sizeof b->format, "%s", value);
    else if (!strcmp(key, "target")) snprintf(b->target, sizeof b->target, "%s", value);
    else if (!strcmp(key, "longexpnr")) snprintf(b->longexpnr, sizeof b->longexpnr, "%s", value);
    else if (!strcmp(key, "longexpnr_stuck")) b->longexpnr_stuck = atoi(value);
    else if (!strcmp(key, "jpeg_first")) b->jpeg_first = atoi(value);
    else if (!strcmp(key, "no_bulb_choice")) b->no_bulb_choice = atoi(value);
    else if (!strcmp(key, "no_pure_raw")) b->no_pure_raw = atoi(value);
    else if (!strcmp(key, "attached")) ATTACHED[body] = atoi(value);
    else if (!strcmp(key, "port")) snprintf(b->port, sizeof b->port, "%s", value);
    else return -1;
    return 0;
}

static char GETBUF[8192];
const char *fake_get(int body, const char *key) {
    Body *b = &BODIES[body];
    GETBUF[0] = 0;
    if (!strcmp(key, "iso")) return b->iso;
    if (!strcmp(key, "shutter")) return b->shutter;
    if (!strcmp(key, "format")) return b->format;
    if (!strcmp(key, "longexpnr")) return b->longexpnr;
    if (!strcmp(key, "files")) {
        for (int i = 0; i < b->nfiles; i++) {
            strcat(GETBUF, b->files[i].path.folder);
            strcat(GETBUF, "/");
            strcat(GETBUF, b->files[i].path.name);
            strcat(GETBUF, ";");
        }
        return GETBUF;
    }
    if (!strcmp(key, "bulb_open")) return b->bulb_is_open ? "1" : "0";
    return GETBUF;
}
const char *fake_log(void) { return LOG; }
void fake_clear_log(void) { LOG[0] = 0; }

static const char *maker_name(Body *b) { return !strcmp(b->maker, "canon") ? "Canon Inc." : "Nikon Corporation"; }

/* The detected model: the abilities model with its first ':' made a space. */
static void detected_model(Body *b, char *out, size_t n) {
    snprintf(out, n, "%s", b->model);
    char *c = strchr(out, ':');
    if (c) *c = ' ';
}

/* ---------------------------------------------------------------- files */
static int is_bulb(Body *b) { return !strcasecmp(b->shutter, "bulb"); }

static double shutter_value(const char *s) {
    int num, den;
    if (sscanf(s, "%d/%d", &num, &den) == 2 && den) return (double)num / den;
    double v = strtod(s, NULL);
    return v;
}

static int wants_raw(Body *b) { return strstr(b->format, "RAW") || strstr(b->format, "NEF"); }
static int wants_jpeg(Body *b) { return !wants_raw(b) || strchr(b->format, '+'); }

static void add_file(Body *b, int raw, double exposure, CameraFilePath *out) {
    File *f = &b->files[b->nfiles++];
    memset(f, 0, sizeof(*f));
    int ram = !strcmp(b->target, "Internal RAM");
    int canon = !strcmp(b->maker, "canon");
    if (ram) {
        strcpy(f->path.folder, "/");
        snprintf(f->path.name, sizeof f->path.name, "capt%04d.%s", b->capcnt++, raw ? (canon ? "cr2" : "nef") : "jpg");
    } else {
        strcpy(f->path.folder, canon ? "/store_00020001/DCIM/100CANON" : "/store_00010001/DCIM/100D850_");
        snprintf(f->path.name, sizeof f->path.name, "%s_%04d.%s", canon ? "IMG" : "DSC", b->counter + 1,
                 raw ? (canon ? "CR2" : "NEF") : "JPG");
    }
    f->raw = raw;
    f->exposure = exposure;
    f->iso = atoi(b->iso);
    if (out) *out = f->path;
}

/* The files of one exposure; the first is answered, the rest become events. */
static void make_exposure(Body *b, double exposure, CameraFilePath *first, int all_as_events) {
    int raw = wants_raw(b), jpeg = wants_jpeg(b);
    CameraFilePath paths[2];
    int n = 0;
    if (raw && jpeg && b->jpeg_first) { add_file(b, 0, exposure, &paths[n++]); add_file(b, 1, exposure, &paths[n++]); }
    else {
        if (raw) add_file(b, 1, exposure, &paths[n++]);
        if (jpeg) add_file(b, 0, exposure, &paths[n++]);
    }
    b->counter++;
    for (int i = 0; i < n; i++) {
        if (i == 0 && !all_as_events && first) *first = paths[0];
        else b->events[b->nevents++] = paths[i];
    }
}

/* ---------------------------------------------------------------- config tree */
static const char *CANON_ISO[] = {"Auto", "100", "125", "160", "200", "250", "320", "400", "500", "640", "800",
                                  "1000", "1250", "1600", "2000", "2500", "3200", "4000", "5000", "6400",
                                  "8000", "10000", "12800", "25600", NULL};
static const char *CANON_SHUTTER[] = {"bulb", "30", "25", "20", "15", "13", "10", "8", "6", "5", "4", "3.2", "2.5",
                                      "2", "1.6", "1.3", "1", "0.8", "0.6", "0.5", "0.4", "0.3", "1/4", "1/5",
                                      "1/6", "1/8", "1/10", "1/13", "1/15", "1/20", "1/25", "1/30", "1/40",
                                      "1/50", "1/60", "1/80", "1/100", "1/125", "1/160", "1/200", "1/250",
                                      "1/320", "1/400", "1/500", "1/640", "1/800", "1/1000", "1/1250",
                                      "1/1600", "1/2000", "1/2500", "1/3200", "1/4000", NULL};
static const char *CANON_FORMAT[] = {"Large Fine JPEG", "Large Normal JPEG", "Medium Fine JPEG", "Small Fine JPEG",
                                     "RAW + Large Fine JPEG", "RAW", NULL};
static const char *CANON_REMOTE[] = {"None", "Press Half AF", "Press Full AF", "Press Half MF", "Press Full MF",
                                     "Release Half", "Release Full", "Release", NULL};
static const char *TARGETS[] = {"Internal RAM", "Memory card", NULL};
static const char *NIKON_ISO[] = {"64", "80", "100", "125", "160", "200", "250", "320", "400", "500", "640",
                                  "800", "1000", "1250", "1600", "3200", "6400", "12800", "25600", NULL};
static const char *NIKON_SHUTTER2[] = {"1/8000", "1/4000", "1/2000", "1/1000", "1/500", "1/250", "1/125", "1/100",
                                       "1/60", "1/30", "1/15", "1/8", "1/4", "1/2", "10/13", "1", "13/10", "2",
                                       "4", "8", "15", "30", "Bulb", "Time", "x 200", NULL};
static const char *NIKON_FORMAT[] = {"JPEG Basic", "JPEG Normal", "JPEG Fine", "NEF (Raw)", "NEF+Basic",
                                     "NEF+Normal", "NEF+Fine", NULL};
static const char *ONOFF[] = {"Off", "On", NULL};

static W *build_tree(Body *b) {
    W *root = wnew(W_WINDOW, "main", "Camera and Driver Configuration");
    W *actions = wnew(W_SECTION, "actions", "Camera Actions");
    W *settings = wnew(W_SECTION, "settings", "Camera Settings");
    W *status = wnew(W_SECTION, "status", "Camera Status Information");
    W *img = wnew(W_SECTION, "imgsettings", "Image Settings");
    W *cap = wnew(W_SECTION, "capturesettings", "Capture Settings");
    wadd(root, actions); wadd(root, settings); wadd(root, status); wadd(root, img); wadd(root, cap);
    int canon = !strcmp(b->maker, "canon");
    char model[128];
    detected_model(b, model, sizeof model);

    W *bulb = wnew(W_TOGGLE, "bulb", "Bulb Mode");
    bulb->ival = b->bulb_is_open;
    wadd(actions, bulb);
    if (canon) wradio(actions, "eosremoterelease", "Canon EOS Remote Release", CANON_REMOTE, "None");

    if (b->target[0]) wradio(settings, "capturetarget", "Capture Target", TARGETS, b->target);
    wtext(status, "serialnumber", "Serial Number", b->serial);
    wtext(status, "manufacturer", "Camera Manufacturer", maker_name(b));
    wtext(status, "cameramodel", "Camera Model", model + strlen(canon ? "Canon " : "Nikon "));
    wtext(status, "batterylevel", "Battery Level", "100%");

    wradio(img, "iso", "ISO Speed", canon ? CANON_ISO : NIKON_ISO, b->iso);
    W *format = wradio(img, canon ? "imageformat" : "imagequality", canon ? "Image Format" : "Image Quality",
                       canon ? CANON_FORMAT : NIKON_FORMAT, b->format);
    if (b->no_pure_raw) format->nchoices--; /* the last choice is the pure RAW one */

    if (canon) {
        W *s = wnew(W_RADIO, "shutterspeed", "Shutter Speed");
        for (const char **c = CANON_SHUTTER; *c; c++)
            if (!(b->no_bulb_choice && !strcmp(*c, "bulb"))) wchoice(s, *c);
        wsets(s, b->shutter);
        wadd(cap, s);
    } else {
        W *s2 = wnew(W_RADIO, "shutterspeed2", "Shutter Speed 2");
        for (const char **c = NIKON_SHUTTER2; *c; c++)
            if (!(b->no_bulb_choice && !strcmp(*c, "Bulb"))) wchoice(s2, *c);
        wsets(s2, b->shutter);
        wadd(cap, s2);
        /* _get_ExpTime: "%0.4fs" of the 1/10000 s value. */
        W *s = wnew(W_RADIO, "shutterspeed", "Shutter Speed");
        char buf[32];
        for (const char **c = NIKON_SHUTTER2; *c; c++) {
            if (!strcmp(*c, "Bulb") || !strcmp(*c, "Time") || !strcmp(*c, "x 200")) {
                if (!strcmp(*c, "x 200")) continue;
                if (b->no_bulb_choice && !strcmp(*c, "Bulb")) continue;
                wchoice(s, *c);
                continue;
            }
            snprintf(buf, sizeof buf, "%0.4fs", shutter_value(*c));
            wchoice(s, buf);
        }
        if (is_bulb(b)) wsets(s, "Bulb");
        else { snprintf(buf, sizeof buf, "%0.4fs", shutter_value(b->shutter)); wsets(s, buf); }
        wadd(cap, s);
        if (b->longexpnr[0]) wradio(cap, "longexpnr", "Long Exp Noise Reduction", ONOFF, b->longexpnr);
    }
    return root;
}

/* ---------------------------------------------------------------- context, lists */
typedef struct { int dummy; } Ctx;
void *gp_context_new(void) { return calloc(1, sizeof(Ctx)); }
void gp_context_unref(void *c) { free(c); }

typedef struct { char *name[16]; char *value[16]; int n; } List;
int gp_list_new(List **l) { *l = calloc(1, sizeof(List)); return GP_OK; }
int gp_list_count(List *l) { return l->n; }
int gp_list_get_name(List *l, int i, const char **n) { if (i >= l->n) return GP_ERROR_BAD_PARAMETERS; *n = l->name[i]; return GP_OK; }
int gp_list_get_value(List *l, int i, const char **v) { if (i >= l->n) return GP_ERROR_BAD_PARAMETERS; *v = l->value[i]; return GP_OK; }
int gp_list_free(List *l) {
    for (int i = 0; i < l->n; i++) { free(l->name[i]); free(l->value[i]); }
    free(l);
    return GP_OK;
}

typedef struct { CameraAbilities a[16]; int n; } AbList;
int gp_abilities_list_new(AbList **l) { *l = calloc(1, sizeof(AbList)); return GP_OK; }
int gp_abilities_list_load(AbList *l, void *ctx) {
    (void)ctx;
    const char *extra[] = {"Canon:EOS 600D", "Nikon:DSC D7500", "Directory Browse", NULL};
    for (int i = 0; i < NBODIES; i++) {
        memset(&l->a[l->n], 0, sizeof(CameraAbilities));
        detected_model(&BODIES[i], l->a[l->n].model, 128);
        strcpy(l->a[l->n].library, "ptp2");
        l->a[l->n].operations = 1 | 8 | 16 | 32;
        l->n++;
    }
    for (const char **e = extra; *e; e++) {
        memset(&l->a[l->n], 0, sizeof(CameraAbilities));
        snprintf(l->a[l->n].model, 128, "%s", *e);
        char *c = strchr(l->a[l->n].model, ':');
        if (c) *c = ' ';
        l->a[l->n].operations = 1 | 8 | 16 | 32;
        l->n++;
    }
    return GP_OK;
}
int gp_abilities_list_lookup_model(AbList *l, const char *model) {
    for (int i = 0; i < l->n; i++) if (!strcasecmp(l->a[i].model, model)) return i;
    logf_("lookup_model(%s) not found", model);
    return GP_ERROR_MODEL_NOT_FOUND;
}
int gp_abilities_list_get_abilities(AbList *l, int i, CameraAbilities *a) {
    if (i < 0 || i >= l->n) return GP_ERROR_BAD_PARAMETERS;
    *a = l->a[i];
    return GP_OK;
}
int gp_abilities_list_free(AbList *l) { free(l); return GP_OK; }

typedef struct { char path[64]; } PortInfo;
typedef struct { PortInfo p[16]; int n; } PortList;
int gp_port_info_list_new(PortList **l) { *l = calloc(1, sizeof(PortList)); return GP_OK; }
int gp_port_info_list_load(PortList *l) {
    for (int i = 0; i < NBODIES; i++) if (ATTACHED[i]) snprintf(l->p[l->n++].path, 64, "%s", BODIES[i].port);
    snprintf(l->p[l->n++].path, 64, "usb:");
    return GP_OK;
}
int gp_port_info_list_lookup_path(PortList *l, const char *path) {
    for (int i = 0; i < l->n; i++) if (!strcmp(l->p[i].path, path)) return i;
    return GP_ERROR_UNKNOWN_PORT;
}
int gp_port_info_list_get_info(PortList *l, int i, PortInfo **info) {
    if (i < 0 || i >= l->n) return GP_ERROR_BAD_PARAMETERS;
    *info = &l->p[i];
    return GP_OK;
}
int gp_port_info_list_free(PortList *l) { free(l); return GP_OK; }

int gp_camera_autodetect(List *l, void *ctx) {
    (void)ctx;
    for (int i = 0; i < NBODIES; i++) {
        if (!ATTACHED[i]) continue;
        char model[128];
        detected_model(&BODIES[i], model, sizeof model);
        l->name[l->n] = strdup(model);
        l->value[l->n] = strdup(BODIES[i].port);
        l->n++;
    }
    return l->n;
}

/* ---------------------------------------------------------------- camera */
int gp_camera_new(Cam **c) { *c = calloc(1, sizeof(Cam)); (*c)->body = -1; return GP_OK; }
int gp_camera_set_abilities(Cam *c, CameraAbilities a) {
    snprintf(c->want_model, sizeof c->want_model, "%s", a.model);
    c->abilities_set = 1;
    return GP_OK;
}
int gp_camera_set_port_info(Cam *c, PortInfo *p) {
    snprintf(c->want_port, sizeof c->want_port, "%s", p->path);
    return GP_OK;
}
int gp_camera_init(Cam *c, void *ctx) {
    (void)ctx;
    int found = -1;
    for (int i = 0; i < NBODIES; i++) {
        if (!ATTACHED[i]) continue;
        if (c->want_port[0] && strcmp(BODIES[i].port, c->want_port)) continue;
        found = i;
        break;
    }
    logf_("init model='%s' port='%s' -> %d", c->want_model, c->want_port, found);
    if (found < 0) return GP_ERROR_IO_USB_FIND;
    char model[128];
    detected_model(&BODIES[found], model, sizeof model);
    if (c->abilities_set && strcasecmp(model, c->want_model)) {
        logf_("init: camlib for '%s' opened a '%s'", c->want_model, model);
    }
    c->body = found;
    BODIES[found].session_open = 1;
    return GP_OK;
}
static Body *body_of(Cam *c) { return c && c->body >= 0 && ATTACHED[c->body] ? &BODIES[c->body] : NULL; }
int gp_camera_exit(Cam *c, void *ctx) {
    (void)ctx;
    if (c && c->body >= 0) { BODIES[c->body].session_open = 0; logf_("exit"); }
    return GP_OK;
}
int gp_camera_free(Cam *c) { free(c); return GP_OK; }
int gp_camera_unref(Cam *c) { free(c); return GP_OK; }
int gp_camera_get_abilities(Cam *c, CameraAbilities *a) {
    Body *b = body_of(c);
    if (!b) return GP_ERROR_IO_USB_FIND;
    memset(a, 0, sizeof(*a));
    detected_model(b, a->model, 128);
    a->operations = 1 | 8 | 16 | 32;
    return GP_OK;
}
int gp_camera_get_summary(Cam *c, char *text, void *ctx) { (void)c; (void)ctx; strcpy(text, "fake"); return GP_OK; }

int gp_camera_get_config(Cam *c, W **root, void *ctx) {
    (void)ctx;
    Body *b = body_of(c);
    if (!b) return GP_ERROR_IO_USB_FIND;
    *root = build_tree(b);
    return GP_OK;
}

static int put_widget(Body *b, W *w) {
    if (!strcmp(w->name, "iso")) {
        if (!whas_choice(w, w->sval)) return GP_ERROR_BAD_PARAMETERS;
        snprintf(b->iso, sizeof b->iso, "%s", w->sval);
        logf_("set iso=%s", w->sval);
    } else if (!strcmp(w->name, "shutterspeed") || !strcmp(w->name, "shutterspeed2")) {
        if (!whas_choice(w, w->sval)) return GP_ERROR_BAD_PARAMETERS;
        if (!strcmp(w->name, "shutterspeed") && !strcmp(b->maker, "nikon")) {
            if (!strcmp(w->sval, "Bulb")) strcpy(b->shutter, "Bulb");
            else return GP_ERROR_NOT_SUPPORTED;
        } else snprintf(b->shutter, sizeof b->shutter, "%s", w->sval);
        logf_("set %s=%s", w->name, w->sval);
    } else if (!strcmp(w->name, "imageformat") || !strcmp(w->name, "imagequality")) {
        if (!whas_choice(w, w->sval)) return GP_ERROR_BAD_PARAMETERS;
        snprintf(b->format, sizeof b->format, "%s", w->sval);
        logf_("set %s=%s", w->name, w->sval);
    } else if (!strcmp(w->name, "capturetarget")) {
        snprintf(b->target, sizeof b->target, "%s", w->sval);
        logf_("set capturetarget=%s", w->sval);
    } else if (!strcmp(w->name, "longexpnr")) {
        if (!b->longexpnr_stuck) snprintf(b->longexpnr, sizeof b->longexpnr, "%s", w->sval);
        logf_("set longexpnr=%s", w->sval);
    } else if (!strcmp(w->name, "eosremoterelease")) {
        logf_("set eosremoterelease=%s", w->sval);
        if (!strcmp(w->sval, "None")) return GP_OK;
        if (!strncmp(w->sval, "Press Full", 10)) {
            if (is_bulb(b)) { b->bulb_open = now_s(); b->bulb_is_open = 1; }
            else make_exposure(b, shutter_value(b->shutter), NULL, 1);
        } else if (!strcmp(w->sval, "Release") || !strcmp(w->sval, "Release Full")) {
            if (b->bulb_is_open) {
                b->bulb_is_open = 0;
                make_exposure(b, now_s() - b->bulb_open, NULL, 1);
            }
        } else if (strcmp(w->sval, "Release Half") && strcmp(w->sval, "Press Half AF") &&
                   strcmp(w->sval, "Press Half MF"))
            return GP_ERROR_NOT_SUPPORTED;
    } else if (!strcmp(w->name, "bulb")) {
        logf_("set bulb=%d", w->ival);
        if (w->ival && !b->bulb_is_open) {
            if (!is_bulb(b)) return GP_ERROR; /* a body not on bulb refuses */
            b->bulb_open = now_s();
            b->bulb_is_open = 1;
        } else if (!w->ival && b->bulb_is_open) {
            b->bulb_is_open = 0;
            make_exposure(b, now_s() - b->bulb_open, NULL, 1);
        }
    } else {
        logf_("set %s (read only here)", w->name);
    }
    return GP_OK;
}

static int apply_changed(Body *b, W *w) {
    if (w->changed) {
        int r = put_widget(b, w);
        w->changed = 0;
        if (r < GP_OK) return r;
    }
    for (int i = 0; i < w->nchildren; i++) {
        int r = apply_changed(b, w->children[i]);
        if (r < GP_OK) return r;
    }
    return GP_OK;
}

int gp_camera_set_config(Cam *c, W *root, void *ctx) {
    (void)ctx;
    Body *b = body_of(c);
    if (!b) return GP_ERROR_IO_USB_FIND;
    return apply_changed(b, root);
}

int gp_camera_capture(Cam *c, int type, CameraFilePath *path, void *ctx) {
    (void)ctx; (void)type;
    Body *b = body_of(c);
    if (!b) return GP_ERROR_IO_USB_FIND;
    if (is_bulb(b)) { logf_("capture refused: shutter on bulb"); return GP_ERROR; }
    double seconds = shutter_value(b->shutter);
    logf_("capture %s", b->shutter);
    usleep((useconds_t)(seconds * 1e6));
    make_exposure(b, seconds, path, 0);
    return GP_OK;
}
int gp_camera_trigger_capture(Cam *c, void *ctx) { (void)c; (void)ctx; return GP_ERROR_NOT_SUPPORTED; }
int gp_camera_capture_preview(Cam *c, void *file, void *ctx) { (void)c; (void)file; (void)ctx; return GP_ERROR_NOT_SUPPORTED; }

int gp_camera_wait_for_event(Cam *c, int timeout, int *type, void **data, void *ctx) {
    (void)ctx;
    Body *b = body_of(c);
    if (!b) return GP_ERROR_IO_USB_FIND;
    if (b->nevents > 0) {
        CameraFilePath *p = malloc(sizeof(CameraFilePath));
        *p = b->events[0];
        memmove(&b->events[0], &b->events[1], sizeof(CameraFilePath) * (b->nevents - 1));
        b->nevents--;
        *type = EV_FILE_ADDED;
        *data = p;
        logf_("event FILE_ADDED %s/%s", p->folder, p->name);
        return GP_OK;
    }
    usleep((useconds_t)(timeout > 50 ? 50 : timeout) * 1000);
    *type = EV_TIMEOUT;
    return GP_OK;
}

/* ---------------------------------------------------------------- files */
typedef struct { unsigned char *data; unsigned long size; } GFile;
int gp_file_new(GFile **f) { *f = calloc(1, sizeof(GFile)); return GP_OK; }
int gp_file_free(GFile *f) { if (f) { free(f->data); free(f); } return GP_OK; }
int gp_file_unref(GFile *f) { return gp_file_free(f); }
int gp_file_get_data_and_size(GFile *f, const char **data, unsigned long *size) {
    *data = (const char *)f->data;
    *size = f->size;
    return GP_OK;
}

/* A little-endian DNG: 64x48 RGGB, 16-bit, with EXIF ExposureTime and ISO. */
typedef struct { unsigned char *p; size_t n, cap; } Buf;
static void put(Buf *b, const void *d, size_t n) {
    if (b->n + n > b->cap) { b->cap = (b->n + n) * 2; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->n, d, n);
    b->n += n;
}
static void put16(Buf *b, uint16_t v) { put(b, &v, 2); }
static void put32(Buf *b, uint32_t v) { put(b, &v, 4); }

typedef struct { uint16_t tag, type; uint32_t count, value; } Entry;

static void write_ifd(Buf *b, Entry *e, int n, size_t *next_at) {
    put16(b, (uint16_t)n);
    for (int i = 0; i < n; i++) { put16(b, e[i].tag); put16(b, e[i].type); put32(b, e[i].count); put32(b, e[i].value); }
    *next_at = b->n;
    put32(b, 0);
}

static void make_dng(File *f, Body *b, unsigned char **out, unsigned long *size) {
    const int W = 64, H = 48;
    Buf buf = {0};
    put(&buf, "II*\0", 4);
    put32(&buf, 8);
    char model[128];
    detected_model(b, model, sizeof model);
    const char *make = !strcmp(b->maker, "canon") ? "Canon" : "NIKON CORPORATION";
    /* IFD0 at 8, the EXIF IFD after it, then the strings, the exposure and the pixels. */
    const int n0 = 17, ne = 2;
    size_t ifd0_size = 2 + n0 * 12 + 4, exif_size = 2 + ne * 12 + 4;
    size_t blob_at = 8 + ifd0_size + exif_size;
    Buf data = {0};
    uint32_t make_at = (uint32_t)(blob_at + data.n); put(&data, make, strlen(make) + 1); if (data.n & 1) put(&data, "", 1);
    uint32_t model_at = (uint32_t)(blob_at + data.n); put(&data, model, strlen(model) + 1); if (data.n & 1) put(&data, "", 1);
    uint32_t expo_at = (uint32_t)(blob_at + data.n);
    uint32_t num, den;
    if (f->exposure >= 0.1 || (1.0 / f->exposure) != (double)(uint32_t)(1.0 / f->exposure + 0.5)) {
        num = (uint32_t)(f->exposure * 100000.0 + 0.5);
        den = 100000;
    } else {
        num = 1;
        den = (uint32_t)(1.0 / f->exposure + 0.5);
    }
    put(&data, &num, 4); put(&data, &den, 4);
    uint32_t pixels_at = (uint32_t)(blob_at + data.n);
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) { uint16_t v = (uint16_t)(1000 + ((x + y) % 7) * 10); put(&data, &v, 2); }
    uint32_t exif_at = (uint32_t)(8 + ifd0_size);
    Entry e0[] = {
        {254, 4, 1, 0},
        {256, 4, 1, (uint32_t)W},
        {257, 4, 1, (uint32_t)H},
        {258, 3, 1, 16},
        {259, 3, 1, 1},
        {262, 3, 1, 32803},
        {271, 2, (uint32_t)strlen(make) + 1, make_at},
        {272, 2, (uint32_t)strlen(model) + 1, model_at},
        {273, 4, 1, pixels_at},
        {277, 3, 1, 1},
        {278, 4, 1, (uint32_t)H},
        {279, 4, 1, (uint32_t)(W * H * 2)},
        {284, 3, 1, 1},
        {33421, 3, 2, 2 | (2u << 16)},
        {33422, 1, 4, 0 | (1u << 8) | (1u << 16) | (2u << 24)},
        {34665, 4, 1, exif_at},
        {50706, 1, 4, 1 | (4u << 8)},
    };
    size_t next;
    write_ifd(&buf, e0, n0, &next);
    Entry ee[] = {
        {33434, 5, 1, expo_at},
        {34855, 3, 1, (uint32_t)f->iso},
    };
    write_ifd(&buf, ee, ne, &next);
    put(&buf, data.p, data.n);
    free(data.p);
    *out = buf.p;
    *size = buf.n;
}

static File *find_file(Body *b, const char *folder, const char *name) {
    for (int i = 0; i < b->nfiles; i++)
        if (!strcmp(b->files[i].path.folder, folder) && !strcmp(b->files[i].path.name, name)) return &b->files[i];
    return NULL;
}

int gp_camera_file_get(Cam *c, const char *folder, const char *name, int type, GFile *file, void *ctx) {
    (void)ctx;
    Body *b = body_of(c);
    if (!b) return GP_ERROR_IO_USB_FIND;
    File *f = find_file(b, folder, name);
    logf_("file_get %s/%s type %d%s", folder, name, type, f ? "" : " (missing)");
    if (!f) return GP_ERROR_FILE_NOT_FOUND;
    if (f->raw) make_dng(f, b, &file->data, &file->size);
    else {
        static const unsigned char jpeg[] = {0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9};
        file->data = malloc(sizeof jpeg);
        memcpy(file->data, jpeg, sizeof jpeg);
        file->size = sizeof jpeg;
    }
    return GP_OK;
}

int gp_camera_file_delete(Cam *c, const char *folder, const char *name, void *ctx) {
    (void)ctx;
    Body *b = body_of(c);
    if (!b) return GP_ERROR_IO_USB_FIND;
    logf_("file_delete %s/%s", folder, name);
    File *f = find_file(b, folder, name);
    if (!f) return !strncmp(name, "capt", 4) ? GP_OK : GP_ERROR_FILE_NOT_FOUND;
    *f = b->files[--b->nfiles];
    return GP_OK;
}

static const char *VERSION[] = {"2.5.34-independent-fake", NULL};
const char **gp_library_version(int verbose) { (void)verbose; return VERSION; }

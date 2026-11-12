/*
 * An independent model of libfli, written from the vendor sources only
 * (libfli as indi-3rdparty ships it: libfli.h, libfli.c, libfli-camera.c,
 * libfli-camera-usb.c, libfli-filter-focuser.c, unix/libusb/libfli-usb-sys.c).
 * Every behavior below cites the line it models. Built as libfli.so; the driver
 * finds it through LD_LIBRARY_PATH.
 *
 * Calls are appended to $FLI_MODEL_LOG, one per line, as "Name arg arg ...".
 * $FLI_MODEL_FAIL_ROW=<n> makes FLIGrabRow fail with -EIO on row n (0-based) of
 * every frame. tests/fli_libfli_model.rs runs the FLI drivers against it.
 *
 * Devices (FLIList via FLICreateList/FLIListFirst/FLIListNext, "file;model"):
 *   camera  "FLI-0101"      ProLine PL09000: status register, visible area
 *                           (20,4)-(3076,3060), pixel 12e-6 m, cooler power %.
 *   camera  "FLI-0102"      MaxCam with param-less knowndev table entry
 *                           KAF-1300: status UNKNOWN (all ones), visible
 *                           (4,2)-(1284,1026), pixel 20.0 (microns, table),
 *                           FLIGetCoolerPower -EFAULT.
 *   camera  "/dev/fliusb0"  MaxCam knowndev CCD47-10: pixel 0.0 (table row 15),
 *                           visible (8,0)-(1064,1027), status UNKNOWN.
 *   focuser "FLI-0201"      extent 7000, position 3000, no external probe.
 *   wheel   "FLI-0301"      CFW-1-7, 7 slots, position -1 until first move.
 *   wheel   "FLI-0302"      CFW-4-5 (newer firmware reads the slot from the
 *                           wheel, libfli-filter-focuser.c:1683): 5 slots,
 *                           FLI_FILTER_POSITION_UNKNOWN (0xff) until moved.
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

typedef long flidev_t;
typedef long flidomain_t;

#define FLIDOMAIN_USB 0x02
#define FLIDEVICE_CAMERA 0x100
#define FLIDEVICE_FILTERWHEEL 0x200
#define FLIDEVICE_FOCUSER 0x300
#define FLIDOMAIN_DEVICE_MASK 0x0f00

static void logf_(const char *fmt, ...) {
  const char *p = getenv("FLI_MODEL_LOG");
  if (!p) return;
  FILE *f = fopen(p, "a");
  if (!f) return;
  va_list ap;
  va_start(ap, fmt);
  vfprintf(f, fmt, ap);
  va_end(ap);
  fputc('\n', f);
  fclose(f);
}

static double now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

enum kind { PROLINE, MAXCAM, FOCUSER, WHEEL };

struct device {
  const char *file;
  const char *model;
  const char *serial;
  long type;
  enum kind kind;
  /* camera */
  long vis[4];
  double pixel;
  long hbin, vbin;
  long area[4];
  int area_set;
  unsigned long exposure_ms;
  long frame_type;
  double expose_start; /* < 0: none */
  long rows_read;
  double setpoint;
  /* focuser */
  long position, extent, target;
  double move_start;
  /* wheel */
  long slot, slots;
};

static struct device devices[] = {
  {"FLI-0101", "PL09000", "PL0123456", FLIDEVICE_CAMERA, PROLINE,
   {20, 4, 3076, 3060}, 12e-6, 1, 1, {0}, 0, 0, 0, -1, 0, 25.0},
  {"FLI-0102", "KAF-1300C0-2", "", FLIDEVICE_CAMERA, MAXCAM,
   {4, 2, 1284, 1026}, 20.0, 1, 1, {0}, 0, 0, 0, -1, 0, 25.0},
  {"/dev/fliusb0", "CCD47-10", "", FLIDEVICE_CAMERA, MAXCAM,
   {8, 0, 1064, 1027}, 0.0, 1, 1, {0}, 0, 0, 0, -1, 0, 25.0},
  {"FLI-0201", "PDF", "PDF0001", FLIDEVICE_FOCUSER, FOCUSER,
   {0}, 0, 0, 0, {0}, 0, 0, 0, -1, 0, 0, 3000, 7000, 3000, -1},
  {"FLI-0301", "CFW-1-7", "CFW0001", FLIDEVICE_FILTERWHEEL, WHEEL,
   {0}, 0, 0, 0, {0}, 0, 0, 0, -1, 0, 0, 0, 0, 0, -1, -1, 7},
  {"FLI-0302", "CFW-4-5", "CFW0002", FLIDEVICE_FILTERWHEEL, WHEEL,
   {0}, 0, 0, 0, {0}, 0, 0, 0, -1, 0, 0, 0, 0, 0, -1, 0xff, 5},
};
#define NDEV ((long)(sizeof(devices) / sizeof(devices[0])))
#define DEV(d) (&devices[(d)])
#define CHK(d)                                  \
  do {                                          \
    if ((d) < 0 || (d) >= NDEV) return -EINVAL; \
  } while (0)

/* libfli.h: FLIOpen(flidev_t *dev, char *name, flidomain_t domain). */
long FLIOpen(flidev_t *dev, char *name, flidomain_t domain) {
  logf_("FLIOpen %s 0x%lx", name, domain);
  for (long i = 0; i < NDEV; i++) {
    if (strcmp(devices[i].file, name) == 0 && (domain & 0x0f) == FLIDOMAIN_USB &&
        (domain & FLIDOMAIN_DEVICE_MASK) == devices[i].type) {
      *dev = i;
      return 0;
    }
  }
  return -ENODEV;
}

long FLIClose(flidev_t dev) {
  CHK(dev);
  logf_("FLIClose %s", DEV(dev)->file);
  return 0;
}

long FLIGetLibVersion(char *ver, size_t len) {
  snprintf(ver, len, "Software Development Library for Linux 1.104");
  return 0;
}

/* libfli.c FLIGetModel: snprintf, -EOVERFLOW when it does not fit. */
long FLIGetModel(flidev_t dev, char *model, size_t len) {
  CHK(dev);
  if ((size_t)snprintf(model, len, "%s", DEV(dev)->model) >= len) return -EOVERFLOW;
  return 0;
}

long FLIGetSerialString(flidev_t dev, char *serial, size_t len) {
  CHK(dev);
  snprintf(serial, len, "%s", DEV(dev)->serial);
  return 0;
}

/* libfli-camera.c:1255 copies cam->ccd.pixelwidth: meters from the ProLine
 * camera block (libfli-camera-usb.c:368), microns from the knowndev table
 * (libfli-camera.c:57). */
long FLIGetPixelSize(flidev_t dev, double *x, double *y) {
  CHK(dev);
  *x = *y = DEV(dev)->pixel;
  return 0;
}

long FLIGetVisibleArea(flidev_t dev, long *ulx, long *uly, long *lrx, long *lry) {
  CHK(dev);
  struct device *d = DEV(dev);
  *ulx = d->vis[0]; *uly = d->vis[1]; *lrx = d->vis[2]; *lry = d->vis[3];
  return 0;
}

long FLIGetArrayArea(flidev_t dev, long *ulx, long *uly, long *lrx, long *lry) {
  return FLIGetVisibleArea(dev, ulx, uly, lrx, lry);
}

/* libfli-camera.c:258 reads an unsigned long of milliseconds. */
long FLISetExposureTime(flidev_t dev, long exptime) {
  CHK(dev);
  logf_("FLISetExposureTime %ld", exptime);
  DEV(dev)->exposure_ms = (unsigned long)exptime;
  return 0;
}

/* libfli-camera-usb.c:630: negative ul is -EINVAL; the area is stored as given.
 * The frame is lr - ul pixels wide and lr - ul rows tall (libfli.c FLISetImageArea
 * lr' = ul + (lr - ul) / bin). */
long FLISetImageArea(flidev_t dev, long ulx, long uly, long lrx, long lry) {
  CHK(dev);
  struct device *d = DEV(dev);
  logf_("FLISetImageArea %ld %ld %ld %ld (bin %ldx%ld)", ulx, uly, lrx, lry, d->hbin, d->vbin);
  if (ulx < 0 || uly < 0) return -EINVAL;
  /* Model the sensor: the camera reads (lr - ul) * bin pixels from ul. */
  if (ulx + (lrx - ulx) * d->hbin > d->vis[2] || uly + (lry - uly) * d->vbin > d->vis[3])
    return -EINVAL;
  d->area[0] = ulx; d->area[1] = uly; d->area[2] = lrx; d->area[3] = lry;
  d->area_set = 1;
  return 0;
}

/* libfli-camera-usb.c:722 MaxCam 1..16, :736 ProLine 1..255. */
long FLISetHBin(flidev_t dev, long hbin) {
  CHK(dev);
  logf_("FLISetHBin %ld", hbin);
  long max = DEV(dev)->kind == PROLINE ? 255 : 16;
  if (hbin < 1 || hbin > max) return -EINVAL;
  DEV(dev)->hbin = hbin;
  return 0;
}

long FLISetVBin(flidev_t dev, long vbin) {
  CHK(dev);
  logf_("FLISetVBin %ld", vbin);
  long max = DEV(dev)->kind == PROLINE ? 255 : 16;
  if (vbin < 1 || vbin > max) return -EINVAL;
  DEV(dev)->vbin = vbin;
  return 0;
}

long FLISetFrameType(flidev_t dev, long frametype) {
  CHK(dev);
  logf_("FLISetFrameType %ld", frametype);
  DEV(dev)->frame_type = frametype;
  return 0;
}

/* FLI USB cameras answer FLISetBitDepth with -EINVAL (libfli-camera-usb.c:2247). */
long FLISetBitDepth(flidev_t dev, long depth) {
  CHK(dev);
  logf_("FLISetBitDepth %ld", depth);
  return -EINVAL;
}

static int fail_row(void) {
  const char *s = getenv("FLI_MODEL_FAIL_ROW");
  return s ? atoi(s) : -1;
}

long FLIExposeFrame(flidev_t dev) {
  CHK(dev);
  struct device *d = DEV(dev);
  logf_("FLIExposeFrame");
  if (!d->area_set) return -EINVAL;
  d->expose_start = now_ms();
  d->rows_read = 0;
  return 0;
}

long FLICancelExposure(flidev_t dev) {
  CHK(dev);
  logf_("FLICancelExposure");
  DEV(dev)->expose_start = -1;
  DEV(dev)->rows_read = 0;
  return 0;
}

long FLIEndExposure(flidev_t dev) {
  CHK(dev);
  logf_("FLIEndExposure");
  return 0;
}

static long remaining_ms(struct device *d) {
  if (d->expose_start < 0) return 0;
  double left = d->exposure_ms - (now_ms() - d->expose_start);
  return left > 0 ? (long)left : 0;
}

/* libfli-camera-usb.c:810: milliseconds left. */
long FLIGetExposureStatus(flidev_t dev, long *timeleft) {
  CHK(dev);
  *timeleft = remaining_ms(DEV(dev));
  return 0;
}

/* libfli.c:809 presets 0xffffffff (into a 64-bit long here); MaxCam leaves it
 * (libfli-camera-usb.c:2575); ProLine reads the 32-bit register (:2593).
 * Wheels/focusers: fli_getstepperstatus (libfli-filter-focuser.c:1279). */
long FLIGetDeviceStatus(flidev_t dev, long *status) {
  CHK(dev);
  struct device *d = DEV(dev);
  *status = 0xffffffff;
  switch (d->kind) {
    case MAXCAM:
      break;
    case PROLINE:
      if (d->expose_start >= 0 && remaining_ms(d) > 0)
        *status = 0x02; /* EXPOSING */
      else if (d->expose_start >= 0)
        *status = (long)0x80000000UL | 0x03; /* DATA_READY | READING_CCD */
      else
        *status = 0x00;
      break;
    case FOCUSER:
      *status = (d->position != d->target) ? 0x01 : 0x00;
      break;
    case WHEEL:
      *status = 0x00;
      break;
  }
  return 0;
}

/* libfli-camera-usb.c:1031: width larger than the area is truncated; 16-bit
 * pixels in host order. Each pixel holds (absolute sensor x + y) & 0xffff of
 * the first sensor pixel of its bin so the test can check the geometry; the
 * first pixel of row r is written separately as the absolute y. */
long FLIGrabRow(flidev_t dev, void *buff, size_t width) {
  CHK(dev);
  struct device *d = DEV(dev);
  long area_w = d->area[2] - d->area[0];
  long area_h = d->area[3] - d->area[1];
  if (d->expose_start < 0) return -EINVAL;
  if (d->rows_read >= area_h) return -EINVAL;
  if (d->rows_read == fail_row()) {
    logf_("FLIGrabRow fail %ld", d->rows_read);
    return -EIO;
  }
  if ((long)width > area_w) width = area_w;
  unsigned short *px = buff;
  long y = d->area[1] + d->rows_read * d->vbin;
  for (size_t i = 0; i < width; i++) {
    long x = d->area[0] + (long)i * d->hbin;
    px[i] = (unsigned short)(i == 0 ? y : x);
  }
  if (d->rows_read == 0) logf_("FLIGrabRow width %zu", width);
  d->rows_read++;
  if (d->rows_read == area_h) logf_("FLIGrabRow rows %ld", d->rows_read);
  return 0;
}

long FLISetTemperature(flidev_t dev, double t) {
  CHK(dev);
  logf_("FLISetTemperature %.2f", t);
  DEV(dev)->setpoint = t;
  return 0;
}

long FLIGetTemperature(flidev_t dev, double *t) {
  CHK(dev);
  *t = -5.5;
  return 0;
}

long FLIReadTemperature(flidev_t dev, long channel, double *t) {
  CHK(dev);
  logf_("FLIReadTemperature %ld", channel);
  if (DEV(dev)->kind == FOCUSER) return -EINVAL; /* numtempsensors == 0 */
  *t = -5.5;
  return 0;
}

/* libfli-camera-usb.c:2514: MaxCam -EFAULT, ProLine a PWM percentage. */
long FLIGetCoolerPower(flidev_t dev, double *power) {
  CHK(dev);
  *power = 0.0;
  if (DEV(dev)->kind == MAXCAM) return -EFAULT;
  *power = 42.0;
  return 0;
}

/* FLICreateList / FLIListFirst / FLIListNext (libfli.c:1645). */
static long list_domain = -1, list_pos = 0;
long FLICreateList(flidomain_t domain) {
  logf_("FLICreateList 0x%lx", domain);
  list_domain = domain;
  list_pos = 0;
  return 0;
}

long FLIDeleteList(void) {
  list_domain = -1;
  return 0;
}

static long list_step(flidomain_t *domain, char *file, size_t fl, char *name, size_t nl) {
  for (; list_pos < NDEV; list_pos++) {
    struct device *d = &devices[list_pos];
    if ((list_domain & FLIDOMAIN_DEVICE_MASK) == d->type && (list_domain & 0x0f) == FLIDOMAIN_USB) {
      *domain = list_domain;
      snprintf(file, fl, "%s", d->file);
      snprintf(name, nl, "%s", d->model);
      list_pos++;
      return 0;
    }
  }
  return -EINVAL;
}

long FLIListFirst(flidomain_t *domain, char *file, size_t fl, char *name, size_t nl) {
  list_pos = 0;
  return list_step(domain, file, fl, name, nl);
}

long FLIListNext(flidomain_t *domain, char *file, size_t fl, char *name, size_t nl) {
  return list_step(domain, file, fl, name, nl);
}

/* Focuser: relative signed steps (libfli-filter-focuser.c:926), 100 steps per
 * 10 ms in this model. */
static void focuser_update(struct device *d) {
  if (d->move_start < 0) return;
  long done = (long)((now_ms() - d->move_start) * 10.0);
  long dist = labs(d->target - d->position);
  if (done >= dist) {
    d->position = d->target;
    d->move_start = -1;
  }
}

static long focuser_current(struct device *d) {
  focuser_update(d);
  if (d->move_start < 0) return d->position;
  long done = (long)((now_ms() - d->move_start) * 10.0);
  return d->target > d->position ? d->position + done : d->position - done;
}

long FLIStepMotorAsync(flidev_t dev, long steps) {
  CHK(dev);
  struct device *d = DEV(dev);
  logf_("FLIStepMotorAsync %ld", steps);
  d->position = focuser_current(d);
  d->target = d->position + steps;
  d->move_start = now_ms();
  return 0;
}

long FLIStepMotor(flidev_t dev, long steps) {
  CHK(dev);
  struct device *d = DEV(dev);
  logf_("FLIStepMotor %ld", steps);
  d->position = focuser_current(d);
  if (steps == 0) { /* halt on old firmware (libfli-filter-focuser.c:940) */
    d->target = d->position;
    d->move_start = -1;
    return 0;
  }
  d->position += steps;
  d->target = d->position;
  d->move_start = -1;
  return 0;
}

long FLIGetStepperPosition(flidev_t dev, long *pos) {
  CHK(dev);
  *pos = focuser_current(DEV(dev));
  return 0;
}

long FLIGetStepsRemaining(flidev_t dev, long *steps) {
  CHK(dev);
  struct device *d = DEV(dev);
  *steps = labs(d->target - focuser_current(d));
  return 0;
}

long FLIGetFocuserExtent(flidev_t dev, long *extent) {
  CHK(dev);
  *extent = DEV(dev)->extent;
  return 0;
}

long FLIHomeFocuser(flidev_t dev) {
  CHK(dev);
  logf_("FLIHomeFocuser");
  DEV(dev)->position = DEV(dev)->target = 0;
  return 0;
}

/* Wheel: 0-based slots, blocking move, -1 before the first move on old wheels
 * (libfli-filter-focuser.c:216, :1683). */
long FLISetFilterPos(flidev_t dev, long filter) {
  CHK(dev);
  logf_("FLISetFilterPos %ld", filter);
  if (filter < 0 || filter >= DEV(dev)->slots) return -EINVAL;
  DEV(dev)->slot = filter;
  return 0;
}

long FLIGetFilterPos(flidev_t dev, long *filter) {
  CHK(dev);
  *filter = DEV(dev)->slot;
  return 0;
}

long FLIGetFilterCount(flidev_t dev, long *count) {
  CHK(dev);
  *count = DEV(dev)->slots;
  return 0;
}

long FLIGetFilterName(flidev_t dev, long filter, char *name, size_t len) {
  CHK(dev);
  memset(name, 0, len);
  static const char *names[] = {"L", "R", "G", "B", "Ha", "", "OIII"};
  if (filter < 0 || filter >= DEV(dev)->slots) return -EINVAL;
  snprintf(name, len, "%s", names[filter]);
  return 0;
}

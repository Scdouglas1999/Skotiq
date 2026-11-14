/* Every read of LibRaw's data structures happens in this file, compiled against
 * the headers of the LibRaw the crate links (build.rs picks them), so field
 * offsets always match the library at run time. The Rust side only sees
 * skotiq_raw_info_t, which this file defines and fills. */
#include "libraw_types.h"
#include <string.h>
#include <stddef.h>

/* Mirrors `RawInfoFfi` in raw.rs field for field. */
typedef struct skotiq_raw_info_t {
    char make[64];
    char model[64];
    char lens[128];
    float iso;
    float shutter;
    float aperture;
    float focal_length;
    long long timestamp;
    /* LibRaw's own "not recorded" value is -1000. */
    float sensor_temperature;
    float sensor_temperature2;
    float camera_temperature;
    int width;
    int height;
    int top_margin;
    int left_margin;
    int raw_width;
    int raw_height;
    int raw_bps;
    unsigned white_level;
    /* Smallest per-channel linear maximum the file records (0: none). */
    unsigned linear_max;
    unsigned filters;
    int colors;
    int dng_version;
    /* CFA colour letters at the visible origin, row-major: 2x2 for Bayer,
     * 6x6 for X-Trans; cfa_size is 2, 6, or 0 for no single-plane CFA. */
    int cfa_size;
    char cfa[36];
    /* Black level at each of those positions. */
    unsigned cfa_black[36];
    int has_mosaic;
} skotiq_raw_info_t;

/* Exported by LibRaw's C API (libraw.h, which the shim does not include):
 * the colour index of a visible (row, col). */
extern int libraw_COLOR(libraw_data_t *, int row, int col);

static void copy_text(char *dst, size_t dst_len, const char *src) {
    size_t n = strnlen(src, dst_len - 1);
    memcpy(dst, src, n);
    dst[n] = '\0';
}

/* LibRaw's black at a visible (row, col): a common level, a per-colour offset
 * (cblack[0..3]) and an optional cblack[4] x cblack[5] pattern stored from
 * cblack[6], indexed by visible position the way LibRaw applies it. */
static unsigned black_at(libraw_data_t *p, int row, int col, int index) {
    unsigned black = p->color.black;
    if (index >= 0 && index < 4) {
        black += p->color.cblack[index];
    }
    unsigned rows = p->color.cblack[4], cols = p->color.cblack[5];
    if (rows > 0 && cols > 0 && rows * cols <= LIBRAW_CBLACK_SIZE - 6) {
        black += p->color.cblack[6 + (row % rows) * cols + (col % cols)];
    }
    return black;
}

/* Fill `info` from an opened processor. Black levels and `has_mosaic` are
 * final only after libraw_unpack. Returns 0 on success. */
int skotiq_raw_describe(libraw_data_t *p, skotiq_raw_info_t *info) {
    if (!p || !info) {
        return -1;
    }
    memset(info, 0, sizeof(*info));

    copy_text(info->make, sizeof(info->make), p->idata.make);
    copy_text(info->model, sizeof(info->model), p->idata.model);
    copy_text(info->lens, sizeof(info->lens), p->lens.Lens);
    info->iso = p->other.iso_speed;
    info->shutter = p->other.shutter;
    info->aperture = p->other.aperture;
    info->focal_length = p->other.focal_len;
    info->timestamp = (long long)p->other.timestamp;
    info->sensor_temperature = p->makernotes.common.SensorTemperature;
    info->sensor_temperature2 = p->makernotes.common.SensorTemperature2;
    info->camera_temperature = p->makernotes.common.CameraTemperature;

    info->width = p->sizes.width;
    info->height = p->sizes.height;
    info->top_margin = p->sizes.top_margin;
    info->left_margin = p->sizes.left_margin;
    info->raw_width = p->sizes.raw_width;
    info->raw_height = p->sizes.raw_height;
    info->raw_bps = p->color.raw_bps;
    info->white_level = p->color.maximum;
    /* long[4] in LibRaw 0.21, unsigned[4] in 0.22. */
    for (int c = 0; c < 4; c++) {
        long value = (long)p->color.linear_max[c];
        if (value > 0 && (info->linear_max == 0 || (unsigned)value < info->linear_max)) {
            info->linear_max = (unsigned)value;
        }
    }
    info->filters = p->idata.filters;
    info->colors = p->idata.colors;
    info->dng_version = (int)p->idata.dng_version;

    info->has_mosaic = p->rawdata.raw_image != NULL;
    int size = 0;
    if (p->idata.filters == 9) {
        size = 6;
    } else if (p->idata.filters >= 1000) {
        size = 2;
    }
    /* filters 1..8 are the Leaf/Phase One 16x16 and other exotic layouts;
     * 0 is already-colour data. Neither is reported as a CFA. */
    if (size > 0) {
        for (int row = 0; row < size; row++) {
            for (int col = 0; col < size; col++) {
                int index = libraw_COLOR(p, row, col);
                char letter = (index >= 0 && index < 4) ? p->idata.cdesc[index] : '?';
                info->cfa[row * size + col] = letter;
                info->cfa_black[row * size + col] = black_at(p, row, col, index);
            }
        }
        info->cfa_size = size;
    }
    return 0;
}

/* Copy the visible part of the single-plane mosaic into `out`
 * (width * height samples). Returns 0 on success. */
int skotiq_raw_copy_mosaic(libraw_data_t *p, unsigned short *out, size_t out_len) {
    if (!p || !out) {
        return -1;
    }
    const unsigned short *raw = p->rawdata.raw_image;
    if (!raw) {
        return -2;
    }
    size_t width = p->sizes.width;
    size_t height = p->sizes.height;
    size_t top = p->sizes.top_margin;
    size_t left = p->sizes.left_margin;
    size_t stride = p->sizes.raw_pitch ? p->sizes.raw_pitch / sizeof(unsigned short)
                                       : p->sizes.raw_width;
    if (width == 0 || height == 0 || left + width > stride ||
        top + height > p->sizes.raw_height) {
        return -3;
    }
    if (out_len < width * height) {
        return -4;
    }
    const unsigned short *src = raw + stride * top + left;
    for (size_t row = 0; row < height; row++) {
        memcpy(out + row * width, src + row * stride, width * sizeof(unsigned short));
    }
    return 0;
}

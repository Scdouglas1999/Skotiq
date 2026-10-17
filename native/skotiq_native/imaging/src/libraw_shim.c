#include "libraw_types.h"
#include <string.h>
#include <stddef.h>

/* libraw_COLOR lives in libraw.h (the C API), which we deliberately do NOT
 * include here (the shim only needs the POD struct layout from
 * libraw_types.h). The symbol is exported by the linked libraw, so a plain
 * forward declaration is enough to call it. It maps a sensor (row,col) to a
 * colour-descriptor index (0..3) — the exact primitive the reference driver
 * uses (RawProcessor.COLOR) to read the CFA pattern out of idata.cdesc. */
extern int libraw_COLOR(libraw_data_t *, int row, int col);

typedef struct skotiq_libraw_config_t {
    int white_balance_mode;
    float user_mul[4];
    int output_color;
    int output_bps;
    int user_qual;
    int highlight;
    float bright;
    int no_auto_bright;
    int half_size;
    const char *bad_pixels;
    const char *dark_frame;
    int user_sat;
    int has_user_sat;
    double gamma[2];
    int has_gamma;
    double chromatic_aberration[2];
    int has_chromatic_aberration;
    unsigned max_memory_mb;
    int has_max_memory_mb;
} skotiq_libraw_config_t;

void skotiq_libraw_apply_config(
    libraw_data_t *processor,
    const skotiq_libraw_config_t *config
) {
    if (!processor || !config) {
        return;
    }

    processor->params.use_camera_wb = 0;
    processor->params.use_auto_wb = 0;

    switch (config->white_balance_mode) {
    case 0:
        processor->params.use_camera_wb = 1;
        break;
    case 1:
        processor->params.use_auto_wb = 1;
        break;
    case 2:
        processor->params.user_mul[0] = config->user_mul[0];
        processor->params.user_mul[1] = config->user_mul[1];
        processor->params.user_mul[2] = config->user_mul[2];
        processor->params.user_mul[3] = config->user_mul[3];
        break;
    default:
        break;
    }

    processor->params.output_color = config->output_color;
    processor->params.output_bps = config->output_bps;
    processor->params.user_qual = config->user_qual;
    processor->params.highlight = config->highlight;
    processor->params.bright = config->bright;
    processor->params.no_auto_bright = config->no_auto_bright;
    processor->params.half_size = config->half_size;
    processor->params.bad_pixels = (char *)config->bad_pixels;
    processor->params.dark_frame = (char *)config->dark_frame;

    if (config->has_user_sat) {
        processor->params.user_sat = config->user_sat;
    }

    if (config->has_gamma) {
        processor->params.gamm[0] = config->gamma[0];
        processor->params.gamm[1] = config->gamma[1];
    }

    if (config->has_chromatic_aberration) {
        processor->params.aber[0] = config->chromatic_aberration[0];
        processor->params.aber[1] = 1.0;
        processor->params.aber[2] = config->chromatic_aberration[1];
        processor->params.aber[3] = 1.0;
    }

    if (config->has_max_memory_mb) {
        processor->rawparams.max_raw_memory_mb = config->max_memory_mb;
    }
}

/* ------------------------------------------------------------------------- *
 * Raw CFA (Bayer / X-Trans) mosaic extraction.
 *
 * These two helpers give the Rust side the SINGLE-CHANNEL LINEAR MOSAIC that
 * astrophotography requires — the same data path the reference INDI driver
 * uses in read_libraw() (indi-gphoto/gphoto_readimage.cpp:143-218):
 *   open -> unpack -> raw2image, then copy imgdata.rawdata.raw_image with the
 *   optical-black margins trimmed. NO dcraw_process(), so NO demosaic / white
 *   balance / gamma / sRGB — the values stay the sensor's native linear ADU.
 *
 * All access to the (large, version-sensitive) libraw_data_t struct is done
 * HERE in C, where the compiler computes field offsets from the real
 * libraw_types.h — so there is zero risk of a hand-transcribed Rust ABI
 * silently reading the wrong bytes and corrupting every frame.
 * ------------------------------------------------------------------------- */
typedef struct skotiq_cfa_info_t {
    int width;         /* visible width  (rawdata.sizes.width)  */
    int height;        /* visible height (rawdata.sizes.height) */
    int raw_width;     /* stride         (rawdata.sizes.raw_width) */
    int raw_height;    /* full raw height (rawdata.sizes.raw_height) */
    int top_margin;    /* sizes.top_margin  */
    int left_margin;   /* sizes.left_margin */
    int raw_bps;       /* color.raw_bps (native ADC bit depth, best-effort) */
    unsigned maximum;  /* color.maximum (saturation white level)   */
    unsigned black;    /* color.black (global black level)         */
    int filters;       /* idata.filters (0 = no CFA, 9 = X-Trans)  */
    int is_xtrans;     /* convenience: filters == 9                */
    char cfa[8];       /* 2x2 CFA letters, e.g. "RGGB\0"           */
} skotiq_cfa_info_t;

/* Populate `info` from an unpacked (post raw2image) processor. Returns 0 on
 * success, negative on error (null args, or no single-channel raw_image —
 * e.g. Foveon / already-RGB data has raw_image == NULL). */
int skotiq_libraw_extract_cfa_info(
    libraw_data_t *processor,
    skotiq_cfa_info_t *info
) {
    if (!processor || !info) {
        return -1;
    }
    if (!processor->rawdata.raw_image) {
        /* No single-channel Bayer/X-Trans buffer (Foveon, sRAW, etc.). */
        return -2;
    }

    info->width       = processor->rawdata.sizes.width;
    info->height      = processor->rawdata.sizes.height;
    info->raw_width   = processor->rawdata.sizes.raw_width;
    info->raw_height  = processor->rawdata.sizes.raw_height;
    info->top_margin  = processor->sizes.top_margin;
    info->left_margin = processor->sizes.left_margin;
    info->raw_bps     = (int)processor->color.raw_bps;
    info->maximum     = processor->color.maximum;
    info->black       = processor->color.black;
    info->filters     = (int)processor->idata.filters;
    info->is_xtrans   = (processor->idata.filters == 9) ? 1 : 0;

    /* CFA orientation, matching read_libraw() lines 179-183: read the colour
     * descriptor letter at each of the four 2x2 positions. cdesc maps a
     * colour index (returned by COLOR) to its letter ('R','G','B'). */
    info->cfa[0] = processor->idata.cdesc[libraw_COLOR(processor, 0, 0)];
    info->cfa[1] = processor->idata.cdesc[libraw_COLOR(processor, 0, 1)];
    info->cfa[2] = processor->idata.cdesc[libraw_COLOR(processor, 1, 0)];
    info->cfa[3] = processor->idata.cdesc[libraw_COLOR(processor, 1, 1)];
    info->cfa[4] = '\0';
    info->cfa[5] = '\0';
    info->cfa[6] = '\0';
    info->cfa[7] = '\0';

    return 0;
}

/* Copy the visible single-channel mosaic into `out` (caller-allocated,
 * out_len >= width*height u16 samples). Trims the top/left optical-black
 * margins and de-strides raw_width -> width, exactly like read_libraw()
 * lines 208-216. Returns 0 on success, negative on error. */
int skotiq_libraw_copy_cfa_mosaic(
    libraw_data_t *processor,
    unsigned short *out,
    size_t out_len
) {
    if (!processor || !out) {
        return -1;
    }
    const unsigned short *raw = processor->rawdata.raw_image;
    if (!raw) {
        return -2;
    }

    int width      = processor->rawdata.sizes.width;
    int height     = processor->rawdata.sizes.height;
    int raw_width  = processor->rawdata.sizes.raw_width;
    int top        = processor->sizes.top_margin;
    int left       = processor->sizes.left_margin;

    if (width <= 0 || height <= 0 || raw_width <= 0) {
        return -3;
    }
    if (out_len < (size_t)width * (size_t)height) {
        return -4;
    }

    /* first_visible_pixel = raw_width * top_margin + left_margin */
    const unsigned short *src =
        raw + (size_t)raw_width * (size_t)top + (size_t)left;
    unsigned short *dst = out;

    for (int row = 0; row < height; row++) {
        memcpy(dst, src, (size_t)width * sizeof(unsigned short));
        dst += width;
        src += raw_width;
    }

    return 0;
}

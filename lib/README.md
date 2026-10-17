# Third-Party Libraries

This directory contains pre-compiled third-party libraries required for building Skotiq.

## LibRaw

Location: `libraw/`

LibRaw is used for RAW image processing. The pre-compiled Windows binaries are included.

**Files required:**
- `libraw.dll` - Dynamic library (needed at runtime)
- `libraw.lib` - Import library (needed at build time)

**To obtain LibRaw:**
1. Download from https://www.libraw.org/download
2. Extract and copy the 64-bit binaries to this directory

**Version:** 0.21.x (April 2025 build)

## Notes

- These libraries are tracked in git because they're required for building
- The build system looks for libraries here first, then falls back to workspace root
- You can override the search path with the `LIBRAW_DIR` environment variable

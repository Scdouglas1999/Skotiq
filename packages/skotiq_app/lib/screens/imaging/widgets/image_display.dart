import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/red_night_filter.dart';

class ImageDisplayWidget extends ConsumerStatefulWidget {
  final CapturedImageData imageData;
  final double zoomLevel;
  final Offset panOffset;

  /// Optional decode-time downscale targets. When set, the engine decodes the
  /// RGBA buffer straight to (at most) these dimensions instead of allocating
  /// the full sensor-resolution texture. Used by the dashboard live-frame tile
  /// — a ~300px panel never needs a 6000px decode. Both are clamped to the
  /// source dimensions (no upscaling). Leave null for the full-screen Imaging
  /// viewer, which decodes at native resolution for pixel-peeping.
  final int? targetWidth;
  final int? targetHeight;

  const ImageDisplayWidget({
    super.key,
    required this.imageData,
    required this.zoomLevel,
    required this.panOffset,
    this.targetWidth,
    this.targetHeight,
  });

  @override
  ConsumerState<ImageDisplayWidget> createState() => _ImageDisplayWidgetState();
}

class _ImageDisplayWidgetState extends ConsumerState<ImageDisplayWidget> {
  ui.Image? _decodedImage;
  bool _isDecoding = false;
  Uint8List? _lastDecodedPixels;
  int? _lastDecodedTargetWidth;
  int? _lastDecodedTargetHeight;

  /// Pixels asked for while another decode was running.
  Uint8List? _pendingPixels;

  // Which pixels to decode is decided in [build], from the screen rendering
  // of the frame: decoding the display data here first flashed the
  // stretched frame before every linear one.

  @override
  void didUpdateWidget(ImageDisplayWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageData.capturedAt != oldWidget.imageData.capturedAt ||
        !identical(
          widget.imageData.displayData,
          oldWidget.imageData.displayData,
        )) {
      // A new frame: [build] picks its pixels; the old texture stays up
      // until they are decoded.
      _lastDecodedPixels = null;
    } else if (widget.targetWidth != oldWidget.targetWidth ||
        widget.targetHeight != oldWidget.targetHeight) {
      // The live-frame panel feeds the viewport width, which moves on resize.
      _decodeImage(pixels: _lastDecodedPixels);
    }
  }

  void _decodePending() {
    final next = _pendingPixels;
    _pendingPixels = null;
    if (next != null && mounted) _decodeImage(pixels: next);
  }

  /// The live texture, so a test can assert it is released rather than leaked.
  @visibleForTesting
  ui.Image? get debugDecodedImage => _decodedImage;

  /// The pixels behind [debugDecodedImage], so a test can tell which
  /// rendering is on screen.
  @visibleForTesting
  Uint8List? get debugDecodedPixels => _lastDecodedPixels;

  @override
  void dispose() {
    _decodedImage?.dispose();
    super.dispose();
  }

  Future<void> _decodeImage({Uint8List? pixels}) async {
    if (_isDecoding) {
      // The decode in flight is of older pixels; take these when it lands.
      _pendingPixels = pixels ?? widget.imageData.displayData;
      return;
    }
    _isDecoding = true;

    try {
      final width = widget.imageData.width;
      final height = widget.imageData.height;
      // The screen rendering when given, else the frame's display data. Both
      // are always RGBA (4 bytes per pixel, alpha=255): the conversion is
      // done in Rust (for display_data) or at the provider boundary (for a
      // rendering), so no per-pixel loop is needed here.
      final Uint8List rgbaBytes = pixels ?? widget.imageData.displayData;

      // Resolve the decode-time downscale target. Clamp to the source
      // dimensions so we never ask the engine to upscale.
      final int? targetW = widget.targetWidth?.clamp(1, width);
      final int? targetH = widget.targetHeight?.clamp(1, height);

      // Skip re-decoding only when both the pixels AND the decode target are
      // unchanged — a resize that moves the target must re-decode even if the
      // underlying buffer is identical.
      if (_lastDecodedPixels != null &&
          _lastDecodedPixels == rgbaBytes &&
          _lastDecodedTargetWidth == targetW &&
          _lastDecodedTargetHeight == targetH) {
        _isDecoding = false;
        _decodePending();
        return;
      }
      _lastDecodedPixels = rgbaBytes;
      _lastDecodedTargetWidth = targetW;
      _lastDecodedTargetHeight = targetH;

      ui.decodeImageFromPixels(
        rgbaBytes,
        width,
        height,
        ui.PixelFormat.rgba8888,
        (image) {
          // A decoded ui.Image holds its texture outside the Dart heap, so a
          // replaced one has to be released explicitly — dropping the
          // reference leaked a full-resolution texture (65 MB at 4656x3520)
          // for every frame the session captured. Same on the unmounted path:
          // nothing else will ever hold this one.
          if (!mounted) {
            image.dispose();
            _isDecoding = false;
            return;
          }
          setState(() {
            _decodedImage?.dispose();
            _decodedImage = image;
            _isDecoding = false;
          });
          _decodePending();
        },
        targetWidth: targetW,
        targetHeight: targetH,
        allowUpscaling: false,
      );
    } catch (e) {
      ref.read(loggingServiceProvider).warning(
          '[Imaging] Error decoding image: $e',
          source: 'ImageDisplay',
          fields: {'error': e.toString()});
      _isDecoding = false;
      _decodePending();
    }
  }

  @override
  Widget build(BuildContext context) {
    // The screen rendering of the current frame: null means the frame's own
    // display data (see stretchedImageProvider). It follows Imaging's current
    // frame, so it applies only while that is the frame this widget shows.
    final stretchedImageAsync = ref.watch(stretchedImageProvider);
    final showsCurrentFrame =
        ref.watch(currentImageProvider.select((i) => i?.capturedAt)) ==
            widget.imageData.capturedAt;
    final expectedLength = widget.imageData.width * widget.imageData.height * 4;
    final Uint8List? wanted = !showsCurrentFrame
        ? widget.imageData.displayData
        : stretchedImageAsync.when(
            data: (stretched) =>
                stretched != null && stretched.length == expectedLength
                    ? stretched
                    : widget.imageData.displayData,
            // A new rendering is on its way; keep what is on screen.
            loading: () => null,
            error: (_, __) => widget.imageData.displayData,
          );
    if (wanted != null && !identical(wanted, _lastDecodedPixels)) {
      // Defer the decode to avoid setState during build. Turning the stretch
      // off and back on lands here too: the frame's own display data is
      // decoded again rather than the last rendering staying up.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _decodeImage(pixels: wanted);
        }
      });
    }

    if (_decodedImage == null) {
      return const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
    }

    // The frame is image DATA: red night re-emits its luminance on the red
    // axis rather than letting an arbitrary RGB astro frame light the room.
    return RedNightImage(
      child: ClipRect(
        child: Center(
          child: Transform.translate(
            offset: widget.panOffset,
            child: Transform.scale(
              scale: widget.zoomLevel,
              alignment: Alignment.center,
              child: CustomPaint(
                painter: _DecodedImagePainter(
                  image: _decodedImage!,
                ),
                size: Size(
                  _decodedImage!.width.toDouble(),
                  _decodedImage!.height.toDouble(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DecodedImagePainter extends CustomPainter {
  final ui.Image image;

  _DecodedImagePainter({required this.image});

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(
      canvas: canvas,
      rect: Rect.fromLTWH(0, 0, size.width, size.height),
      image: image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_DecodedImagePainter oldDelegate) {
    return image != oldDelegate.image;
  }
}

import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

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

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  @override
  void didUpdateWidget(ImageDisplayWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-decode on a new frame, or when the requested decode target changes
    // (the live-frame panel feeds the viewport width, which moves on resize).
    if (widget.imageData != oldWidget.imageData ||
        widget.targetWidth != oldWidget.targetWidth ||
        widget.targetHeight != oldWidget.targetHeight) {
      _decodeImage();
    }
  }

  /// The live texture, so a test can assert it is released rather than leaked.
  @visibleForTesting
  ui.Image? get debugDecodedImage => _decodedImage;

  @override
  void dispose() {
    _decodedImage?.dispose();
    super.dispose();
  }

  Future<void> _decodeImage({Uint8List? stretchedData}) async {
    if (_isDecoding) return;
    _isDecoding = true;

    try {
      final width = widget.imageData.width;
      final height = widget.imageData.height;
      // Use stretched data if available, otherwise fall back to display data.
      // Both are always RGBA (4 bytes per pixel, alpha=255) — the conversion
      // is done in Rust (for display_data) or at the provider boundary (for
      // stretched data), so no per-pixel loop is needed here.
      final Uint8List rgbaBytes = stretchedData ?? widget.imageData.displayData;

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
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch the stretched image provider for auto-stretch updates
    final stretchedImageAsync = ref.watch(stretchedImageProvider);

    // When stretched data changes, trigger re-decode
    stretchedImageAsync.whenData((stretchedData) {
      if (stretchedData != null && stretchedData != _lastDecodedPixels) {
        // Defer the decode to avoid setState during build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _decodeImage(stretchedData: stretchedData);
          }
        });
      }
    });

    if (_decodedImage == null) {
      return const Center(child: CircularProgressIndicator());
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

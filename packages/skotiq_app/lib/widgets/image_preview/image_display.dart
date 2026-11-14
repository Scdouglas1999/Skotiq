import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kProfileMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../red_night_filter.dart';
import 'preview_display_scale.dart';
import 'preview_downscale.dart';

class ImageDisplayWidget extends ConsumerStatefulWidget {
  final CapturedImageData imageData;
  final double zoomLevel;
  final Offset panOffset;

  /// Optional preview dimensions in physical pixels, clamped to the source.
  /// A missing dimension follows the source aspect ratio.
  final int? targetWidth;
  final int? targetHeight;

  /// Decode only the physical pixels shown by this widget's fit and zoom.
  /// Keep false when an ancestor controls magnification, as in fullscreen's
  /// InteractiveViewer. Native zoom still uses the original source pixels.
  final bool downscaleToViewport;

  const ImageDisplayWidget({
    super.key,
    required this.imageData,
    required this.zoomLevel,
    required this.panOffset,
    this.targetWidth,
    this.targetHeight,
    this.downscaleToViewport = false,
  });

  @override
  ConsumerState<ImageDisplayWidget> createState() => _ImageDisplayWidgetState();
}

class _ImageDisplayWidgetState extends ConsumerState<ImageDisplayWidget> {
  ui.Image? _decodedImage;
  bool _isDecoding = false;
  bool _decodeScheduled = false;
  _DecodeRequest? _requested;
  _DecodeRequest? _decoded;

  /// The live texture, so a test can assert it is released rather than leaked.
  @visibleForTesting
  ui.Image? get debugDecodedImage => _decodedImage;

  /// The pixels behind [debugDecodedImage], so a test can tell which
  /// rendering is on screen.
  @visibleForTesting
  Uint8List? get debugDecodedPixels => _decoded?.pixels;

  @override
  void dispose() {
    _decodedImage?.dispose();
    super.dispose();
  }

  void _requestDecode(_DecodeRequest? request) {
    if (request?.matches(_requested) ?? _requested == null) return;
    _requested = request;
    if (request == null ||
        request.matches(_decoded) ||
        _isDecoding ||
        _decodeScheduled) {
      return;
    }
    _decodeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _decodeScheduled = false;
      if (mounted) unawaited(_decodeLatest());
    });
  }

  Future<void> _decodeLatest() async {
    if (_isDecoding) return;
    _isDecoding = true;
    try {
      while (mounted) {
        final request = _requested;
        if (request == null || request.matches(_decoded)) return;
        bool obsolete() => !mounted || !identical(request, _requested);
        final trace = kProfileMode
            ? (developer.TimelineTask()
              ..start('Preview decode', arguments: {
                'sourceWidth': request.width,
                'sourceHeight': request.height,
                'targetWidth': request.targetWidth,
                'targetHeight': request.targetHeight,
                'sourceBytes': request.pixels.length,
              }))
            : null;
        var finishAfterPaint = false;
        try {
          final pixels = await downscalePreviewRgba(
            pixels: request.pixels,
            width: request.width,
            height: request.height,
            targetWidth: request.targetWidth,
            targetHeight: request.targetHeight,
            isCancelled: obsolete,
          );
          if (pixels == null || obsolete()) continue;
          trace
              ?.instant('Preview resized', arguments: {'bytes': pixels.length});
          // This is decodeImageFromPixels' buffer/descriptor path, awaited so
          // errors and obsolete results release every native allocation.
          final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
          trace?.instant('Preview immutable copy ready');
          ui.ImageDescriptor? descriptor;
          ui.Codec? codec;
          ui.Image? image;
          try {
            if (obsolete()) continue;
            descriptor = ui.ImageDescriptor.raw(
              buffer,
              width: request.targetWidth,
              height: request.targetHeight,
              pixelFormat: ui.PixelFormat.rgba8888,
            );
            codec = await descriptor.instantiateCodec();
            image = (await codec.getNextFrame()).image;
          } finally {
            codec?.dispose();
            descriptor?.dispose();
            buffer.dispose();
          }
          if (obsolete()) {
            image.dispose();
            continue;
          }
          trace?.instant('Preview texture ready');
          setState(() {
            _decodedImage?.dispose();
            _decodedImage = image;
            _decoded = request;
          });
          if (trace != null) {
            finishAfterPaint = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final current = mounted &&
                  identical(_requested, request) &&
                  identical(_decoded, request);
              if (current) trace.instant('Preview paint submitted');
              trace.finish(arguments: {'displayed': current});
            });
          }
        } catch (error, stackTrace) {
          Log.warning('Error decoding image',
              source: 'ImageDisplay', error: error, stackTrace: stackTrace);
          // Keep the last successful rendering. A new request can retry, but
          // a failing decoder must not start an unbounded retry loop here.
          if (!obsolete()) {
            _requested = null;
            return;
          }
        } finally {
          if (!finishAfterPaint) {
            trace?.finish(arguments: {'obsolete': obsolete()});
          }
        }
      }
    } finally {
      _isDecoding = false;
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
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final width = widget.imageData.width;
      final height = widget.imageData.height;
      final sourceSize = Size(width.toDouble(), height.toDouble());
      var targetW = widget.targetWidth?.clamp(1, width);
      var targetH = widget.targetHeight?.clamp(1, height);
      if (targetW == null && targetH != null) {
        targetW = math.max(1, (targetH * width / height).round());
      } else if (targetH == null && targetW != null) {
        targetH = math.max(1, (targetW * height / width).floor());
      } else if (targetW == null && widget.downscaleToViewport) {
        final scale = math.min(
          1.0,
          previewFitScale(
                viewportSize: constraints.biggest,
                imageSize: sourceSize,
              ) *
              widget.zoomLevel *
              dpr,
        );
        targetW = math.max(1, (width * scale).ceil());
        targetH = math.max(1, (height * scale).ceil());
      }
      _requestDecode(wanted == null
          ? null
          : _DecodeRequest(
              pixels: wanted,
              width: width,
              height: height,
              targetWidth: targetW ?? width,
              targetHeight: targetH ?? height,
            ));

      if (_decodedImage == null) {
        return const Center(
            child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
      }
      final decodedSize =
          Size(_decoded!.width.toDouble(), _decoded!.height.toDouble());
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
                    sourceSize: decodedSize,
                  ),
                  // Texture resolution must not change fit, zoom or the
                  // source-coordinate geometry used by overlays.
                  size: decodedSize,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _DecodeRequest {
  const _DecodeRequest({
    required this.pixels,
    required this.width,
    required this.height,
    required this.targetWidth,
    required this.targetHeight,
  });

  final Uint8List pixels;
  final int width;
  final int height;
  final int targetWidth;
  final int targetHeight;

  bool matches(_DecodeRequest? other) =>
      other != null &&
      identical(pixels, other.pixels) &&
      width == other.width &&
      height == other.height &&
      targetWidth == other.targetWidth &&
      targetHeight == other.targetHeight;
}

class _DecodedImagePainter extends CustomPainter {
  final ui.Image image;
  final Size sourceSize;

  _DecodedImagePainter({required this.image, required this.sourceSize});

  @override
  void paint(Canvas canvas, Size size) {
    final fitted = applyBoxFit(BoxFit.contain, sourceSize, size);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Alignment.center.inscribe(fitted.destination, Offset.zero & size),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_DecodedImagePainter oldDelegate) {
    return image != oldDelegate.image || sourceSize != oldDelegate.sourceSize;
  }
}

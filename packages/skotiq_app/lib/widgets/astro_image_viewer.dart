import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Efficient astronomy image viewer that supports both color and mono images
/// with zoom/pan functionality including mousewheel support.
///
/// Features:
/// - GPU-accelerated rendering via ui.Image
/// - Supports RGBA pixel data (conversion done in Rust for performance)
/// - Interactive zoom/pan with mousewheel and gesture support
/// - Configurable min/max zoom levels
class AstroImageViewer extends StatefulWidget {
  /// The RGBA pixel data (4 bytes per pixel, alpha=255).
  /// Conversion from RGB/grayscale is done in Rust for performance.
  final Uint8List imageData;

  /// Width of the image in pixels
  final int width;

  /// Height of the image in pixels
  final int height;

  /// Whether the source image was color (RGB) or mono (grayscale).
  /// Retained for informational purposes; imageData is always RGBA.
  final bool isColor;

  /// Minimum zoom scale
  final double minScale;

  /// Maximum zoom scale
  final double maxScale;

  /// Whether to enable zoom/pan interaction
  final bool enableInteraction;

  /// Filter quality for image scaling
  final FilterQuality filterQuality;

  /// Callback when zoom/pan state changes
  final ValueChanged<TransformationController>? onTransformChanged;

  /// Externally owned view transform.
  ///
  /// Supplying one hands the caller two things this widget's private
  /// controller cannot give: the ability to drive the transform (fit, 1:1,
  /// zoom buttons) and the ability to share one transform between two viewers
  /// for an A/B compare. The caller owns its lifecycle — this widget never
  /// disposes a controller it did not create.
  ///
  /// It also changes what a NEW image buffer means. With the private
  /// controller a new buffer is a new scene and is re-fitted; with an
  /// externally owned one the caller is showing successive renders of the same
  /// scene, so the first layout fits and every later buffer keeps the zoom and
  /// pan the operator set. Throwing that away on each re-render is what makes
  /// an editor unusable.
  final TransformationController? transformationController;

  const AstroImageViewer({
    super.key,
    required this.imageData,
    required this.width,
    required this.height,
    this.isColor = false,
    this.minScale = 0.1,
    this.maxScale = 10.0,
    this.enableInteraction = true,
    this.filterQuality = FilterQuality.medium,
    this.onTransformChanged,
    this.transformationController,
  });

  @override
  State<AstroImageViewer> createState() => _AstroImageViewerState();
}

class _AstroImageViewerState extends State<AstroImageViewer> {
  ui.Image? _decodedImage;
  bool _isLoading = true;
  Uint8List? _lastImageData;
  int? _lastWidth;
  int? _lastHeight;
  bool? _lastIsColor;
  bool _initialScaleSet = false;

  /// A post-frame fit write is pending; layout passes must not schedule
  /// another (the write itself happens outside layout — see build).
  bool _initialFitScheduled = false;
  double? _effectiveMinScale;

  late TransformationController _transformationController;

  /// True when this state created the controller and must therefore dispose it.
  bool _ownsTransformationController = false;

  @override
  void initState() {
    super.initState();
    final supplied = widget.transformationController;
    _ownsTransformationController = supplied == null;
    _transformationController = supplied ?? TransformationController();
    _decodeImage();
  }

  /// Calculate the scale needed to fit the image within the container
  double _calculateFitScale(
      Size containerSize, int imageWidth, int imageHeight) {
    if (containerSize.isEmpty || imageWidth <= 0 || imageHeight <= 0) {
      return 1.0;
    }
    final scaleX = containerSize.width / imageWidth;
    final scaleY = containerSize.height / imageHeight;
    return scaleX < scaleY ? scaleX : scaleY;
  }

  /// Set the initial transformation to fit the image in the container
  void _setInitialFitTransform(Size containerSize) {
    if (_decodedImage == null || _initialScaleSet) return;

    final fitScale = _calculateFitScale(
      containerSize,
      _decodedImage!.width,
      _decodedImage!.height,
    );

    // Calculate offset to center the scaled image
    final scaledWidth = _decodedImage!.width * fitScale;
    final scaledHeight = _decodedImage!.height * fitScale;
    final offsetX = (containerSize.width - scaledWidth) / 2;
    final offsetY = (containerSize.height - scaledHeight) / 2;

    _transformationController.value = Matrix4.identity()
      ..translateByDouble(offsetX, offsetY, 0, 1.0)
      ..scaleByDouble(fitScale, fitScale, 1.0, 1.0);

    _initialScaleSet = true;
  }

  @override
  void didUpdateWidget(covariant AstroImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.transformationController != oldWidget.transformationController) {
      if (_ownsTransformationController) _transformationController.dispose();
      final supplied = widget.transformationController;
      _ownsTransformationController = supplied == null;
      _transformationController = supplied ?? TransformationController();
      // A different transform is a different view, so the next layout fits it.
      _initialScaleSet = false;
    }
    // Only re-decode if the image data actually changed
    if (!identical(widget.imageData, _lastImageData) ||
        widget.width != _lastWidth ||
        widget.height != _lastHeight ||
        widget.isColor != _lastIsColor) {
      // Re-fit only when this widget owns the transform. An externally owned
      // controller means the caller is showing successive renders of one scene
      // and holds the operator's zoom and pan; re-fitting here would throw
      // those away on every re-render.
      if (_ownsTransformationController) _initialScaleSet = false;
      _decodeImage();
    }
  }

  Future<void> _decodeImage() async {
    final sourceData = widget.imageData;
    final width = widget.width;
    final height = widget.height;
    final isColor = widget.isColor;

    if (sourceData.isEmpty || width <= 0 || height <= 0) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      return;
    }

    // Cache current params
    _lastImageData = sourceData;
    _lastWidth = width;
    _lastHeight = height;
    _lastIsColor = isColor;

    // Show loading state
    if (mounted && !_isLoading) {
      setState(() => _isLoading = true);
    }

    // imageData is already RGBA (4 bytes per pixel, alpha=255) —
    // conversion from RGB/grayscale is done in Rust for performance.
    // No compute isolate needed; just decode directly.
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      sourceData,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (ui.Image img) {
        completer.complete(img);
      },
    );

    final image = await completer.future;

    if (mounted) {
      // Dispose old image before replacing
      _decodedImage?.dispose();
      setState(() {
        _decodedImage = image;
        _isLoading = false;
      });
    } else {
      // Widget was disposed while loading
      image.dispose();
    }
  }

  @override
  void dispose() {
    _decodedImage?.dispose();
    if (_ownsTransformationController) _transformationController.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (!widget.enableInteraction) return;

    if (event is PointerScrollEvent) {
      // Get current scale
      final currentScale = _transformationController.value.getMaxScaleOnAxis();

      // Calculate new scale based on scroll direction
      final delta = event.scrollDelta.dy;
      final scaleFactor = delta > 0 ? 0.9 : 1.1; // Zoom out or in
      final minScale = _effectiveMinScale ?? widget.minScale;
      final newScale =
          (currentScale * scaleFactor).clamp(minScale, widget.maxScale);

      if (newScale != currentScale) {
        // Get the focal point in scene coordinates
        final focalPoint = event.localPosition;

        // Calculate the new transformation matrix
        final scaleChange = newScale / currentScale;

        // Create a new matrix that scales around the focal point
        final matrix = Matrix4.identity()
          ..translateByDouble(focalPoint.dx, focalPoint.dy, 0, 1.0)
          ..scaleByDouble(scaleChange, scaleChange, 1.0, 1.0)
          ..translateByDouble(-focalPoint.dx, -focalPoint.dy, 0, 1.0);

        _transformationController.value =
            matrix * _transformationController.value;

        widget.onTransformChanged?.call(_transformationController);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (_decodedImage == null) {
      return const Center(
        child: Text('No image data'),
      );
    }

    final imageWidget = CustomPaint(
      painter: _AstroImagePainter(
        image: _decodedImage!,
        filterQuality: widget.filterQuality,
      ),
      size: Size(
        _decodedImage!.width.toDouble(),
        _decodedImage!.height.toDouble(),
      ),
    );

    if (!widget.enableInteraction) {
      return Center(
        child: FittedBox(
          fit: BoxFit.contain,
          child: imageWidget,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final containerSize = Size(constraints.maxWidth, constraints.maxHeight);

        // Calculate fit scale for this container
        final fitScale = _calculateFitScale(
          containerSize,
          _decodedImage!.width,
          _decodedImage!.height,
        );

        // Ensure minScale doesn't exceed the fit scale, otherwise the image
        // would appear zoomed in rather than fitting the container
        final effectiveMinScale =
            fitScale < widget.minScale ? fitScale : widget.minScale;
        _effectiveMinScale = effectiveMinScale;

        // Set initial fit transform once we know the container size. The
        // write is deferred to a post-frame callback: a caller-supplied
        // controller can have listeners that setState, and notifying them
        // from inside this layout callback wedges the enclosing
        // LayoutBuilder's build scope in release builds (the framework's
        // debugNeedsLayout assert that catches it is stripped).
        if (!_initialScaleSet &&
            !_initialFitScheduled &&
            containerSize.width > 0 &&
            containerSize.height > 0) {
          _initialFitScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _initialFitScheduled = false;
            if (mounted) _setInitialFitTransform(containerSize);
          });
        }

        return Listener(
          onPointerSignal: _onPointerSignal,
          child: InteractiveViewer(
            transformationController: _transformationController,
            minScale: effectiveMinScale,
            maxScale: widget.maxScale,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            child: Center(
              child: imageWidget,
            ),
          ),
        );
      },
    );
  }
}

/// Efficient image painter that draws a pre-decoded ui.Image
class _AstroImagePainter extends CustomPainter {
  final ui.Image image;
  final FilterQuality filterQuality;

  _AstroImagePainter({
    required this.image,
    this.filterQuality = FilterQuality.medium,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = filterQuality;
    canvas.drawImage(image, Offset.zero, paint);
  }

  @override
  bool shouldRepaint(_AstroImagePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.filterQuality != filterQuality;
  }
}

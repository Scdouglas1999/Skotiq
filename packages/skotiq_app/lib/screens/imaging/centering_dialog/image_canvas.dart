part of '../centering_dialog.dart';

/// Efficiently renders RGBA image data without zoom/pan (simple fit display)
class _CenteringImageWidget extends StatefulWidget {
  final Uint8List imageData;
  final int width;
  final int height;

  const _CenteringImageWidget({
    required this.imageData,
    required this.width,
    required this.height,
  });

  @override
  State<_CenteringImageWidget> createState() => _CenteringImageWidgetState();
}

class _CenteringImageWidgetState extends State<_CenteringImageWidget> {
  ui.Image? _decodedImage;
  Uint8List? _lastData;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  @override
  void didUpdateWidget(covariant _CenteringImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.imageData, _lastData)) {
      _decodeImage();
    }
  }

  Future<void> _decodeImage() async {
    _lastData = widget.imageData;
    try {
      final completer = ui.ImmutableBuffer.fromUint8List(widget.imageData);
      final buffer = await completer;
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: widget.width,
        height: widget.height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      if (mounted) {
        setState(() {
          _decodedImage?.dispose();
          _decodedImage = frame.image;
        });
      }
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    } catch (e, st) {
      // Why: preview-image decode is best-effort UI; the centering loop
      // continues regardless. Logged so we can diagnose chronic decode
      // failures (codec issues, malformed buffer) that would otherwise
      // be invisible — the user just sees the spinner forever.
      developer.log('[CenteringDialog] preview decode failed: $e',
          name: 'CenteringDialog', level: 900, error: e, stackTrace: st);
    }
  }

  @override
  void dispose() {
    _decodedImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_decodedImage == null) {
      return const SizedBox(
        width: 200,
        height: 200,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return RawImage(
      image: _decodedImage,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// Crosshair overlay painter for centering image
class _CrosshairPainter extends CustomPainter {
  final Color color;

  _CrosshairPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final cx = size.width / 2;
    final cy = size.height / 2;

    // Horizontal line
    canvas.drawLine(Offset(0, cy), Offset(size.width, cy), paint);
    // Vertical line
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), paint);

    // Center circle
    canvas.drawCircle(Offset(cx, cy), 20, paint);
  }

  @override
  bool shouldRepaint(covariant _CrosshairPainter oldDelegate) =>
      oldDelegate.color != color;
}

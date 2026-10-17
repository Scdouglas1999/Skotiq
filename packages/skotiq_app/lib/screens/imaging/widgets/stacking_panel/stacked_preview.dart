part of '../stacking_panel.dart';

/// Displays the u16 stacked preview image, converting it to an 8-bit
/// displayable format on the fly.
///
/// The conversion is the app's shared auto-stretch ([stretch], normally
/// `LiveStackingService.autoStretchPreview` → the Rust MAD-based STF), so the
/// preview shows the same star field the viewer shows. It is deliberately NOT
/// a linear min/max map: on a real stacked light the max is a saturated star
/// and the min is the sky floor, which renders the whole frame black.
///
/// [channels] selects how [previewData] is interpreted:
///   * `1` — a single luminance plane (`width * height` samples).
///   * `3` — an interleaved RGB16 buffer (`width * height * 3` samples, the
///     layout an OSC session produces), stretched per channel so a colour
///     stack previews in colour rather than as a scrambled mono plane.
class _StackedPreview extends StatefulWidget {
  final Uint16List previewData;
  final int width;
  final int height;
  final int channels;
  final StackedPreviewStretch stretch;
  final SkotiqColors colors;

  const _StackedPreview({
    required this.previewData,
    required this.width,
    required this.height,
    required this.channels,
    required this.stretch,
    required this.colors,
  });

  @override
  State<_StackedPreview> createState() => _StackedPreviewState();
}

class _StackedPreviewState extends State<_StackedPreview> {
  ui.Image? _displayImage;
  bool _isDecoding = false;

  @override
  void initState() {
    super.initState();
    _buildDisplayImage();
  }

  @override
  void didUpdateWidget(_StackedPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only rebuild when the data actually changes (identity check is fast)
    if (!identical(widget.previewData, oldWidget.previewData) ||
        widget.width != oldWidget.width ||
        widget.height != oldWidget.height ||
        widget.channels != oldWidget.channels ||
        widget.stretch != oldWidget.stretch) {
      _buildDisplayImage();
    }
  }

  @override
  void dispose() {
    _displayImage?.dispose();
    super.dispose();
  }

  Future<void> _buildDisplayImage() async {
    if (_isDecoding) return;
    _isDecoding = true;

    final data = widget.previewData;
    final w = widget.width;
    final h = widget.height;
    final pixelCount = w * h;

    if (pixelCount <= 0) {
      _isDecoding = false;
      return;
    }

    // Sanity check: the buffer must carry the samples the channel layout
    // claims before it is handed to the native stretch.
    final samplesPerPixel = widget.channels == 3 ? 3 : 1;
    if (data.length < pixelCount * samplesPerPixel) {
      _isDecoding = false;
      return;
    }

    final Uint8List rgba;
    try {
      rgba = widget.stretch(
        width: w,
        height: h,
        data: data,
        channels: samplesPerPixel,
      );
    } catch (e) {
      developer.log('[StackingPanel] Error stretching preview: $e',
          name: 'StackingPanel', level: 900, error: e);
      _isDecoding = false;
      return;
    }
    if (rgba.length < pixelCount * 4) {
      developer.log(
          '[StackingPanel] Stretched preview is ${rgba.length} bytes, '
          'expected ${pixelCount * 4}',
          name: 'StackingPanel',
          level: 900);
      _isDecoding = false;
      return;
    }

    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();

      if (mounted) {
        setState(() {
          _displayImage?.dispose();
          _displayImage = frame.image;
        });
      } else {
        frame.image.dispose();
      }

      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    } catch (e) {
      developer.log('[StackingPanel] Error building preview image: $e',
          name: 'StackingPanel', level: 900, error: e);
    } finally {
      _isDecoding = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_displayImage == null) {
      return Container(
        height: 180,
        decoration: BoxDecoration(
          color: widget.colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: const SkotiqMark(
                    motion: SkotiqMarkMotion.loading, size: 20),
              ),
              const SizedBox(height: 8),
              Text('Rendering preview...',
                  style: SkotiqTypography.caption
                      .copyWith(color: widget.colors.textMuted)),
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      child: AspectRatio(
        aspectRatio: widget.width / widget.height,
        child: RawImage(
          image: _displayImage,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

// Preview pixel conversion

/// Renders a u16 stacked buffer to display-ready RGBA8.
///
/// `channels` is `1` (luminance plane) or `3` (interleaved RGB16). The
/// production implementation is the app's shared MAD-based STF auto-stretch
/// (`LiveStackingService.autoStretchPreview`), which lives in Rust so exactly
/// one stretch curve exists across the viewer, Stack-and-Share and this
/// preview.
typedef StackedPreviewStretch = Uint8List Function({
  required int width,
  required int height,
  required List<int> data,
  required int channels,
});

/// Injection point for [StackedPreviewStretch]; overridden in tests so the
/// preview can be exercised without the native library.
final stackedPreviewStretchProvider = Provider<StackedPreviewStretch>(
  (ref) => ref.watch(liveStackingServiceProvider).autoStretchPreview,
);

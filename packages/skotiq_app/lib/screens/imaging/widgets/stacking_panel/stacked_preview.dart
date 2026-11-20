part of '../stacking_panel.dart';

/// Displays the u16 stacked preview image, converting it to an 8-bit
/// displayable format off the UI thread.
///
/// The conversion is the app's shared auto-stretch ([stretchAsync], normally
/// `LiveStackingService.renderStackPreviewRgba` / `autoStretchPreviewAsync` →
/// the Rust progressive EAA STF with parallel area downsampling), so the
/// preview shows the star field and reveals faint signal as frames stack
/// without blocking the Flutter UI isolate.
class _StackedPreview extends StatefulWidget {
  final Uint16List previewData;
  final int width;
  final int height;
  final int channels;
  final StackedPreviewStretchAsync stretchAsync;
  final String? filterKey;
  final SkotiqColors colors;

  const _StackedPreview({
    required this.previewData,
    required this.width,
    required this.height,
    required this.channels,
    required this.stretchAsync,
    this.filterKey,
    required this.colors,
  });

  static const int _thumbnailMaxDimension = 640;

  @override
  State<_StackedPreview> createState() => _StackedPreviewState();
}

class _StackedPreviewState extends State<_StackedPreview> {
  ui.Image? _displayImage;
  bool _isDecoding = false;
  bool _pendingRebuild = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scheduleBuild();
  }

  @override
  void didUpdateWidget(_StackedPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.previewData, oldWidget.previewData) ||
        widget.width != oldWidget.width ||
        widget.height != oldWidget.height ||
        widget.channels != oldWidget.channels ||
        widget.filterKey != oldWidget.filterKey ||
        widget.stretchAsync != oldWidget.stretchAsync) {
      _scheduleBuild();
    }
  }

  @override
  void dispose() {
    _generation++;
    _displayImage?.dispose();
    super.dispose();
  }

  void _scheduleBuild() {
    _generation++;
    if (_isDecoding) {
      _pendingRebuild = true;
      return;
    }
    unawaited(_buildDisplayImage());
  }

  Future<void> _buildDisplayImage() async {
    _isDecoding = true;
    _pendingRebuild = false;
    final gen = _generation;

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

    try {
      final StretchedPreviewFrame stretched = await widget.stretchAsync(
        width: w,
        height: h,
        data: data,
        channels: samplesPerPixel,
        maxDimension: _StackedPreview._thumbnailMaxDimension,
        filterKey: widget.filterKey,
      );
      if (!mounted || gen != _generation) return;

      final outW = stretched.width;
      final outH = stretched.height;
      final expectedBytes = outW * outH * 4;
      if (outW <= 0 || outH <= 0 || stretched.rgba.length < expectedBytes) {
        Log.warning(
          '[StackingPanel] Stretched preview is ${stretched.rgba.length} '
          'bytes, expected $expectedBytes',
          source: 'StackingPanel',
        );
        return;
      }

      final buffer = await ui.ImmutableBuffer.fromUint8List(stretched.rgba);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: outW,
        height: outH,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();

      if (!mounted || gen != _generation) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _displayImage?.dispose();
        _displayImage = frame.image;
      });
    } catch (e) {
      Log.warning(
        '[StackingPanel] Error building preview image: $e',
        source: 'StackingPanel',
        error: e,
      );
    } finally {
      _isDecoding = false;
      if (mounted && _pendingRebuild) {
        _pendingRebuild = false;
        unawaited(_buildDisplayImage());
      }
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
                child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 20),
              ),
              const SizedBox(height: 8),
              Text(
                'Rendering preview...',
                style: SkotiqTypography.caption.copyWith(
                  color: widget.colors.textMuted,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        child: AspectRatio(
          aspectRatio: widget.width / widget.height,
          child: RawImage(
            image: _displayImage,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}

/// Renders a u16 stacked buffer to display-ready RGBA8.
///
/// `channels` is `1` (luminance plane) or `3` (interleaved RGB16). Kept for
/// test overrides and callers that expect a synchronous signature; production
/// rendering goes through [stackedPreviewStretchAsyncProvider] so stretching
/// and downscaling run off the Flutter UI thread in Rust.
typedef StackedPreviewStretch = Uint8List Function({
  required int width,
  required int height,
  required List<int> data,
  required int channels,
});

/// Async, off-UI-thread preview stretcher with optional native downscaling.
typedef StackedPreviewStretchAsync = Future<StretchedPreviewFrame> Function({
  required int width,
  required int height,
  required Uint16List data,
  required int channels,
  int maxDimension,
  String? filterKey,
});

final _defaultSyncPreviewStretchProvider = Provider<StackedPreviewStretch>(
  (ref) {
    final service = ref.watch(liveStackingServiceProvider);
    return ({
      required int width,
      required int height,
      required List<int> data,
      required int channels,
    }) =>
        service.autoStretchPreview(
          width: width,
          height: height,
          data: data,
          channels: channels,
        );
  },
);

/// Injection point for [StackedPreviewStretch]; overridden in tests so the
/// preview can be exercised without the native library.
final stackedPreviewStretchProvider = Provider<StackedPreviewStretch>(
  (ref) => ref.watch(_defaultSyncPreviewStretchProvider),
);

/// Production off-UI-thread stretcher for live stack canvases and previews.
///
/// When [stackedPreviewStretchProvider] has not been overridden (production),
/// this runs entirely off the Flutter UI isolate on the Rust worker thread pool
/// with Rayon parallel area downscaling (and zero-u16-copy cached native
/// F32 progressive rendering when a local [filterKey] stack slot is available).
/// When a widget test overrides [stackedPreviewStretchProvider], this seamlessly
/// delegates to that test override.
final stackedPreviewStretchAsyncProvider = Provider<StackedPreviewStretchAsync>(
  (ref) {
    final syncStretch = ref.watch(stackedPreviewStretchProvider);
    final defaultSyncStretch = ref.watch(_defaultSyncPreviewStretchProvider);
    if (!identical(syncStretch, defaultSyncStretch)) {
      return ({
        required int width,
        required int height,
        required Uint16List data,
        required int channels,
        int maxDimension = 2048,
        String? filterKey,
      }) async {
        final rgba = syncStretch(
          width: width,
          height: height,
          data: data,
          channels: channels,
        );
        return StretchedPreviewFrame(
          width: width,
          height: height,
          channels: channels,
          rgba: rgba,
        );
      };
    }

    final service = ref.watch(liveStackingServiceProvider);
    final isRemote = ref.watch(isRemoteModeProvider);
    return ({
      required int width,
      required int height,
      required Uint16List data,
      required int channels,
      int maxDimension = 2048,
      String? filterKey,
    }) async {
      if (!isRemote && filterKey != null && filterKey.isNotEmpty) {
        try {
          return await service.renderStackPreviewRgba(
            filterKey: filterKey,
            maxDimension: maxDimension,
          );
        } catch (_) {
          // Fall through to async buffer stretch when the native slot is not
          // present (e.g. restored or synthetic snapshot).
        }
      }
      return service.autoStretchPreviewAsync(
        width: width,
        height: height,
        data: data,
        channels: channels,
        maxDimension: maxDimension,
      );
    };
  },
);

part of '../darkroom_editor.dart';

/// The Darkroom's picture. Widget tests count these to assert how many panes
/// are mounted.
const Key kDarkroomPreviewSurfaceKey = Key('darkroom-preview-surface');

/// One render's pixels, held on screen until the next render's are ready.
///
/// **Why the Darkroom does not use the shared `AstroImageViewer`.** That viewer
/// decodes the buffer it is handed and shows a spinner while it runs. For a
/// gallery that is right — there is nothing else to show. For an editor it is
/// not: every parameter change produces a new buffer, so the picture the
/// operator is judging the change AGAINST disappeared once per render and a
/// slider drag strobed. In blink compare it destroyed the mode outright: each
/// tick showed the other recipe, and between the two frames the eye is supposed
/// to compare there was a blank one for roughly half of every cycle.
///
/// So this surface holds two buffers. [_shown] keeps painting — at the
/// operator's own zoom and pan — while the incoming buffer decodes, and the
/// swap happens on the frame the new image is ready. A small tag says a newer
/// frame is on its way, so "the picture is a moment behind" is stated rather
/// than left to be inferred from a picture that has not changed.
///
/// The transform is the CALLER's: the viewport drives it from its fit / 1:1 /
/// zoom controls, and the compare panes share one so two viewers cannot
/// disagree about where the operator is looking. This surface writes it once,
/// to fit the first frame it decodes, and never again.
class _DarkroomImageSurface extends StatefulWidget {
  /// The render to paint.
  final DarkroomPreviewImage preview;

  /// The view transform, owned by the caller.
  final TransformationController transform;

  /// Narrowest zoom, before the fit scale is taken into account.
  final double minScale;

  /// Widest zoom.
  final double maxScale;

  const _DarkroomImageSurface({
    required this.preview,
    required this.transform,
    required this.minScale,
    required this.maxScale,
  });

  @override
  State<_DarkroomImageSurface> createState() => _DarkroomImageSurfaceState();
}

class _DarkroomImageSurfaceState extends State<_DarkroomImageSurface> {
  /// The frame being painted. Null only until the first decode lands.
  ui.Image? _shown;

  /// The buffer [_shown] was decoded from, so a rebuild carrying the same
  /// pixels is told apart from a new render.
  Uint8List? _shownFrom;

  /// The buffer a decode is running for, null when none is.
  Uint8List? _decoding;

  /// Why the newest buffer produced no image. Null when the last decode
  /// succeeded.
  String? _decodeError;

  /// True once this surface has fitted a frame to its box.
  bool _fitted = false;

  /// A post-frame fit is already scheduled; layout must not queue a second.
  bool _fitScheduled = false;

  @override
  void initState() {
    super.initState();
    _startDecode();
  }

  @override
  void didUpdateWidget(covariant _DarkroomImageSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.preview.rgba;
    if (identical(incoming, _shownFrom) || identical(incoming, _decoding)) {
      return;
    }
    _startDecode();
  }

  @override
  void dispose() {
    _shown?.dispose();
    super.dispose();
  }

  /// Begin decoding the buffer this widget now carries.
  ///
  /// The fields are written directly rather than through `setState`: both
  /// callers are [initState] and [didUpdateWidget], each of which is followed
  /// by a build. Only the completion, which arrives outside a build, asks for
  /// one.
  void _startDecode() {
    final preview = widget.preview;
    final data = preview.rgba;
    if (data.isEmpty || preview.width <= 0 || preview.height <= 0) {
      _decoding = null;
      _decodeError = 'The render answered with a ${preview.width}×'
          '${preview.height} image and ${data.length} bytes of pixels, which is '
          'not a picture this build can draw.';
      return;
    }
    _decoding = data;
    _decodeError = null;
    unawaited(_decode(preview, data));
  }

  Future<void> _decode(DarkroomPreviewImage preview, Uint8List data) async {
    final ui.Image image;
    try {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        data,
        preview.width,
        preview.height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      image = await completer.future;
    } catch (error) {
      if (!mounted || !identical(_decoding, data)) return;
      // The previous frame stays up and says why it is still the newest one on
      // screen — dropping to an empty canvas would throw away the last picture
      // this editor is known to have drawn correctly.
      setState(() {
        _decoding = null;
        _decodeError = 'The newest render could not be decoded into an image: '
            '$error';
      });
      return;
    }

    if (!mounted || !identical(_decoding, data)) {
      // Superseded while it decoded, or this surface is gone. These pixels are
      // never painted, so the handle is released here rather than left to the
      // collector.
      image.dispose();
      return;
    }
    final previous = _shown;
    setState(() {
      _shown = image;
      _shownFrom = data;
      _decoding = null;
    });
    // After the swap, never before: the render tree read `previous` on the last
    // frame it painted.
    previous?.dispose();
  }

  /// Fit the decoded frame to [box], once.
  ///
  /// Called from a post-frame callback, never from the layout callback that
  /// measured [box]: the transform is the caller's and its listeners call
  /// setState, and notifying them from inside layout wedges the enclosing
  /// panel's build scope in release builds.
  void _fitToBox(Size box) {
    final shown = _shown;
    if (shown == null || _fitted) return;
    if (box.width <= 0 || box.height <= 0) return;
    if (shown.width <= 0 || shown.height <= 0) return;
    final scaleX = box.width / shown.width;
    final scaleY = box.height / shown.height;
    final fit = scaleX < scaleY ? scaleX : scaleY;
    widget.transform.value = Matrix4.identity()
      ..translateByDouble(
        (box.width - shown.width * fit) / 2,
        (box.height - shown.height * fit) / 2,
        0,
        1.0,
      )
      ..scaleByDouble(fit, fit, 1.0, 1.0);
    _fitted = true;
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final error = _decodeError;
    return Stack(
      key: kDarkroomPreviewSurfaceKey,
      fit: StackFit.expand,
      children: [
        if (shown == null)
          error == null
              ? const Center(
                  child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36))
              : EmptyState.compact(
                  icon: SkotiqIcons.imageOff,
                  title: 'This render produced no picture',
                  body: error,
                )
        else
          _viewer(shown),
        // Subtle, and only while the picture below is one render behind.
        if (shown != null && _decoding != null)
          const Positioned(
            top: SkotiqTokens.spaceSm,
            left: SkotiqTokens.spaceSm,
            child: _DarkroomTag(
              label: 'New frame…',
              tooltip: 'The newest render has landed and its pixels are being '
                  'decoded. The picture below is the previous one until they '
                  'are ready, so nothing here is ever blank between two '
                  'frames.',
            ),
          ),
        if (shown != null && error != null)
          Positioned(
            top: SkotiqTokens.spaceSm,
            left: SkotiqTokens.spaceSm,
            child: _DarkroomTag(
              label: 'Showing the previous frame',
              tooltip: error,
            ),
          ),
      ],
    );
  }

  Widget _viewer(ui.Image shown) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final scaleX = shown.width <= 0 ? 1.0 : box.width / shown.width;
        final scaleY = shown.height <= 0 ? 1.0 : box.height / shown.height;
        final fitScale =
            box.isEmpty ? 1.0 : (scaleX < scaleY ? scaleX : scaleY);
        // A fit that is wider than the configured floor would otherwise leave
        // the picture unable to zoom out far enough to be seen whole.
        final effectiveMin =
            fitScale < widget.minScale ? fitScale : widget.minScale;

        if (!_fitted && !_fitScheduled && !box.isEmpty) {
          _fitScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _fitScheduled = false;
            if (mounted) _fitToBox(box);
          });
        }

        return InteractiveViewer(
          transformationController: widget.transform,
          minScale: effectiveMin,
          maxScale: widget.maxScale,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          child: Center(
            // Image DATA: red night re-emits the master's luminance on the red
            // axis rather than lighting the room with the frame.
            child: RedNightImage(
              child: CustomPaint(
                painter: _DarkroomImagePainter(shown),
                size: Size(shown.width.toDouble(), shown.height.toDouble()),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Draws one decoded frame at its own pixel size.
///
/// A painter rather than a [RawImage] because the image handle is owned by
/// [_DarkroomImageSurfaceState], which disposes it when the next frame takes
/// over; `RenderImage` takes ownership of what it is given and would dispose it
/// first.
class _DarkroomImagePainter extends CustomPainter {
  final ui.Image image;

  const _DarkroomImagePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_DarkroomImagePainter oldDelegate) =>
      oldDelegate.image != image;
}

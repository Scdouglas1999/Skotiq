// Live frame viewer, zoom readout and viewer control widgets.
part of '../live_frame_panel.dart';

/// Interactive image area: button-driven zoom + drag pan, wheel-zoom disabled.
class _LiveFrameViewer extends StatefulWidget {
  final CapturedImageData image;
  final SkotiqColors colors;

  const _LiveFrameViewer({required this.image, required this.colors});

  @override
  State<_LiveFrameViewer> createState() => _LiveFrameViewerState();
}

class _LiveFrameViewerState extends State<_LiveFrameViewer> {
  final TransformationController _controller = TransformationController();

  static const double _minScale = 1.0;
  static const double _maxScale = 8.0;
  static const double _zoomStep = 1.6;

  double _scale = 1.0;

  @override
  void didUpdateWidget(covariant _LiveFrameViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A brand-new frame resets the view so the operator always sees the full
    // fresh sub-exposure rather than a stale zoom/pan from the previous frame.
    if (oldWidget.image != widget.image) {
      _reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _reset() {
    _controller.value = Matrix4.identity();
    if (mounted) {
      setState(() => _scale = 1.0);
    } else {
      _scale = 1.0;
    }
  }

  /// Zoom around the centre of the viewport by [factor], keeping the image
  /// clamped within bounds (InteractiveViewer's `constrained: true` handles the
  /// pan clamp; we re-centre the focal point so zoom feels anchored).
  void _zoomBy(double factor, Size viewport) {
    final current = _controller.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(_minScale, _maxScale);
    if (target == current) return;

    if (target <= _minScale) {
      _reset();
      return;
    }

    final focal = Offset(viewport.width / 2, viewport.height / 2);
    final change = target / current;
    final next = Matrix4.identity()
      ..translateByDouble(focal.dx, focal.dy, 0, 1.0)
      ..scaleByDouble(change, change, 1.0, 1.0)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1.0);
    _controller.value = next * _controller.value;
    setState(() => _scale = target);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        // Decode only as many pixels as the panel can actually show. A ~300px
        // tile never needs a full sensor-resolution texture; the source width
        // clamp lives in ImageDisplayWidget so this is just the upper bound.
        final targetWidth =
            (viewport.width * devicePixelRatio).round().clamp(1, 1 << 30);
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _controller,
                // Pinch scaling is enabled; `constrained: true` keeps the
                // scaled child clamped inside the viewport so it can never be
                // flung off-canvas. The readout/buttons track the live scale
                // via onInteractionUpdate.
                scaleEnabled: true,
                panEnabled: true,
                // `constrained: true` keeps the (scaled) child inside the
                // viewport, which clamps the pan so the image can't be dragged
                // fully off-canvas.
                constrained: true,
                minScale: _minScale,
                maxScale: _maxScale,
                onInteractionUpdate: (_) {
                  final live = _controller.value.getMaxScaleOnAxis();
                  if ((live - _scale).abs() > 0.001) {
                    setState(() => _scale = live);
                  }
                },
                child: ImageDisplayWidget(
                  imageData: widget.image,
                  zoomLevel: 1.0,
                  panOffset: Offset.zero,
                  targetWidth: targetWidth,
                ),
              ),
            ),
            // Zoom percentage readout.
            Positioned(
              left: 8,
              top: 8,
              child: _ZoomReadout(colors: colors, scale: _scale),
            ),
            // Zoom / fit controls.
            Positioned(
              left: 8,
              bottom: 8,
              child: _ViewerControls(
                colors: colors,
                canZoomOut: _scale > _minScale + 0.001,
                canZoomIn: _scale < _maxScale - 0.001,
                onZoomIn: () => _zoomBy(_zoomStep, viewport),
                onZoomOut: () => _zoomBy(1 / _zoomStep, viewport),
                onFit: _reset,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ZoomReadout extends StatelessWidget {
  final SkotiqColors colors;
  final double scale;

  const _ZoomReadout({required this.colors, required this.scale});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        border: Border.all(color: colors.border.withValues(alpha: 0.5)),
      ),
      child: Text(
        '${(scale * 100).round()}%',
        style: SkotiqTypography.withTabular(
          SkotiqTypography.captionSm.copyWith(
            fontWeight: FontWeight.w600,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _ViewerControls extends StatelessWidget {
  final SkotiqColors colors;
  final bool canZoomIn;
  final bool canZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;

  const _ViewerControls({
    required this.colors,
    required this.canZoomIn,
    required this.canZoomOut,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ControlButton(
            colors: colors,
            icon: LucideIcons.zoomOut,
            tooltip: 'Zoom out',
            onPressed: canZoomOut ? onZoomOut : null,
          ),
          _ControlDivider(colors: colors),
          _ControlButton(
            colors: colors,
            icon: LucideIcons.maximize,
            tooltip: 'Fit to view',
            onPressed: onFit,
          ),
          _ControlDivider(colors: colors),
          _ControlButton(
            colors: colors,
            icon: LucideIcons.zoomIn,
            tooltip: 'Zoom in',
            onPressed: canZoomIn ? onZoomIn : null,
          ),
        ],
      ),
    );
  }
}

class _ControlDivider extends StatelessWidget {
  final SkotiqColors colors;
  const _ControlDivider({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      color: colors.border.withValues(alpha: 0.5),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _ControlButton({
    required this.colors,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(
            icon,
            // Bumped from 16 to 20 so the zoom controls are comfortably
            // tappable on a touch tablet.
            size: 20,
            color: enabled ? colors.textSecondary : colors.textMuted,
          ),
        ),
      ),
    );
  }
}

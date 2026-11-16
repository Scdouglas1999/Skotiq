// The glass groups FramingCanvasChrome places: the toolbar (survey and layers),
// the status group (scale bar, then the survey's notice or credit) and zoom.
part of '../framing_canvas.dart';

/// The canvas layers the Layers menu turns on and off.
enum FramingLayer {
  crosshair('Crosshair'),
  grid('Coordinate grid'),
  targetLabel('Target label'),
  directions('Sky directions'),
  guideStars('Guide stars'),
  surveyTiles('Deep survey tiles');

  const FramingLayer(this.label);

  final String label;
}

/// Top right: the survey picker and the Layers menu, in one glass group.
class _FramingToolbar extends ConsumerWidget {
  final FramingState framingState;
  final bool hasEquipment;

  const _FramingToolbar({
    required this.framingState,
    required this.hasEquipment,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(framingProvider.notifier);
    final source = framingState.surveySource;
    final tilesOffered = hipsSurveyIsTileCapable(source);
    final on = <FramingLayer, bool>{
      FramingLayer.crosshair:
          ref.watch(imagingViewerStateProvider).showCrosshair,
      FramingLayer.grid: framingState.showGrid,
      FramingLayer.targetLabel: framingState.showLabels,
      // The directions are drawn inside the camera frame, so they need one.
      if (hasEquipment)
        FramingLayer.directions: framingState.showCardinalDirections,
      FramingLayer.guideStars: framingState.showGuideStars,
      if (tilesOffered)
        FramingLayer.surveyTiles: ref.watch(hipsFramingEnabledProvider),
    };

    void toggle(FramingLayer layer) {
      switch (layer) {
        case FramingLayer.crosshair:
          ref.read(imagingViewerStateProvider.notifier).toggleCrosshair();
        case FramingLayer.grid:
          notifier.toggleGrid();
        case FramingLayer.targetLabel:
          notifier.toggleLabels();
        case FramingLayer.directions:
          notifier.toggleCardinalDirections();
        case FramingLayer.guideStars:
          notifier.toggleGuideStars();
        case FramingLayer.surveyTiles:
          final tiles = ref.read(hipsFramingEnabledProvider.notifier);
          tiles.state = !tiles.state;
      }
    }

    return Glass(
      padding: const EdgeInsets.all(SkotiqTokens.spaceXs),
      child: SkotiqToolbar(
        groups: [
          [
            SkotiqMenuChip<SurveySource>(
              name: 'Survey',
              label: source.displayName,
              icon: SkotiqIcons.image,
              entries: [
                for (final s in SurveySource.values)
                  SkotiqMenuChoice(s, s.displayName, checked: s == source),
              ],
              onSelected: notifier.setSurveySource,
            ),
          ],
          [
            SkotiqMenuButton<FramingLayer>(
              icon: SkotiqIcons.layers,
              tooltip: 'Layers',
              size: IconButtonSize.sm,
              entries: [
                for (final MapEntry(key: layer, value: shown) in on.entries)
                  SkotiqMenuChoice(layer, layer.label, checked: shown),
              ],
              onSelected: toggle,
            ),
          ],
        ],
      ),
    );
  }
}

/// Bottom left: the scale bar, then one line about the survey image: why it
/// is missing, that it is loading, or the credit its publisher asks for.
class _FramingStatus extends ConsumerWidget {
  final FramingState framingState;
  final FramingPlateScale plateScale;
  final Size canvasSize;

  const _FramingStatus({
    required this.framingState,
    required this.plateScale,
    required this.canvasSize,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Glass(
      child: Builder(
        builder: (context) {
          final colors = context.skotiqColors;
          final Widget? surveyLine;
          if (framingState.imageError case final error?) {
            surveyLine = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  SkotiqIcons.warning,
                  size: SkotiqTokens.iconXs,
                  color: colors.warning,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Flexible(
                  child: Text(
                    error,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textSecondary),
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                SkotiqButton(
                  label: 'Retry',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  onPressed: framingState.isLoadingImage
                      ? null
                      : () =>
                          ref.read(framingProvider.notifier).loadSurveyImage(),
                ),
              ],
            );
          } else if (framingState.isLoadingImage) {
            surveyLine = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SkotiqSpinner(size: SkotiqTokens.iconXs, color: colors.primary),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Flexible(
                  child: Text(
                    'Loading ${framingState.surveySource.displayName}…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textSecondary),
                  ),
                ),
              ],
            );
          } else {
            surveyLine = null;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _ScaleIndicator(
                colors: colors,
                zoom: framingState.zoom,
                plateScale: plateScale,
                canvasSize: canvasSize,
              ),
              if (surveyLine != null) ...[
                const SizedBox(height: SkotiqTokens.spaceXs),
                surveyLine,
              ] else
                const FramingSurveyCredit(
                  padding: EdgeInsets.only(top: SkotiqTokens.spaceXs),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Bottom right: zoom in, the zoom level, zoom out, and back to the fitted
/// view. A column, or a row on a canvas too short for the column.
class _ZoomControls extends StatelessWidget {
  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  const _ZoomControls({
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  /// The column's height: three buttons, the level, and the glass padding.
  static const double _columnHeight = 3 * SkotiqTokens.iconButtonSizeSm +
      SkotiqTokens.spaceLg +
      2 * SkotiqTokens.spaceXs +
      2 * SkotiqTokens.spaceXs;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final column = constraints.maxHeight >= _columnHeight;
        return Glass(
          padding: const EdgeInsets.all(SkotiqTokens.spaceXs),
          child: Builder(
            builder: (context) {
              final level = Padding(
                padding: column
                    ? const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs)
                    : const EdgeInsets.symmetric(
                        horizontal: SkotiqTokens.spaceXs,
                      ),
                child: Text(
                  '${(zoom * 100).round()}%',
                  style: SkotiqTypography.withTabular(
                    SkotiqTypography.caption
                        .copyWith(color: context.skotiqColors.textSecondary),
                  ),
                ),
              );
              final tooltipPosition = column
                  ? SkotiqTooltipPosition.left
                  : SkotiqTooltipPosition.top;
              final children = [
                SkotiqIconButton(
                  icon: SkotiqIcons.add,
                  tooltip: 'Zoom in',
                  size: IconButtonSize.sm,
                  tooltipPosition: tooltipPosition,
                  onPressed: onZoomIn,
                ),
                level,
                SkotiqIconButton(
                  icon: SkotiqIcons.remove,
                  tooltip: 'Zoom out',
                  size: IconButtonSize.sm,
                  tooltipPosition: tooltipPosition,
                  onPressed: onZoomOut,
                ),
                SkotiqIconButton(
                  icon: SkotiqIcons.expand,
                  tooltip: 'Fit the view',
                  size: IconButtonSize.sm,
                  tooltipPosition: tooltipPosition,
                  onPressed: onReset,
                ),
              ];
              return column
                  ? Column(mainAxisSize: MainAxisSize.min, children: children)
                  : Row(mainAxisSize: MainAxisSize.min, children: children);
            },
          ),
        );
      },
    );
  }
}

/// On-canvas scale bar showing a real angular distance derived from the shared
/// [FramingPlateScale].
///
/// The bar targets a ~60px length, converts that to degrees through
/// [FramingPlateScale.pixelsPerDegree] (the same scale the imagery and overlays
/// use), snaps it to a "nice" arcminute / degree increment, and then sizes the
/// bar to the *exact* on-screen length of that snapped value so the rule and
/// its label always agree.
class _ScaleIndicator extends StatelessWidget {
  final SkotiqColors colors;
  final double zoom;
  final FramingPlateScale plateScale;
  final Size canvasSize;

  const _ScaleIndicator({
    required this.colors,
    required this.zoom,
    required this.plateScale,
    required this.canvasSize,
  });

  /// Candidate scale-bar lengths, in arcminutes, from 1' up to 5°. The renderer
  /// picks the largest entry whose on-screen length does not exceed the target
  /// bar width, so the bar grows and shrinks through familiar astronomical
  /// increments as the user zooms.
  static const List<double> _niceArcminSteps = [
    1,
    2,
    5,
    10,
    15,
    30,
    60,
    120,
    300,
  ];

  /// Target on-screen length of the scale bar, in logical pixels, before
  /// snapping to the nearest nice value.
  static const double _targetBarPx = 60;

  /// Thickness of the bar.
  static const double _barThickness = 3;

  @override
  Widget build(BuildContext context) {
    final pixelsPerDegree =
        canvasSize.isEmpty ? 0.0 : plateScale.pixelsPerDegree(canvasSize, zoom);
    final pixelsPerArcmin = pixelsPerDegree / 60.0;

    // Choose the largest nice step that still fits within the target width;
    // fall back to the smallest step when even 1' is wider than the target
    // (extreme zoom-in) so the bar always represents a real, labelled distance.
    double stepArcmin = _niceArcminSteps.first;
    if (pixelsPerArcmin.isFinite && pixelsPerArcmin > 0) {
      for (final candidate in _niceArcminSteps) {
        if (candidate * pixelsPerArcmin <= _targetBarPx) {
          stepArcmin = candidate;
        } else {
          break;
        }
      }
    }

    final barLength = (stepArcmin * pixelsPerArcmin)
        .clamp(SkotiqTokens.space3xl, _targetBarPx * 1.5);
    final label = _formatScaleLabel(stepArcmin);

    return Semantics(
      label: 'Scale bar, $label',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: barLength,
            height: _barThickness,
            decoration: BoxDecoration(
              color: colors.textSecondary,
              borderRadius: SkotiqTokens.borderRadiusXs,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            label,
            style: SkotiqTypography.withTabular(
              SkotiqTypography.caption.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// Formats an arcminute span as a compact astronomical label: values that are
  /// a whole number of degrees read as e.g. `2°`, otherwise as arcminutes
  /// (`15'`).
  String _formatScaleLabel(double arcmin) {
    if (arcmin >= 60 && arcmin % 60 == 0) {
      return '${(arcmin / 60).toStringAsFixed(0)}°';
    }
    return "${arcmin.toStringAsFixed(0)}'";
  }
}

// Equipment hint card, canvas controls, survey selector, zoom controls and scale indicator.
part of '../framing_canvas.dart';

/// The "no equipment configured" hint card in the canvas's top chrome.
///
/// Lives in the single top-chrome [Column] rather than an inline `Positioned`
/// pinned at a literal `top: 60`, where a wrapped toolbar row could end up
/// underneath it.
class _EquipmentHintCard extends StatelessWidget {
  final NightshadeColors colors;
  final double previewFovDegrees;

  const _EquipmentHintCard({
    required this.colors,
    required this.previewFovDegrees,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: NightshadeTokens.paddingMd,
      decoration: BoxDecoration(
        color:
            colors.info.withValues(alpha: NightshadeTokens.opacityStatusFill),
        borderRadius: NightshadeTokens.borderRadiusMd,
        border: Border.all(
          color: colors.info.withValues(alpha: NightshadeTokens.opacityHalf),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(NightshadeIcons.visible,
              size: NightshadeTokens.iconXs, color: colors.info),
          const SizedBox(width: NightshadeTokens.spaceSm),
          // Flexible so a narrow canvas ellipsizes rather than overflowing.
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Preview: ${previewFovDegrees.toStringAsFixed(1)}° FOV',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NightshadeTypography.labelQuiet
                      .copyWith(color: colors.info),
                ),
                Text(
                  'Configure equipment for accurate framing',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: NightshadeTypography.overline
                      .copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CanvasControls extends StatelessWidget {
  final NightshadeColors colors;
  final FramingState framingState;

  const _CanvasControls({
    required this.colors,
    required this.framingState,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, child) {
        // One toolbar (05 §7): the survey picker in its own group, then the
        // layer toggles as selectable icon buttons. NightshadeToolbar only
        // measures itself when it is given an `overflow` list; with none it is
        // a min-width Row, so on a phone canvas the strip scrolls sideways
        // rather than overflowing (07: reduce content or let it scroll).
        final toggles = <Widget>[
          NightshadeIconButton(
            icon: NightshadeIcons.crosshair,
            tooltip: 'Crosshair',
            size: IconButtonSize.sm,
            selected: ref.watch(imagingViewerStateProvider).showCrosshair,
            onPressed: () =>
                ref.read(imagingViewerStateProvider.notifier).toggleCrosshair(),
          ),
          NightshadeIconButton(
            icon: NightshadeIcons.grid,
            tooltip: 'Grid',
            size: IconButtonSize.sm,
            selected: framingState.showGrid,
            onPressed: () => ref.read(framingProvider.notifier).toggleGrid(),
          ),
          NightshadeIconButton(
            icon: NightshadeIcons.tag,
            tooltip: 'Labels',
            size: IconButtonSize.sm,
            selected: framingState.showLabels,
            onPressed: () => ref.read(framingProvider.notifier).toggleLabels(),
          ),
          // Guide-star finder: highlights bright (V < 10) catalog stars inside
          // the imaging FOV as candidate autoguider guide stars.
          NightshadeIconButton(
            icon: NightshadeIcons.guider,
            tooltip: 'Guide stars',
            size: IconButtonSize.sm,
            selected: framingState.showGuideStars,
            onPressed: () =>
                ref.read(framingProvider.notifier).toggleGuideStars(),
          ),
          // HiPS deep-survey tiles. Only offered for surveys that have a
          // verified HiPS pyramid (the toggle would be inert otherwise — the
          // capability gate, hipsSurveyIsTileCapable, would keep tiles off);
          // for those it flips hipsFramingEnabledProvider, the same user
          // preference hipsFramingActiveProvider combines with the capability
          // gate to mount/unmount the streamed tile mosaic.
          if (hipsSurveyIsTileCapable(framingState.surveySource))
            NightshadeIconButton(
              icon: NightshadeIcons.sparkle,
              tooltip: 'HiPS tiles',
              size: IconButtonSize.sm,
              selected: ref.watch(hipsFramingEnabledProvider),
              onPressed: () {
                final notifier = ref.read(hipsFramingEnabledProvider.notifier);
                notifier.state = !notifier.state;
              },
            ),
        ];

        final Widget toolbar = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: NightshadeToolbar(
            groups: [
              [
                _SurveySourceSelector(
                  colors: colors,
                  source: framingState.surveySource,
                  onChanged: (source) => ref
                      .read(framingProvider.notifier)
                      .setSurveySource(source),
                ),
              ],
              toggles,
            ],
          ),
        );

        if (!framingState.isLoadingImage) return toolbar;

        // The loading pill sits at the trailing edge, outside the toolbar, so
        // it never competes with the toolbar's own overflow measurement.
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: toolbar),
            const SizedBox(width: NightshadeTokens.spaceSm),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: NightshadeTokens.spaceMd,
                  vertical: NightshadeTokens.spaceSm),
              decoration: BoxDecoration(
                color: colors.surfaceOverlay
                    .withValues(alpha: NightshadeTokens.opacityMuted),
                borderRadius: NightshadeTokens.borderRadiusMd,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: NightshadeTokens.iconXs,
                    height: NightshadeTokens.iconXs,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(width: NightshadeTokens.spaceSm),
                  Text(
                    'Loading…',
                    style: NightshadeTypography.labelQuiet
                        .copyWith(color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// On-canvas survey-source picker.
///
/// A [NightshadeDropdown] (the canonical design-system selector) fronted by the
/// `layers` glyph so it reads as part of the chip strip, wired straight to
/// [FramingNotifier.setSurveySource]. Selecting a source refetches the survey
/// imagery for that band (the refetch lives in the notifier).
/// The tight width the survey select needs for its widest option.
///
/// Measured with [NightshadeDropdown.labelStyle] (the style the closed control
/// actually paints its value in) and added to
/// [NightshadeDropdown.chromeWidth] (the padding, chevron, gap and ring the
/// control spends on everything that is not the label), so this cannot drift
/// out of step with the kit the way a literal did.
double _surveySelectorWidth(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context);
  var widest = 0.0;
  for (final source in SurveySource.values) {
    final painter = TextPainter(
      text: TextSpan(
        text: source.displayName,
        style: NightshadeDropdown.labelStyle,
      ),
      textDirection: TextDirection.ltr,
      textScaler: scale,
    )..layout();
    if (painter.width > widest) widest = painter.width;
  }
  return widest + NightshadeDropdown.chromeWidth;
}

class _SurveySourceSelector extends StatelessWidget {
  final NightshadeColors colors;
  final SurveySource source;
  final ValueChanged<SurveySource> onChanged;

  const _SurveySourceSelector({
    required this.colors,
    required this.source,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // The dropdown keys on the enum name and maps back to the enum on change so
    // SurveySource stays the single source of truth (no string parsing of
    // display names).
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceOverlay
            .withValues(alpha: NightshadeTokens.opacityHalf),
        borderRadius: NightshadeTokens.borderRadiusMd,
        border: Border.all(
          color:
              colors.border.withValues(alpha: NightshadeTokens.opacitySubtle),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: NightshadeTokens.spaceMd),
          Icon(
            NightshadeIcons.layers,
            size: NightshadeTokens.iconXs,
            color: colors.textSecondary,
          ),
          const SizedBox(width: NightshadeTokens.spaceXs),
          // A TIGHT width (not just a minimum), MEASURED rather than guessed.
          //
          // Two things depend on it. First: left to size itself in the
          // toolbar, the button is squeezed against the neighbouring chrome
          // and loses the first character of the selection ('DSS2 Red'
          // rendered as ')SS2 Red', '2MASS J' as '?MASS J') — the control
          // misreporting which survey is on screen. Second: `isExpanded` uses
          // an internal Expanded, which asserts on the unbounded width the
          // toolbar hands its children, so the box must be tight rather than a
          // ConstrainedBox(minWidth:).
          //
          // It used to be a hard-coded 148, which went stale the moment the
          // kit's select started counting the gap before its chevron: the
          // label then wanted 112 px inside a box that offered 104.5. So the
          // width now comes from the widest ACTUAL option, laid out in the
          // style the control paints it in, plus the control's own published
          // chrome allowance — both of which the kit exposes for exactly this.
          SizedBox(
            width: _surveySelectorWidth(context),
            child: NightshadeDropdown(
              value: source.name,
              isDense: true,
              isExpanded: true,
              items: SurveySource.values.map((s) => s.name).toList(),
              itemLabels:
                  SurveySource.values.map((s) => s.displayName).toList(),
              onChanged: (name) {
                if (name == null) return;
                onChanged(SurveySource.values.byName(name));
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomControls extends StatelessWidget {
  final NightshadeColors colors;
  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  const _ZoomControls({
    required this.colors,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: NightshadeTokens.paddingXs,
      decoration: BoxDecoration(
        color: colors.surfaceOverlay
            .withValues(alpha: NightshadeTokens.opacityHoverBorder),
        borderRadius: NightshadeTokens.borderRadiusMd,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomButton(
              icon: NightshadeIcons.add, colors: colors, onTap: onZoomIn),
          const SizedBox(height: NightshadeTokens.spaceXs),
          Padding(
            padding:
                const EdgeInsets.symmetric(vertical: NightshadeTokens.spaceXs),
            child: Text(
              '${(zoom * 100).round()}%',
              style: NightshadeTypography.withTabular(
                NightshadeTypography.overline
                    .copyWith(color: colors.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: NightshadeTokens.spaceXs),
          _ZoomButton(
              icon: NightshadeIcons.remove, colors: colors, onTap: onZoomOut),
          const SizedBox(height: NightshadeTokens.spaceXs),
          Container(height: 1, width: 20, color: colors.border),
          const SizedBox(height: NightshadeTokens.spaceXs),
          _ZoomButton(
              icon: NightshadeIcons.expand, colors: colors, onTap: onReset),
        ],
      ),
    );
  }
}

class _ZoomButton extends StatefulWidget {
  final IconData icon;
  final NightshadeColors colors;
  final VoidCallback onTap;

  const _ZoomButton({
    required this.icon,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_ZoomButton> createState() => _ZoomButtonState();
}

class _ZoomButtonState extends State<_ZoomButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NightshadeTokens.durationQuick,
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _isHovered ? widget.colors.well : Colors.transparent,
            borderRadius: NightshadeTokens.borderRadiusXs,
          ),
          child: Icon(
            widget.icon,
            size: NightshadeTokens.iconXs,
            color: widget.colors.textSecondary,
          ),
        ),
      ),
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
  final NightshadeColors colors;
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
        .clamp(NightshadeTokens.space3xl, _targetBarPx * 1.5);

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: NightshadeTokens.spaceMd,
          vertical: NightshadeTokens.spaceSm),
      decoration: BoxDecoration(
        color: colors.surfaceOverlay
            .withValues(alpha: NightshadeTokens.opacityHoverBorder),
        borderRadius: NightshadeTokens.borderRadiusMd,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Scale',
            style:
                NightshadeTypography.overline.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: NightshadeTokens.spaceXs),
          Row(
            children: [
              Container(
                width: barLength,
                height: 3,
                decoration: BoxDecoration(
                  color: colors.textSecondary,
                  borderRadius: NightshadeTokens.borderRadiusXs,
                ),
              ),
              const SizedBox(width: NightshadeTokens.spaceXs),
              Text(
                _formatScaleLabel(stepArcmin),
                style: NightshadeTypography.withTabular(
                  NightshadeTypography.labelQuiet
                      .copyWith(color: colors.textSecondary),
                ),
              ),
            ],
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

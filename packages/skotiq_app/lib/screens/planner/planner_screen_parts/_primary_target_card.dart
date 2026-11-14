// The Tonight tab's detail column: the selected target's field, its four
// readouts, its altitude tonight, its facts, and the one pair of actions.
part of '../planner_screen.dart';

/// The 380px column beside the candidate list.
///
/// Everything on it describes the ONE selected target. The page's single
/// primary action — "Build sequence" — lives at the bottom of it (06 §Plan).
class _TargetDetailColumn extends ConsumerWidget {
  final TargetSuggestion target;
  final SessionOptimizationPlan plan;

  final VoidCallback onFrameIt;
  final VoidCallback onBuildSequence;

  const _TargetDetailColumn({
    required this.target,
    required this.plan,
    required this.onFrameIt,
    required this.onBuildSequence,
  });

  /// Height of the field preview at the top of the column.
  ///
  /// The well holds only the target's extent against the frame, never a sky
  /// image, so at 150px it was mostly empty dark box while the facts below
  /// were pushed out under the action footer.
  static const double _previewHeight = 96;

  /// Height of the altitude well, its degree and clock scales included.
  static const double _altitudeHeight = 128;

  bool get _isOptimizerPick => plan.primaryTarget?.targetId == target.targetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final visibility = target.visibility;
    final minAltitude =
        ref.watch(suggestionFilterProvider).minCurrentAltitude ??
            _kPlannerDefaultMinAltitude;

    final content = <Widget>[
      SizedBox(
        height: _previewHeight,
        child: _TargetFieldPreview(target: target),
      ),
      const SizedBox(height: SkotiqTokens.spaceMd),
      Text(
        target.targetName,
        style: SkotiqTypography.pageTitle.copyWith(
          color: colors.textPrimary,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      Text(
        _candidateDetailLine(target),
        style: SkotiqTypography.bodySm.copyWith(
          color: colors.textSecondary,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: SkotiqTokens.spaceMd),
      ReadoutRow(
        gap: SkotiqTokens.spaceMd,
        children: [
          Readout(
            value: visibility.currentAltitude.toStringAsFixed(1),
            unit: '°',
            label: l10n.text('plannerAltNow'),
          ),
          Readout(
            value: visibility.transitAltitude?.round().toString(),
            unit: '°',
            label: l10n.text('plannerColTransit'),
          ),
          Readout(
            value: _hoursAndMinutes(visibility.hoursAboveMinAlt),
            label: l10n.text('plannerWindow'),
          ),
          Readout(
            value: visibility.moonDistance.round().toString(),
            unit: '°',
            label: l10n.text('plannerFromMoon'),
          ),
        ],
      ),
      const SizedBox(height: SkotiqTokens.spaceMd),
      SizedBox(
        height: _altitudeHeight,
        child: _TargetAltitudeWell(target: target, minAltitude: minAltitude),
      ),
      const SizedBox(height: SkotiqTokens.spaceMd),
      KeyValueList(rows: _facts(context, ref)),
      // The sensor the exposure above was computed from, and where each of its
      // figures came from. It belongs beside the exposure, not on a settings
      // screen: this is the number the owner found the app calling unknown.
      const CameraSensorSpecsRow(),
      if (target.warnings.isNotEmpty) ...[
        const SizedBox(height: SkotiqTokens.spaceMd),
        // ONE banner for the target's problems, not one per warning: the
        // loudest warning is the title and the rest ride on it.
        SkotiqBanner(
          title: target.warnings.first.message,
          message: target.warnings.length > 1
              ? target.warnings.skip(1).map((w) => w.message).join(' · ')
              : null,
          tone: _bannerTone(target.warnings.first.severity),
        ),
      ],
      // The optimizer's reasoning belongs to the optimizer's PICK, not to
      // whichever row the user has selected — the old screen showed it under a
      // hero card a search could have replaced, so it explained numbers that
      // were not on screen. It appears here only when the two agree.
      if (_isOptimizerPick && plan.rationale.isNotEmpty) ...[
        const SizedBox(height: SkotiqTokens.spaceMd),
        SectionTitle(
          icon: LucideIcons.lightbulb,
          title: l10n.text(
            'plannerRationaleSubtitleNamed',
            params: {'target': target.targetName},
          ),
        ),
        for (var i = 0; i < plan.rationale.length; i++)
          ListRow(
            title: plan.rationale[i],
            showDivider: i < plan.rationale.length - 1,
          ),
      ],
    ];

    final actions = Row(
      children: [
        Expanded(
          child: SkotiqButton(
            label: l10n.text('plannerFrameIt'),
            icon: LucideIcons.crop,
            variant: ButtonVariant.secondary,
            onPressed: onFrameIt,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: SkotiqButton(
            label: l10n.text('plannerBuildSequence'),
            icon: LucideIcons.listOrdered,
            variant: ButtonVariant.primary,
            onPressed: onBuildSequence,
          ),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: content,
            ),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        actions,
      ],
    );
  }

  /// The facts under the readouts. Only rows the app actually knows are
  /// listed; a row with nothing behind it is left out rather than filled with
  /// a placeholder.
  List<(String, String)> _facts(
    BuildContext context,
    WidgetRef ref,
  ) {
    final l10n = context.l10n;
    final preview =
        ref.watch(plannerTargetIntegrationPreviewProvider(target.targetId));
    final estimated = preview.valueOrNull;
    // The plan's filters and sub length are its primary target's; another
    // selected row quotes its own estimate, or nothing it does not have.
    final isPrimary = plan.primaryTarget?.targetId == target.targetId;
    final filters = estimated != null && estimated.filterNames.isNotEmpty
        ? estimated.filterNames.join('  ')
        : !isPrimary
            ? null
            : plan.recommendedFilterNames.isNotEmpty
                ? plan.recommendedFilterNames.join('  ')
                : plan.recommendedFilterName;
    final exposureSeconds = estimated != null && estimated.subExposureSecs > 0
        ? estimated.subExposureSecs
        : isPrimary
            ? plan.recommendedExposureSeconds
            : null;

    return <(String, String)>[
      if (target.objectType != null)
        (l10n.text('plannerKvObjectType'), target.objectType!),
      if (target.constellation != null)
        (l10n.text('plannerKvConstellation'), target.constellation!),
      if (target.magnitude != null)
        (
          l10n.text('plannerKvMagnitude'),
          target.magnitude!.toStringAsFixed(1),
        ),
      if (target.sizeArcmin != null && target.sizeArcmin! > 0)
        (l10n.text('plannerKvSize'), _formatSizeLabel(target.sizeArcmin)),
      if (filters != null) (l10n.text('plannerKvSuggestedFilters'), filters),
      if (exposureSeconds != null && exposureSeconds > 0)
        (l10n.text('plannerKvExposure'), '${exposureSeconds.round()} s'),
      if (estimated != null && estimated.estimatedIntegrationHours > 0)
        (
          l10n.text('plannerKvEstimatedIntegration'),
          _hoursAndMinutes(estimated.estimatedIntegrationHours) ??
              kReadoutUnknown,
        ),
    ];
  }

  BannerTone _bannerTone(WarningSeverity severity) {
    switch (severity) {
      case WarningSeverity.critical:
        return BannerTone.error;
      case WarningSeverity.warning:
        return BannerTone.warning;
      case WarningSeverity.caution:
      case WarningSeverity.info:
        return BannerTone.info;
    }
  }
}

/// The compact altitude curve in the middle of the detail column.
///
/// One `well` holding the altitude line on a 0 to 90° scale with degree
/// labels and a clock scale, the minimum altitude the filters ask for as the
/// reference line, astronomical dusk and dawn as dashed markers, and "now". `AltitudeChart` (the Framing tab's) is the full instrument —
/// a header, an airmass toggle, its own Alt/Airmass chips and a
/// rise/transit/set block, some 350px of it — so it would both overflow this
/// 110px slot and repeat the four readouts directly above it.
class _TargetAltitudeWell extends ConsumerWidget {
  final TargetSuggestion target;
  final double minAltitude;

  const _TargetAltitudeWell({required this.target, required this.minAltitude});

  /// How many points the curve is sampled at across the night.
  static const int _samples = 60;

  /// How far either side of the night the curve is sampled, so it enters and
  /// leaves the frame instead of starting mid-air at the dusk edge.
  static const Duration _margin = Duration(hours: 1);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final location = ref.watch(appObserverLocationProvider);
    final night = ref.watch(_plannerNightWindowProvider);

    // No site means no altitude at all. Say so, rather than draw a flat line at
    // zero that reads as "your target is on the horizon".
    if (plannerSiteUnset(location) || night == null) {
      return DecoratedBox(
        decoration: SkotiqDecorations.well(colors),
        child: Center(
          child: Text(
            context.l10n.text('plannerNoSiteTitle'),
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textMuted,
            ),
          ),
        ),
      );
    }

    final from = night.start.subtract(_margin);
    final to = night.end.add(_margin);
    final span = to.difference(from).inSeconds;
    final points = <(DateTime, double?)>[];
    for (var i = 0; i < _samples; i++) {
      final t = from.add(
        Duration(seconds: (span * i / (_samples - 1)).round()),
      );
      final (alt, _) = AstronomyCalculations.objectAltAz(
        raDeg: target.raHours * 15.0,
        decDeg: target.decDegrees,
        dt: t,
        latitudeDeg: location!.latitude,
        longitudeDeg: location.longitude,
      );
      points.add((t, alt.clamp(0.0, 90.0)));
    }

    final now = DateTime.now();
    return DecoratedBox(
      decoration: SkotiqDecorations.well(colors),
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceXs),
        child: NightChartAxes(
          from: from,
          to: to,
          zeroLineY: minAltitude,
          leftTicks: const <double>[0, 30, 60, 90],
          leftUnit: '°',
          lines: <SeriesChartLine>[
            SeriesChartLine(
              points: points,
              tone: SeriesChartTone.primary,
              minY: 0,
              maxY: 90,
            ),
          ],
          markers: <SeriesChartMarker>[
            SeriesChartMarker(night.start),
            SeriesChartMarker(night.end),
            if (now.isAfter(from) && now.isBefore(to))
              SeriesChartMarker(now, tone: SeriesChartTone.secondary),
          ],
          semanticLabel: context.l10n.text(
            'plannerAltitudeChartSem',
            params: {
              'name': target.targetName,
              'deg': minAltitude.round().toString(),
            },
          ),
        ),
      ),
    );
  }
}

/// How a target of [sizeArcmin] sits in a camera field of [fieldWidthArcmin]
/// by [fieldHeightArcmin]: inside the short side with room around it, filling
/// the short side, or larger than it and needing a mosaic of [columns] by
/// [rows] panels at the mosaic planner's default overlap.
@immutable
class PlannerFieldFit {
  const PlannerFieldFit._(this.kind, {this.columns = 1, this.rows = 1});

  final PlannerFieldFitKind kind;
  final int columns;
  final int rows;

  /// The share of the short side a target may take and still leave room to
  /// frame it.
  static const double _roomy = 0.8;

  static PlannerFieldFit? of({
    required double? sizeArcmin,
    required double fieldWidthArcmin,
    required double fieldHeightArcmin,
  }) {
    if (sizeArcmin == null || sizeArcmin <= 0) return null;
    final long = math.max(fieldWidthArcmin, fieldHeightArcmin);
    final short = math.min(fieldWidthArcmin, fieldHeightArcmin);
    if (sizeArcmin <= short * _roomy) {
      return const PlannerFieldFit._(PlannerFieldFitKind.fits);
    }
    if (sizeArcmin <= short) {
      return const PlannerFieldFit._(PlannerFieldFitKind.fills);
    }
    final (rows, columns) = MosaicPlanner.calculatePanelCount(
      totalWidth: sizeArcmin,
      totalHeight: sizeArcmin,
      panelWidth: long,
      panelHeight: short,
    );
    return PlannerFieldFit._(
      PlannerFieldFitKind.mosaic,
      columns: columns,
      rows: rows,
    );
  }

  String get label => switch (kind) {
        PlannerFieldFitKind.fits => 'Fits the frame',
        PlannerFieldFitKind.fills => 'Fills the frame',
        PlannerFieldFitKind.mosaic => 'Needs a $columns × $rows mosaic',
      };
}

enum PlannerFieldFitKind { fits, fills, mosaic }

/// The field preview at the top of the detail column.
///
/// Skotiq does not have the target's sky in hand here — the HiPS surface
/// that does lives on the Framing tab and needs its own tile loader — so the
/// well is a scale drawing of what IS known: the camera's field (the active
/// profile's sensor and focal length) as the `primary` rectangle, the
/// target's catalogued size as a circle, and whether it fits.
class _TargetFieldPreview extends ConsumerWidget {
  final TargetSuggestion target;

  const _TargetFieldPreview({required this.target});

  /// The size (in arcminutes) the preview treats as filling the well when the
  /// camera's field is not known.
  static const double _fullFrameArcmin = 90;

  /// Room left around the larger of the field and the target.
  static const double _margin = 1.2;

  /// The smallest the target circle is drawn, so a small target is still a
  /// visible mark rather than a dot.
  static const double _minTargetPx = 6;

  /// The caption row's share of the well's top.
  static const double _captionBand = 30;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final size = target.sizeArcmin != null && target.sizeArcmin! > 0
        ? target.sizeArcmin
        : null;
    final fov = ref.watch(opticalConfigProvider)?.fieldOfView;
    final field = fov == null
        ? null
        : (
            math.max(fov.$1, fov.$2) * 60,
            math.min(fov.$1, fov.$2) * 60,
          );
    final fit = field == null
        ? null
        : PlannerFieldFit.of(
            sizeArcmin: size,
            fieldWidthArcmin: field.$1,
            fieldHeightArcmin: field.$2,
          );
    final caption = field != null
        ? 'Camera field ${_arcmin(field.$1)} × ${_arcmin(field.$2)}'
            '${size == null ? ' · size not catalogued' : ' · target ${_arcmin(size)}'}'
        : size == null
            ? 'Size not catalogued'
            : 'Target size to scale in a ${_fullFrameArcmin.round()} arcmin '
                'field · camera field unknown';

    return Semantics(
      label: 'Field preview for ${target.targetName}. $caption'
          '${fit == null ? '' : '. ${fit.label}'}',
      child: Container(
        decoration: SkotiqDecorations.well(colors),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The drawing sits under the caption row, so the frame never
            // covers the words that say what it is.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.spaceSm,
                _captionBand,
                SkotiqTokens.spaceSm,
                SkotiqTokens.spaceSm,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final h = constraints.maxHeight;
                  final double pxPerArcmin;
                  if (field != null) {
                    pxPerArcmin = math.min(
                      w / (math.max(field.$1, size ?? 0) * _margin),
                      h / (math.max(field.$2, size ?? 0) * _margin),
                    );
                  } else {
                    pxPerArcmin = math.min(w, h) / _fullFrameArcmin;
                  }
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      if (field != null)
                        Container(
                          width: field.$1 * pxPerArcmin,
                          height: field.$2 * pxPerArcmin,
                          decoration: BoxDecoration(
                            border: Border.all(color: colors.primary),
                          ),
                        ),
                      if (size != null)
                        Container(
                          width: math.max(_minTargetPx, size * pxPerArcmin),
                          height: math.max(_minTargetPx, size * pxPerArcmin),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: colors.textSecondary),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            Positioned(
              left: SkotiqTokens.spaceSm,
              top: SkotiqTokens.spaceSm,
              right: SkotiqTokens.spaceSm,
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                    if (fit != null) ...[
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      SkotiqChip(
                        label: fit.label,
                        tone: fit.kind == PlannerFieldFitKind.mosaic
                            ? ChipTone.warning
                            : ChipTone.neutral,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // The two things you can do with a target that are not the page's
            // actions. A candidate row carries ONE button (05 §9) and the
            // selected row spends it on "Image tonight", so the observing list
            // has to be reachable from here or the selected target — the only
            // one when the list has a single candidate — could never be added
            // to one.
            Positioned(
              right: SkotiqTokens.spaceSm,
              bottom: SkotiqTokens.spaceSm,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SkotiqIconButton(
                    icon: LucideIcons.listPlus,
                    tooltip: 'Add to observing list',
                    size: IconButtonSize.sm,
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => _CandidateObservingListDialog(
                        suggestion: target,
                        colors: SkotiqColors.of(context),
                      ),
                    ),
                  ),
                  SkotiqIconButton(
                    icon: LucideIcons.globe,
                    tooltip: context.l10n.text('plannerOpenPlanetarium'),
                    size: IconButtonSize.sm,
                    onPressed: () => showTargetInSky(
                      context,
                      ref,
                      raHours: target.raHours,
                      decDegrees: target.decDegrees,
                      name: target.targetName,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// [arcmin] as `31′`, or `7.4′` below ten.
String _arcmin(double arcmin) =>
    '${arcmin < 10 ? arcmin.toStringAsFixed(1) : arcmin.round()}′';

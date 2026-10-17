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
  static const double _previewHeight = 150;

  /// Height of the altitude well.
  static const double _altitudeHeight = 110;

  /// Whether the selected target IS the one the optimizer chose.
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
    final filters = plan.recommendedFilterNames.isNotEmpty
        ? plan.recommendedFilterNames.join('  ')
        : plan.recommendedFilterName;

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
      (
        l10n.text('plannerKvExposure'),
        '${plan.recommendedExposureSeconds.round()} s',
      ),
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
/// One `well`, one `primary` path, a dashed line at the minimum altitude the
/// filters ask for, the astronomical-dark span shaded, and a `textPrimary`
/// "now" tick. `AltitudeChart` (the Framing tab's) is the full instrument —
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
    final points = <double>[];
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
      points.add(alt);
    }

    double fraction(DateTime t) =>
        (t.difference(from).inSeconds / span).clamp(0.0, 1.0);

    return DecoratedBox(
      decoration: SkotiqDecorations.well(colors),
      child: CustomPaint(
        painter: _AltitudeCurvePainter(
          altitudes: points,
          minAltitude: minAltitude,
          darkFrom: fraction(night.start),
          darkTo: fraction(night.end),
          now: fraction(DateTime.now()),
          curve: colors.primary,
          hairline: colors.border,
          marker: colors.textPrimary,
        ),
      ),
    );
  }
}

/// Paints [_TargetAltitudeWell]'s curve. Altitude 0–90° maps to the full
/// height; anything below the horizon is clamped to the floor rather than
/// drawn underground.
class _AltitudeCurvePainter extends CustomPainter {
  final List<double> altitudes;
  final double minAltitude;
  final double darkFrom;
  final double darkTo;
  final double now;
  final Color curve;
  final Color hairline;
  final Color marker;

  const _AltitudeCurvePainter({
    required this.altitudes,
    required this.minAltitude,
    required this.darkFrom,
    required this.darkTo,
    required this.now,
    required this.curve,
    required this.hairline,
    required this.marker,
  });

  /// The altitude the top of the well represents.
  static const double _ceiling = 90;

  /// Stroke width of the curve and the now marker.
  static const double _curveStroke = 1.5;

  /// Dash geometry of the minimum-altitude line.
  static const double _dashOn = 3;
  static const double _dashOff = 3;

  @override
  void paint(Canvas canvas, Size size) {
    if (altitudes.length < 2 || size.width <= 0 || size.height <= 0) return;

    double y(double altitude) =>
        size.height * (1 - (altitude.clamp(0.0, _ceiling) / _ceiling));

    // The astronomical-dark span, so the useful part of the curve is obvious.
    canvas.drawRect(
      Rect.fromLTRB(darkFrom * size.width, 0, darkTo * size.width, size.height),
      Paint()
        ..color = curve.withValues(alpha: SkotiqTokens.opacityPanelOutline),
    );

    // The minimum altitude the filters ask for, dashed.
    final horizonY = y(minAltitude);
    final dash = Paint()
      ..color = hairline
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += _dashOn + _dashOff) {
      canvas.drawLine(
        Offset(x, horizonY),
        Offset((x + _dashOn).clamp(0.0, size.width), horizonY),
        dash,
      );
    }

    final path = Path();
    final fill = Path();
    for (var i = 0; i < altitudes.length; i++) {
      final x = size.width * i / (altitudes.length - 1);
      final py = y(altitudes[i]);
      if (i == 0) {
        path.moveTo(x, py);
        fill.moveTo(x, size.height);
        fill.lineTo(x, py);
      } else {
        path.lineTo(x, py);
        fill.lineTo(x, py);
      }
    }
    fill.lineTo(size.width, size.height);
    fill.close();

    canvas.drawPath(
      fill,
      Paint()
        ..color = curve.withValues(alpha: SkotiqTokens.opacityAccentTint),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = curve
        ..strokeWidth = _curveStroke
        ..style = PaintingStyle.stroke,
    );

    canvas.drawLine(
      Offset(now * size.width, 0),
      Offset(now * size.width, size.height),
      Paint()
        ..color = marker
        ..strokeWidth = _curveStroke,
    );
  }

  @override
  bool shouldRepaint(_AltitudeCurvePainter old) =>
      old.altitudes != altitudes ||
      old.minAltitude != minAltitude ||
      old.now != now ||
      old.curve != curve;
}

/// The field preview at the top of the detail column.
///
/// The mockup fills this with a decorative star field. Skotiq does not
/// have the target's sky in hand here — the HiPS surface that does lives on
/// the Framing tab and needs its own tile loader — and a synthetic star field
/// in a slot that reads as a preview would be the app claiming to show
/// something it has not fetched. So the well carries the ONE thing that IS
/// known from the numbers on this column: the target's angular extent against
/// the frame, drawn as the `primary` rectangle the mockup puts there, with the
/// action that opens the real sky.
class _TargetFieldPreview extends ConsumerWidget {
  final TargetSuggestion target;

  const _TargetFieldPreview({required this.target});

  /// The size (in arcminutes) the preview treats as filling the well. Anything
  /// larger is drawn at the full width.
  static const double _fullFrameArcmin = 90;

  /// The smallest fraction of the well the rectangle is drawn at, so a small
  /// target is still a visible mark rather than a dot.
  static const double _minFraction = 0.12;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final size = target.sizeArcmin;
    final fraction = size == null || size <= 0
        ? null
        : (size / _fullFrameArcmin).clamp(_minFraction, 1.0);

    return Semantics(
      label: 'Field preview for ${target.targetName}',
      child: Container(
        decoration: SkotiqDecorations.well(colors),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (fraction != null)
              Center(
                child: FractionallySizedBox(
                  widthFactor: fraction,
                  heightFactor: fraction,
                  child: DecoratedBox(
                    // The mockup softens this hairline to 80% primary; there
                    // is no 0.8 opacity token and 03 §5.1 forbids inventing
                    // one, so a 1px line takes the token colour whole.
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.primary),
                    ),
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

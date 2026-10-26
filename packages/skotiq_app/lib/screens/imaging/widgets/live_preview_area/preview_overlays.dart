part of '../live_preview_area.dart';

/// Small success-coloured chip that announces the displayed frame has
/// been auto-calibrated. Watches `currentImageIsCalibratedProvider` and
/// collapses to nothing when the answer is false, so it costs zero
/// pixels for raw / failed-calibration frames.
///
/// Why a separate widget instead of inlining a `ref.watch` next to the
/// `RawPreviewStatusBadge` row: keeping the watch local to this widget
/// means a calibration-state flip only rebuilds the badge, not the
/// whole preview area (which paints the image, overlays, histograms,
/// etc.). The cost saved per swap is small but it lines up with how
/// the other preview badges are scoped.
class _CalibratedBadge extends ConsumerWidget {
  final SkotiqColors colors;

  const _CalibratedBadge({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCalibrated = ref.watch(currentImageIsCalibratedProvider);
    if (!isCalibrated) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.checkCircle2,
              size: 12,
              color: colors.onPrimary,
            ),
            const SizedBox(width: 4),
            Text(
              'Calibrated',
              style: SkotiqTypography.caption.copyWith(
                  fontWeight: FontWeight.w600, color: colors.onPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Composite overlay widget that shows compass and scale bar when plate solve
/// data is available and the respective settings are enabled.
class _CompassScaleBarOverlay extends ConsumerWidget {
  final double zoomLevel;
  final PlateSolveData? plateSolve;

  /// Whether the bottom-left chip stack (science, guiding) may be on screen.
  /// The corner glass is a separately-anchored sibling in the same stack, so
  /// the scale bar has to be told to stay off that corner.
  final bool bottomLeftOccupied;

  /// Whether the opt-in histogram holds the bottom-right corner, where the
  /// compass rose would otherwise be drawn under it.
  final bool bottomRightOccupied;

  /// How far each corner's readouts stepped up over the capture bar; the
  /// scale bar and the compass clear them by the same amount.
  final double bottomLeftLift;
  final double bottomRightLift;

  const _CompassScaleBarOverlay({
    required this.zoomLevel,
    required this.plateSolve,
    required this.bottomLeftOccupied,
    required this.bottomRightOccupied,
    this.bottomLeftLift = 0,
    this.bottomRightLift = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(annotationSettingsProvider);
    final settings = settingsAsync.valueOrNull;

    final solve = plateSolve;
    if (solve == null || settings == null) return const SizedBox.shrink();

    final showCompass = settings.compassEnabled;
    final showScaleBar = settings.scaleBarEnabled;
    if (!showCompass && !showScaleBar) return const SizedBox.shrink();

    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _CompassScaleBarCombinedPainter(
            plateSolve: solve,
            showCompass: showCompass,
            showScaleBar: showScaleBar,
            zoomLevel: zoomLevel,
            bottomLeftOccupied: bottomLeftOccupied,
            bottomRightOccupied: bottomRightOccupied,
            bottomLeftLift: bottomLeftLift,
            bottomRightLift: bottomRightLift,
            colors: SkotiqColors.of(context),
          ),
        ),
      ),
    );
  }
}

/// Combined painter that delegates to CompassOverlayPainter and ScaleBarPainter
/// to avoid multiple CustomPaint layers when both are visible.
class _CompassScaleBarCombinedPainter extends CustomPainter {
  final PlateSolveData plateSolve;
  final bool showCompass;
  final bool showScaleBar;
  final double zoomLevel;
  final bool bottomLeftOccupied;
  final bool bottomRightOccupied;
  final double bottomLeftLift;
  final double bottomRightLift;
  final SkotiqColors colors;

  _CompassScaleBarCombinedPainter({
    required this.plateSolve,
    required this.showCompass,
    required this.showScaleBar,
    required this.zoomLevel,
    required this.bottomLeftOccupied,
    required this.bottomRightOccupied,
    this.bottomLeftLift = 0,
    this.bottomRightLift = 0,
    required this.colors,
  });

  /// The scale-bar painter this widget draws with.
  ScaleBarPainter scaleBarPainter() => ScaleBarPainter(
        pixelScaleArcsecPerPixel: plateSolve.pixelScale,
        imageWidthPixels: plateSolve.imageWidth.toDouble(),
        zoomLevel: zoomLevel,
        bottomMargin: bottomLeftOccupied
            ? PreviewReadoutInsets.bottomLeft + bottomLeftLift
            : null,
      );

  /// The compass painter this widget draws with.
  ///
  /// Built once per painter instance, never per `paint`: it resolves its axis
  /// hues for the active theme at construction, and rebuilding it inside the
  /// draw would put that resolve on every frame.
  late final CompassOverlayPainter _compass = CompassOverlayPainter(
    rotationDegrees: plateSolve.rotation,
    axes: _compassAxes(plateSolve),
    bottomMargin: bottomRightOccupied
        ? PreviewReadoutInsets.bottomRight + bottomRightLift
        : null,
    colors: colors,
  );

  CompassOverlayPainter compassPainter() => _compass;

  @override
  void paint(Canvas canvas, Size size) {
    if (showCompass) {
      compassPainter().paint(canvas, size);
    }
    if (showScaleBar) {
      scaleBarPainter().paint(canvas, size);
    }
  }

  @override
  bool shouldRepaint(covariant _CompassScaleBarCombinedPainter oldDelegate) {
    return oldDelegate.plateSolve != plateSolve ||
        oldDelegate.showCompass != showCompass ||
        oldDelegate.showScaleBar != showScaleBar ||
        oldDelegate.zoomLevel != zoomLevel ||
        oldDelegate.bottomLeftOccupied != bottomLeftOccupied ||
        oldDelegate.bottomRightOccupied != bottomRightOccupied ||
        oldDelegate.bottomLeftLift != bottomLeftLift ||
        oldDelegate.bottomRightLift != bottomRightLift ||
        oldDelegate.colors != colors;
  }
}

/// North and east on the frame from the solve's full WCS, or null when it
/// cannot be projected.
({double northX, double northY, double eastX, double eastY})? _compassAxes(
  PlateSolveData plateSolve,
) {
  final wcs = plateSolve.toSolvedWcs();
  return wcs.isValid ? GnomonicProjection(wcs).skyAxesOnImage : null;
}

/// Translate the database WCS row + image dimensions into the form the
/// catalog overlay expects. Returns null when the row is missing or the
/// frame wasn't plate-solved. The overlay widget renders an explanatory banner
/// in that case rather than drawing nothing.
class _CurrentImageSkySolution {
  final SolvedWcs? catalogWcs;
  final PlateSolveData? plateSolve;

  const _CurrentImageSkySolution({
    this.catalogWcs,
    this.plateSolve,
  });
}

_CurrentImageSkySolution _resolveCurrentImageSkySolution({
  required CapturedImageWcsData? wcs,
  required ImageAnnotation? annotation,
  required int width,
  required int height,
  FrameSolveVm? frameSolve,
}) {
  final catalogWcs = _solvedWcsFromImage(
    wcs: wcs,
    width: width,
    height: height,
  );
  if (catalogWcs != null) {
    return _CurrentImageSkySolution(
      catalogWcs: catalogWcs,
      plateSolve: _plateSolveFromSolvedWcs(catalogWcs),
    );
  }

  final annotationSolve = annotation?.plateSolve;
  final annotationWcs = annotationSolve == null
      ? null
      : _solvedWcsFromPlateSolve(annotationSolve);
  // The frame's background solve, when nothing saved or annotated covers it.
  final autoWcs = annotationWcs == null
      ? frameSolve?.wcsFor(width: width, height: height)
      : null;
  if (autoWcs != null) {
    return _CurrentImageSkySolution(
      catalogWcs: autoWcs,
      plateSolve: _plateSolveFromSolvedWcs(autoWcs),
    );
  }
  return _CurrentImageSkySolution(
    catalogWcs: annotationWcs,
    plateSolve: annotationSolve,
  );
}

SolvedWcs? _solvedWcsFromImage({
  required CapturedImageWcsData? wcs,
  required int width,
  required int height,
}) {
  if (wcs == null || !wcs.isPlateSolved) return null;
  return solvedWcsFromStored(
    raHours: wcs.solvedRaHours,
    decDegrees: wcs.solvedDecDegrees,
    rotationDeg: wcs.solvedRotationDegrees,
    pixelScaleArcsec: wcs.solvedPixelScaleArcsecPerPixel,
    imageWidth: width,
    imageHeight: height,
    cd1_1: wcs.cd1_1,
    cd1_2: wcs.cd1_2,
    cd2_1: wcs.cd2_1,
    cd2_2: wcs.cd2_2,
    sip: wcs.sip,
  );
}

SolvedWcs? _solvedWcsFromPlateSolve(PlateSolveData plateSolve) {
  final solved = plateSolve.toSolvedWcs();
  return solved.isValid ? solved : null;
}

PlateSolveData _plateSolveFromSolvedWcs(SolvedWcs wcs) =>
    plateSolveDataFromSolvedWcs(wcs);

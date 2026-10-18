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
  final ra = wcs.solvedRaHours;
  final dec = wcs.solvedDecDegrees;
  final rot = wcs.solvedRotationDegrees;
  final scale = wcs.solvedPixelScaleArcsecPerPixel;
  if (ra == null || dec == null || rot == null || scale == null) {
    return null;
  }
  return SolvedWcs(
    raHours: ra,
    decDegrees: dec,
    rotationDeg: rot,
    pixelScaleArcsec: scale,
    imageWidth: width,
    imageHeight: height,
  );
}

SolvedWcs? _solvedWcsFromPlateSolve(PlateSolveData plateSolve) {
  final solved = SolvedWcs(
    raHours: plateSolve.ra,
    decDegrees: plateSolve.dec,
    rotationDeg: plateSolve.rotation,
    pixelScaleArcsec: plateSolve.pixelScale,
    imageWidth: plateSolve.imageWidth,
    imageHeight: plateSolve.imageHeight,
  );
  return solved.isValid ? solved : null;
}

PlateSolveData _plateSolveFromSolvedWcs(SolvedWcs wcs) {
  return PlateSolveData(
    ra: wcs.raHours,
    dec: wcs.decDegrees,
    pixelScale: wcs.pixelScaleArcsec,
    rotation: wcs.rotationDeg,
    fieldWidth: wcs.imageWidth * wcs.pixelScaleArcsec / 3600.0,
    fieldHeight: wcs.imageHeight * wcs.pixelScaleArcsec / 3600.0,
    imageWidth: wcs.imageWidth,
    imageHeight: wcs.imageHeight,
  );
}

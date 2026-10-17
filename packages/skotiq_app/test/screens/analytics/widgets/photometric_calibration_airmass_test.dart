// The airmass the extinction fit actually runs on, driven through the wizard.
//
// The wizard must use the SHARED airmass model, not a local copy: a clamp at
// airmass 8 hands every frame below ~6.6° to the extinction fit as the same
// constant, flattening the low-altitude leverage the fit exists to measure and
// disagreeing with the airmass the same frame's FITS header and AAVSO line
// report.
//
// These tests drive the real widget from the frame list through "Match Stars"
// and read the airmass back out of the [ScienceFrameContext] the wizard hands
// to the science backend, which is the value that reaches the fit. Cutting the
// wizard's call to the shared model must break this.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/widgets/photometric_calibration_wizard.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A local (non-network) backend, so the wizard takes its own matching path
/// instead of delegating to a remote host.
class _LocalBackend extends Mock implements SkotiqBackend {
  @override
  void dispose() {}
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

class _StubImagesDao extends Mock implements ImagesDao {}

/// Captures the frame context the wizard builds.
///
/// With [zeroPoint] left null it then refuses to calibrate, so a run stops at a
/// stable, assertable point right after the airmass decision. Set it and the
/// run continues into catalog matching, which is what the multi-frame span test
/// needs — the span readout is only produced once matching completes.
class _CapturingScienceBackend extends Mock implements ScienceBackend {
  _CapturingScienceBackend({this.zeroPoint});

  final double? zeroPoint;
  final contexts = <ScienceFrameContext>[];

  @override
  Future<List<StarMeasurement>> measureStars(
    String imagePath,
    PhotometryOptions options,
  ) async =>
      List.generate(
        8,
        (i) => StarMeasurement(
          x: 100.0 + i * 20,
          y: 100.0 + i * 15,
          flux: 20000.0 - i * 500,
          hfr: 2.4,
          fwhm: 3.1,
          snr: 60.0 - i,
          eccentricity: 0.2,
          sharpness: 0.5,
          background: 120.0,
          peak: 9000.0,
        ),
      );

  @override
  Future<FramePhotometricCalibration?> calibrateFramePhotometry(
    String imagePath,
    WcsSolution wcs,
    PhotometricCatalogSource catalog,
    ScienceFrameContext? frameContext,
  ) async {
    if (frameContext != null) {
      contexts.add(frameContext);
    }
    if (zeroPoint == null) {
      return null;
    }
    return FramePhotometricCalibration(
      capturedImageId: frameContext?.capturedImageId,
      sessionId: frameContext?.sessionId,
      timestamp: frameContext?.capturedAt ?? DateTime.utc(2026, 8, 1, 23),
      airmass: frameContext?.airmass,
      exposureSeconds: frameContext?.exposureSeconds ?? 1.0,
      isCalibrated: true,
      zeroPoint: zeroPoint,
      solverId: 'stored',
    );
  }
}

/// Serves the detected stars back as catalog stars at their own sky positions,
/// so every detection finds a counterpart and the run reaches the span readout.
///
/// The RA/Dec come from inverting the same projection the wizard builds, and
/// each V magnitude is the star's own instrumental magnitude plus the frame
/// zero point, which is what the wizard's plausibility gate expects.
class _CoincidentCatalog extends Mock implements PhotometricCatalogService {
  _CoincidentCatalog(this.stars);

  final List<PhotometricCatalogStar> stars;

  @override
  Future<PhotometricConeResult> coneSearch({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
    double maxMagnitude = 16.0,
  }) async =>
      PhotometricConeResult(
        source: PhotometricCatalogSource.localHyg,
        stars: stars,
      );
}

class _StubImagingBackend extends Mock implements ImagingBackend {
  @override
  Future<FitsReadResult> readFitsFile({required String filePath}) async =>
      _FakeFitsRead();
}

/// Only the dimensions matter here — they set the projection's reference pixel,
/// so the catalog positions the test derives land back on the same pixels.
class _FakeFitsRead extends Mock implements FitsReadResult {
  @override
  int get width => _imageSizePx;

  @override
  int get height => _imageSizePx;
}

const int _imageSizePx = 2048;

ImagingSession _session() => ImagingSession(
      id: 1,
      name: 'Extinction run',
      startTime: DateTime.utc(2026, 8, 1, 21),
      totalExposures: 1,
      successfulExposures: 1,
      failedExposures: 0,
      totalIntegrationSecs: 30,
      autofocusCount: 0,
      status: 'completed',
    );

/// A plate-solved light frame at [mountAltitude]. A stored pixel scale keeps
/// the run off the rig-geometry fallback path, which is covered by
/// photometric_calibration_pixel_scale_test.dart.
DbCapturedImage _frame(String fileName, double? mountAltitude, {int id = 11}) =>
    DbCapturedImage(
      id: id,
      filePath: '/captures/standards/$fileName',
      fileName: fileName,
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 30,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 8, 1, 23),
      createdAt: DateTime.utc(2026, 8, 1, 23),
      isAccepted: true,
      isPlateSolved: true,
      solvedRa: 5.5,
      solvedDec: -5.4,
      solvedRotation: 0.0,
      solvedPixelScale: 1.5,
      filter: 'V',
      starCount: 40,
      sessionId: 1,
      mountAltitude: mountAltitude,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CapturingScienceBackend science;
  late _StubImagesDao imagesDao;

  setUp(() {
    science = _CapturingScienceBackend();
    imagesDao = _StubImagesDao();
    registerFallbackValue(0);
  });

  /// Bounded pumping instead of [WidgetTester.pumpAndSettle]: this screen keeps
  /// indefinite animations on stage (the shimmer placeholder while the frame
  /// list loads, the progress spinner while matching runs), so "settle" never
  /// arrives and a wrong finder would look like a hang instead of a failure.
  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpWizard(WidgetTester tester, DbCapturedImage frame) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1400);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    when(() => imagesDao.getImageById(any())).thenAnswer((_) async => frame);
    when(
      () => imagesDao.getStoredWcsDistortion(any()),
    ).thenAnswer((_) async => null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, _LocalBackend()),
          ),
          scienceBackendProvider.overrideWithValue(science),
          imagesDaoProvider.overrideWithValue(imagesDao),
          allSessionsProvider.overrideWith((ref) => Stream.value([_session()])),
          calibrationSessionImagesProvider.overrideWith(
            (ref, sessionId) async => [frame],
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PhotometricCalibrationWizard()),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> matchFrame(WidgetTester tester, String fileName) async {
    // The wizard defaults to the first session, so the frame list is already
    // on screen; touching the session dropdown would only open an overlay.
    await tester.tap(find.text(fileName));
    await tester.pump();
    final next = find.widgetWithText(SkotiqButton, 'Next');
    await tester.ensureVisible(next);
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    final match = find.widgetWithText(SkotiqButton, 'Match Stars');
    await tester.ensureVisible(match);
    await tester.pump();
    await tester.tap(match);
    await settle(tester);
  }

  testWidgets(
    'a 4-degree frame reaches the fit at airmass 11.897, not the old clamp 8.0',
    (tester) async {
      await pumpWizard(tester, _frame('standard-04.fits', 4.0));
      await matchFrame(tester, 'standard-04.fits');

      expect(
        science.contexts,
        hasLength(1),
        reason: 'the wizard must have reached frame calibration',
      );
      final airmass = science.contexts.single.airmass;
      expect(airmass, isNotNull);
      // The one product model. The retired copy clamped this to 8.0.
      expect(airmass, closeTo(airmassForTrueAltitude(4.0)!, 1e-9));
      expect(airmass, closeTo(11.897, 0.005));
      expect(
        airmass,
        isNot(closeTo(8.0, 0.01)),
        reason: 'clamping here is what erased the extinction leverage',
      );
    },
  );

  testWidgets(
    'a frame with no recorded altitude is refused instead of assumed at zenith',
    (tester) async {
      await pumpWizard(tester, _frame('standard-noalt.fits', null));
      await matchFrame(tester, 'standard-noalt.fits');

      // Nothing may reach the fit: an invented X = 1.0 for an unknown altitude
      // drags the extinction slope toward zero for every other frame too.
      expect(science.contexts, isEmpty);
      expect(
        find.textContaining('no recorded above-horizon mount'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a sub-horizon altitude is refused, not clamped to 1.0', (
    tester,
  ) async {
    await pumpWizard(tester, _frame('standard-set.fits', -2.0));
    await matchFrame(tester, 'standard-set.fits');

    expect(science.contexts, isEmpty);
    expect(
      find.textContaining('no recorded above-horizon mount'),
      findsOneWidget,
    );
  });

  // The airmass number the wizard PRINTS, across more than one frame.
  //
  // Everything above stops at the value handed to the backend. The wizard also
  // renders an "Airmass span" in air masses and decides from it whether to tell
  // the user extinction is fittable — and a span needs at least two frames, so
  // no single-frame test can reach it. That readout is the one place a user
  // sees an airmass in this flow, and a clamped computation gets it wrong: two
  // frames at 60 deg and 4 deg span 10.74 air masses, while a clamp prints 6.85
  // and still says "fittable".
  testWidgets('the printed airmass span across frames is the product model', (
    tester,
  ) async {
    const zeroPoint = 20.0;
    const exposureSeconds = 30.0;
    science = _CapturingScienceBackend(zeroPoint: zeroPoint);

    final high = _frame('standard-60.fits', 60.0, id: 11);
    final low = _frame('standard-04.fits', 4.0, id: 12);
    final frames = [high, low];

    // Both frames share pointing and pixel scale, so one catalog serves both.
    // Building it by inverting the wizard's own projection is what makes every
    // detection match: the run then reaches the span readout instead of
    // failing on "not enough catalog matches".
    final projection = GnomonicProjection(
      SolvedWcs(
        raHours: high.solvedRa!,
        decDegrees: high.solvedDec!,
        rotationDeg: high.solvedRotation ?? 0.0,
        pixelScaleArcsec: high.solvedPixelScale!,
        imageWidth: _imageSizePx,
        imageHeight: _imageSizePx,
      ),
    );
    final detections = await _CapturingScienceBackend().measureStars(
      high.filePath,
      const PhotometryOptions(minSnr: 5.0),
    );
    final catalog = <PhotometricCatalogStar>[];
    for (final star in detections) {
      final sky = projection.pixelToWorld(x: star.x, y: star.y);
      final instMag = -2.5 * math.log(star.flux / exposureSeconds) / math.ln10;
      catalog.add(
        PhotometricCatalogStar(
          raDegrees: sky.raDegrees,
          decDegrees: sky.decDegrees,
          magV: instMag + zeroPoint,
          colorIndexBv: 0.6,
        ),
      );
    }

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1400);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    when(() => imagesDao.getImageById(any())).thenAnswer((invocation) async {
      final id = invocation.positionalArguments.first as int;
      return frames.firstWhere((frame) => frame.id == id);
    });
    when(
      () => imagesDao.getStoredWcsDistortion(any()),
    ).thenAnswer((_) async => null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, _LocalBackend()),
          ),
          scienceBackendProvider.overrideWithValue(science),
          imagesDaoProvider.overrideWithValue(imagesDao),
          imagingBackendProvider.overrideWithValue(_StubImagingBackend()),
          photometricCatalogServiceProvider.overrideWithValue(
            _CoincidentCatalog(catalog),
          ),
          allSessionsProvider.overrideWith((ref) => Stream.value([_session()])),
          calibrationSessionImagesProvider.overrideWith(
            (ref, sessionId) async => frames,
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PhotometricCalibrationWizard()),
        ),
      ),
    );
    await settle(tester);

    // ensureVisible: the frame list sits inside the wizard's own scroll view
    // and the bulk-selection header above it can push the second row past the
    // fold on a short viewport.
    await tester.ensureVisible(find.text('standard-60.fits'));
    await tester.tap(find.text('standard-60.fits'));
    await tester.pump();
    await tester.ensureVisible(find.text('standard-04.fits'));
    await tester.tap(find.text('standard-04.fits'));
    await tester.pump();
    final next = find.widgetWithText(SkotiqButton, 'Next');
    await tester.ensureVisible(next);
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    final match = find.widgetWithText(SkotiqButton, 'Match Stars');
    await tester.ensureVisible(match);
    await tester.pump();
    await tester.tap(match);
    await settle(tester, frames: 60);

    // The rendered number first: this is the claim the user reads. Derived
    // from the model AND pinned to a literal, so neither side can drift alone.
    final span = airmassForTrueAltitude(4.0)! - airmassForTrueAltitude(60.0)!;
    expect(span.toStringAsFixed(2), '10.74');
    expect(find.textContaining('Airmass span 10.74'), findsOneWidget);
    expect(find.textContaining('extinction is fittable'), findsOneWidget);

    // The retired clamp(1, 8) pinned the 4 deg frame to 8.0 and would have
    // printed this instead — a wrong number under a correct verdict.
    expect(find.textContaining('Airmass span 6.85'), findsNothing);

    // And both frames reached the fit, each on its own atmosphere.
    expect(science.contexts, hasLength(2));
    expect(
      science.contexts.map((c) => c.airmass),
      containsAll(<Matcher>[
        closeTo(airmassForTrueAltitude(60.0)!, 1e-9),
        closeTo(airmassForTrueAltitude(4.0)!, 1e-9),
      ]),
    );
  });
}

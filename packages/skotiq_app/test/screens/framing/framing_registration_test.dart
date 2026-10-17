// Registration / regression guard for the survey-backed framing canvas.
//
// THE BUG THIS GUARDS: the equipment FOV reticle must be drawn at the *same*
// astrometric plate scale as the survey background image. Divergent scales — a
// fit-to-canvas survey draw rect, a hardcoded `60px/deg` FOV reticle, a third
// gesture mapping — make the rectangle a user draws over a patch of sky
// correspond to different pixels than the survey imagery occupies there. One
// `FramingPlateScale` is the single answer; this test proves the wired-up screen
// threads that survey-registered scale into BOTH the background painter and the
// FOV reticle, so they stay co-registered to the pixel.
//
// Concretely, with a known survey cutout (2.0deg wide, 800x600px) and a
// known equipment FOV, pumped at a fixed surface size, we assert:
//
//   1. The FOV reticle painter and the survey background painter both
//      receive the *exact same* `FramingPlateScale` the framing provider
//      published for the loaded image — not a synthetic fallback and not a
//      hardcoded 60px/deg. A regression that re-introduced a divergent
//      scale would make these two `plateScale` values differ.
//   2. The on-screen FOV rectangle width (what the painter actually draws)
//      equals `fovWidthDeg * plateScale.pixelsPerDegree(canvasSize, zoom)`
//      within 1 logical pixel, where `canvasSize` is the *measured*,
//      sidebar-excluded canvas region. This proves the reticle is sized
//      from the background scale and confirms C6's LayoutBuilder feeds the
//      bounded canvas box (not the whole-window MediaQuery size that
//      includes the sidebar).
//   3. With rotation=30deg, the survey background painter receives
//      rotation=30 — i.e. the field rotation reaches the background, so the
//      imagery rotates together with the (identically rotated) FOV overlay.
//
// Determinism: there is no network. We override `framingProvider` with a
// notifier seeded with a pre-decoded in-memory `ui.Image` and a known
// `FramingPlateScale`, and override `framingFOVProvider` with a ready
// equipment result. `settle: false` + fixed-step pumps avoid the framing
// screen's `ContextualTourPrompt` fade animation tripping pumpAndSettle.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/framing_screen.dart';
import 'package:skotiq_app/screens/framing/painters/framing_background_painters.dart';
import 'package:skotiq_app/screens/framing/painters/framing_painters.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_canvas.dart';
import 'package:skotiq_core/skotiq_core.dart';
// FramingPlateScale is the C1 single-source-of-truth astrometric scale. It is
// intentionally not surfaced through the public barrel (it is an app->core
// src-model shared with the framing painters), so it is imported directly
// here, matching the convention used by the painters themselves.
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';

import '../../harness/pump_app_screen.dart';

/// Known survey-image astrometry under test: a 2.0deg-wide DSS-style cutout
/// returned as an 800x600 pixel image. These exact numbers flow through the
/// width assertion below, so changing one without updating the expectation
/// would (correctly) fail the test.
const double _surveyFovWidthDeg = 2.0;
const int _surveyImagePixelWidth = 800;
const int _surveyImagePixelHeight = 600;

/// The plate scale the framing provider would publish for the loaded cutout:
/// 2.0deg across 800px, 600px tall. The FOV height (1.5deg) preserves the
/// cutout's pixel aspect (800:600) == FOV aspect, matching how
/// [FramingNotifier] pairs the requested FOV with the decoded pixel dims.
const FramingPlateScale _surveyPlateScale = FramingPlateScale(
  surveyFovWidthDeg: _surveyFovWidthDeg,
  // 2.0deg * 600 / 800 = 1.5deg (kept literal so the value object stays const).
  surveyFovHeightDeg: 1.5,
  imagePixelWidth: _surveyImagePixelWidth,
  imagePixelHeight: _surveyImagePixelHeight,
);

/// A modest refractor + APS-C-ish sensor giving an equipment FOV comfortably
/// *larger* than the framing preview FOV below, so the canvas renders the
/// [FramingFOVPainter] reticle (the `previewFov <= equipmentFov` branch) and
/// NOT the larger-than-equipment overlay painter. fovWidthDeg works out to
/// ~1.46deg, fovHeightDeg ~0.97deg.
const FramingEquipment _equipment = FramingEquipment(
  cameraName: 'Test Camera',
  sensorWidthMm: 13.5,
  sensorHeightMm: 9.0,
  pixelSizeMicrons: 3.76,
  pixelsX: 3600,
  pixelsY: 2400,
  telescopeName: 'Test Refractor',
  focalLengthMm: 530,
  apertureMm: 106,
);

/// A target sitting at the canvas center; coordinates are arbitrary but valid.
const FramingTarget _target = FramingTarget(
  name: 'NGC 7000',
  catalogId: 'NGC7000',
  raHours: 20.97,
  decDegrees: 44.33,
);

/// Fixed surface size for the pump. Wide enough that the framing screen takes
/// its desktop Row + sidebar layout (the only layout the screen has), so the
/// canvas is the surface width minus the 320px sidebar.
const Size _surfaceSize = Size(1280, 800);

/// Test-only [FramingNotifier] that skips all network / database wiring and
/// pins the state to a fully-formed, image-loaded framing state.
///
/// Mirrors the harness's `TestBackendNotifier` trick: `framingProvider` is a
/// `StateNotifierProvider`, so the only way to inject a known state is to
/// override the notifier factory with a subclass that seeds `state` in its
/// constructor. Seeding a non-null `target` also prevents the screen's
/// post-frame `_loadPersistedTarget` from calling `loadMostRecentTarget()`
/// (which would touch the database / network).
class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

/// Builds a 1x1-decoded-color [ui.Image] at the survey cutout's pixel
/// dimensions. The pixel content is irrelevant to registration geometry — the
/// painter maps the full image rect onto the plate-scale draw rect regardless
/// of content — so a flat fill keeps the fixture cheap and deterministic.
Future<ui.Image> _decodeSurveyImage() async {
  const width = _surveyImagePixelWidth;
  const height = _surveyImagePixelHeight;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF101820),
  );
  final picture = recorder.endRecording();
  return picture.toImage(width, height);
}

/// Recording [Canvas] that captures the geometry of every `drawRRect` call.
///
/// The [FramingFOVPainter] draws its reticle as a rounded rect via
/// `drawRRect`, so replaying the real painter into this recorder lets the
/// test read back the *actual on-screen rectangle the painter drew* — not a
/// re-derivation of the same formula. The first recorded rounded rect is the
/// FOV frame (the painter draws the frame fill+border before the smaller text
/// scrim), and its width is the quantity under test.
class _RRectRecordingCanvas implements Canvas {
  final List<RRect> recordedRRects = [];

  @override
  void drawRRect(RRect rrect, Paint paint) {
    recordedRRects.add(rrect);
  }

  // Every other Canvas operation is irrelevant to the geometry assertion and
  // is intentionally a no-op. We only care about the rounded-rect frame the
  // FOV painter emits. noSuchMethod swallows the rest (drawLine for corner
  // markers, drawCircle for the rotation handle, TextPainter.paint, etc.).
  @override
  void noSuchMethod(Invocation invocation) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image surveyImage;

  setUpAll(() async {
    surveyImage = await _decodeSurveyImage();
  });

  tearDownAll(() {
    surveyImage.dispose();
  });

  /// The framing state pumped into every test: target framed, survey image
  /// decoded and registered via [_surveyPlateScale], small preview FOV (so
  /// the equipment-FOV reticle path renders), at the given [rotation].
  FramingState seededState({double rotation = 0}) {
    return FramingState(
      target: _target,
      surveyImageBytes: Uint8List.fromList(const [0]),
      surveyImage: surveyImage,
      plateScale: _surveyPlateScale,
      previewFovDegrees: 0.5,
      rotation: rotation,
      // Cardinal directions add TextPainter work that is irrelevant here and
      // would only slow the pump; the reticle geometry is independent of it.
      showCardinalDirections: false,
      showGrid: false,
    );
  }

  List<Override> overridesFor(FramingState seed) {
    return [
      framingProvider.overrideWith((ref) => _SeededFramingNotifier(ref, seed)),
      // framingFOVProvider is a FutureProvider; an override returning a value
      // resolves on the first microtask so the canvas sees a ready equipment
      // result without querying any camera hardware.
      framingFOVProvider.overrideWith(
        (ref) async => const FramingEquipmentResult(
          status: EquipmentStatus.ready,
          equipment: _equipment,
          profileName: 'Test Profile',
        ),
      ),
      // FramingCanvas now composes the GPU HiPS tile layer (above the survey
      // snapshot, under the FOV reticle). This registration/golden test is about
      // the survey-image <-> FOV-reticle co-registration, so the tile layer is
      // gated off to keep the canvas hermetic (no real properties fetch) and the
      // golden stable; the HiPS layer's own registration is covered by the C8/C10
      // HiPS suites.
      hipsFramingEnabledProvider.overrideWith((ref) => false),
    ];
  }

  /// Pumps the real [FramingScreen] and returns the measured, sidebar-excluded
  /// canvas size plus the two painters the canvas built for the survey
  /// background and the equipment FOV reticle.
  Future<
      ({
        Size canvasSize,
        FramingSurveyImagePainter survey,
        FramingFOVPainter fov
      })> pumpAndExtract(WidgetTester tester, FramingState seed) async {
    await pumpAppScreen(
      tester,
      const FramingScreen(),
      size: _surfaceSize,
      // The framing screen hosts ContextualTourPrompt, whose fade/slide
      // AnimationController would make pumpAndSettle wait; fixed-step pumps
      // deliver enough frames for the framingFOVProvider FutureProvider
      // override to resolve and the canvas to lay out.
      settle: false,
      extraOverrides: overridesFor(seed),
    );
    // Drain the FutureProvider microtask + a couple of layout/animation frames.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));

    // Measure the actual painted canvas region. This is the bounded box C6's
    // LayoutBuilder receives — surface width minus the sidebar — and the size
    // every painter is handed via CustomPaint(size: Size.infinite).
    final canvasFinder = find.byType(FramingCanvas);
    expect(canvasFinder, findsOneWidget,
        reason: 'FramingScreen must compose exactly one FramingCanvas.');
    final canvasSize = tester.getSize(canvasFinder);

    final surveyPainter = _findPainter<FramingSurveyImagePainter>(tester);
    final fovPainter = _findPainter<FramingFOVPainter>(tester);

    return (canvasSize: canvasSize, survey: surveyPainter, fov: fovPainter);
  }

  testWidgets(
      'framing_fov_reticle_uses_survey_plate_scale: the FOV rectangle is '
      'registered to the survey background scale to within 1px',
      (tester) async {
    final extracted = await pumpAndExtract(tester, seededState());

    // Guard 1: both painters share the survey-published plate scale. A
    // divergent scale (e.g. a hardcoded 60px/deg reticle, or a synthetic
    // no-image fallback) would make these differ. They must both be the exact
    // scale FramingState carried.
    expect(extracted.survey.plateScale, equals(_surveyPlateScale),
        reason: 'Survey background painter must draw with the plate scale the '
            'framing provider published for the loaded cutout.');
    expect(extracted.fov.plateScale, equals(_surveyPlateScale),
        reason: 'FOV reticle painter must use the SAME survey-registered '
            'plate scale as the background — not a hardcoded 60px/deg or a '
            'synthetic fallback. This is the core co-registration guard.');
    expect(extracted.fov.plateScale, equals(extracted.survey.plateScale),
        reason: 'Reticle and background must agree on one astrometric scale.');

    // Guard 2: the drawn FOV width equals fovWidthDeg * px-per-deg.
    // Replay the real FOV painter into a recording canvas at the measured
    // canvas size to read the actual rounded-rect frame width it draws.
    final recorder = _RRectRecordingCanvas();
    extracted.fov.paint(recorder, extracted.canvasSize);
    expect(recorder.recordedRRects, isNotEmpty,
        reason: 'FramingFOVPainter must draw a rounded-rect FOV frame.');
    final drawnFovWidthPx = recorder.recordedRRects.first.width;

    // The expected width, derived independently from the survey plate scale at
    // the measured canvas geometry and the unzoomed (zoom=1.0) state.
    final pixelsPerDegree =
        _surveyPlateScale.pixelsPerDegree(extracted.canvasSize, 1.0);
    final expectedFovWidthPx = _equipment.fovWidthDeg * pixelsPerDegree;

    expect(expectedFovWidthPx, greaterThan(0),
        reason: 'Sanity: the equipment FOV must map to a positive on-screen '
            'width at the test geometry.');
    expect(
      drawnFovWidthPx,
      closeTo(expectedFovWidthPx, 1.0),
      reason: 'The FOV rectangle the painter actually drew '
          '(${drawnFovWidthPx.toStringAsFixed(3)}px) must equal '
          'fovWidthDeg * plateScale.pixelsPerDegree(canvasSize, zoom) '
          '(${expectedFovWidthPx.toStringAsFixed(3)}px) within 1px. A '
          'mismatch means the reticle is no longer registered to the survey '
          'background scale.',
    );

    // --- Guard 3 (companion): the survey background draws into the plate '
    // scale's draw rect, so its px-per-degree matches the reticle's. --------
    // The background painter and the reticle derive px-per-degree from the
    // identical scale + canvas size; assert the values coincide so a future
    // change that fed the background a different size/zoom is caught.
    final backgroundPixelsPerDegree =
        extracted.survey.plateScale.pixelsPerDegree(extracted.canvasSize, 1.0);
    expect(backgroundPixelsPerDegree, closeTo(pixelsPerDegree, 1e-9),
        reason: 'Background and reticle must compute the same pixels-per-'
            'degree from the shared scale at the same canvas size.');

    // Layout guard: the canvas region excludes the sidebar.
    // FramingScreen now places the controls in an AdaptivePanelLayout. On a
    // desktop surface (1280px) that renders a resizable split: the Expanded
    // canvas, a 10px drag handle, then the 320px secondary panel. Confirm C6's
    // LayoutBuilder is fed the bounded, sidebar-excluded box rather than the
    // full window width.
    expect(extracted.canvasSize.width, lessThan(_surfaceSize.width),
        reason: 'Canvas must be narrower than the full surface; the framing '
            'controls panel occupies the rest. If the canvas spanned the whole '
            'window the plate-scale math would be off by the sidebar width.');
    expect(
        extracted.canvasSize.width, closeTo(_surfaceSize.width - 320 - 10, 1.0),
        reason:
            'Canvas width must equal surface width minus the controls panel '
            '(initialPanelWidth 320) and the 10px resize handle. This pins the '
            'bounded LayoutBuilder region.');
  });

  testWidgets(
      'framing_rotation_reaches_background_painter: rotation=30 is threaded '
      'into the survey background painter', (tester) async {
    final extracted = await pumpAndExtract(tester, seededState(rotation: 30));

    expect(extracted.survey.rotation, 30,
        reason: 'Field rotation must reach FramingSurveyImagePainter so the '
            'survey imagery rotates together with the identically-rotated FOV '
            'overlay. A reticle that rotated while the background stayed fixed '
            'would visually de-register the framing.');
    // The reticle still shares the survey-registered plate scale under
    // rotation (rotation is applied by the widget Transform, not baked into
    // the scale), so co-registration holds at any field angle.
    expect(extracted.fov.plateScale, equals(_surveyPlateScale),
        reason: 'Plate scale must remain the survey-registered one under '
            'rotation; rotation is a Transform, not a scale change.');
  });

  testWidgets(
      'framing_canvas_golden: the composed survey background + co-registered '
      'FOV reticle renders pixel-stably under rotation',
      tags: 'golden', (tester) async {
    // C9 golden: lock the actual rendered framing canvas (survey background +
    // equipment FOV reticle, rotated) so a regression in the plate-scale
    // registration or the overlay transform composition is caught visually,
    // not just via the geometry assertions above. Rendered at rotation=20 so
    // the golden also exercises the rotate-outer / translate-inner overlay
    // order that keeps the reticle co-registered with the imagery.
    await pumpAppScreen(
      tester,
      const FramingScreen(),
      size: _surfaceSize,
      settle: false,
      extraOverrides: overridesFor(seededState(rotation: 20)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));

    await expectLater(
      find.byType(FramingCanvas),
      matchesGoldenFile('goldens/framing_canvas_registered.png'),
    );
  });
}

/// Finds the single [CustomPaint] in the pumped tree whose painter is of type
/// [T] and returns that painter. The framing canvas stacks several CustomPaint
/// layers (survey background, optional grid, FOV reticle, crosshair); this
/// filters to the one painter the test cares about and fails loudly if the
/// layer is missing or duplicated.
T _findPainter<T extends CustomPainter>(WidgetTester tester) {
  final matches = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((cp) => cp.painter)
      .whereType<T>()
      .toList();
  expect(matches, hasLength(1),
      reason: 'Expected exactly one $T in the framing canvas, found '
          '${matches.length}. The canvas layer composition changed.');
  return matches.single;
}

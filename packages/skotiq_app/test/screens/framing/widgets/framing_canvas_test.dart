// Tests for the FramingCanvas integration:
//
//   * the on-canvas scale bar reports a *real* angular distance derived from the
//     shared FramingPlateScale, so it scales with the preview FOV rather than
//     reading a fixed value,
//   * the survey-source picker is a real SkotiqDropdown wired to
//     FramingNotifier.setSurveySource (selecting a band changes the active
//     source — no dead handler),
//   * the no-image fallback still renders the FOV reticle (the synthetic plate
//     scale is valid before any survey imagery is fetched).
//
// The canvas reads the framing notifier through Riverpod for its controls, so
// every pump wraps the widget in a ProviderScope with a real FramingNotifier
// and the Skotiq dark theme (the canvas resolves semantic colors at
// runtime).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_canvas.dart';
import 'package:skotiq_app/widgets/tutorial_keys/framing_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A camera + scope giving a roughly 1.5° x 1.0° field, large enough that the
/// FOV reticle and the scale bar both have meaningful geometry on a desktop-size
/// canvas.
const _equipment = FramingEquipment(
  cameraName: 'Test Camera',
  sensorWidthMm: 23.5,
  sensorHeightMm: 15.7,
  pixelSizeMicrons: 3.76,
  pixelsX: 6248,
  pixelsY: 4176,
  telescopeName: 'Test Scope',
  focalLengthMm: 900,
  apertureMm: 150,
);

const _equipmentResult = FramingEquipmentResult(
  status: EquipmentStatus.ready,
  equipment: _equipment,
  profileName: 'Test Profile',
);

Future<ProviderContainer> _pumpCanvas(
  WidgetTester tester, {
  required FramingState framingState,
  FramingEquipmentResult? equipmentResult,
  void Function(double, double, Size)? onPan,
  void Function(double)? onRotate,
  void Function(double, double)? onAimChanged,
  void Function(Size)? onCanvasResized,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  // FramingCanvas now composes the GPU HiPS tile layer in its Stack (above the
  // survey snapshot, under the FOV overlays). These tests predate HiPS and
  // exercise the scale bar / survey dropdown / no-image FOV reticle, so the tile
  // layer must stay inert here: gating it off keeps the canvas hermetic (no real
  // properties fetch / network) and the assertions focused on what they cover.
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      hipsFramingEnabledProvider.overrideWith((ref) => false),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 800,
            child: FramingCanvas(
              colors: SkotiqColors.dark,
              framingState: framingState,
              equipmentResult: equipmentResult,
              onPan: onPan ?? (_, __, ___) {},
              onRotate: onRotate ?? (_) {},
              onAimChanged: onAimChanged ?? (_, __) {},
              onCanvasResized: onCanvasResized ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Reads the scale-bar's angular label (the trailing text of the `_ScaleIndicator`).
String _scaleLabel(WidgetTester tester) {
  final labels = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data)
      .whereType<String>()
      .where((s) => s.endsWith("'") || s.endsWith('°'))
      .toList();
  expect(labels, isNotEmpty,
      reason: 'expected a scale-bar label ending in arcmin or degree');
  return labels.first;
}

void main() {
  testWidgets('scale bar reports a real angular distance, not a fixed 10\'',
      (tester) async {
    // A narrow preview FOV (0.5°) packs more pixels per degree than a wide one,
    // so the snapped scale-bar value must be SMALLER for the narrow field — it
    // cannot be a constant.
    await _pumpCanvas(
      tester,
      framingState: const FramingState(previewFovDegrees: 0.5),
    );
    final narrowLabel = _scaleLabel(tester);

    await _pumpCanvas(
      tester,
      framingState: const FramingState(previewFovDegrees: 8.0),
    );
    final wideLabel = _scaleLabel(tester);

    expect(narrowLabel, isNot(equals(wideLabel)),
        reason:
            'the scale bar must track the plate scale, so a 0.5° field and an '
            '8° field cannot show the same label');
  });

  testWidgets('scale bar promotes to degrees for very wide fields',
      (tester) async {
    // At an 800px canvas width a 20° preview field is ~40px per degree, so the
    // largest "nice" step fitting the ~60px target bar is 60' — which the label
    // formats as a whole degree rather than 60 arcminutes.
    await _pumpCanvas(
      tester,
      framingState: const FramingState(previewFovDegrees: 20.0),
    );
    expect(_scaleLabel(tester), endsWith('°'),
        reason: 'a 20° field should yield a degree-scale bar');
  });

  testWidgets('survey-source dropdown is present and lists every survey band',
      (tester) async {
    await _pumpCanvas(
      tester,
      framingState: const FramingState(surveySource: SurveySource.dss2Red),
    );

    expect(find.byType(SkotiqDropdown), findsOneWidget);

    // Open the menu and assert every survey source is offered.
    await tester.tap(find.byType(SkotiqDropdown));
    await tester.pumpAndSettle();

    for (final source in SurveySource.values) {
      expect(find.text(source.displayName), findsWidgets,
          reason: '${source.displayName} should appear in the survey menu');
    }
  });

  testWidgets(
      'selecting a survey source drives FramingNotifier.setSurveySource',
      (tester) async {
    final container = await _pumpCanvas(
      tester,
      framingState: const FramingState(surveySource: SurveySource.dss2Red),
    );

    expect(container.read(framingProvider).surveySource, SurveySource.dss2Red);

    await tester.tap(find.byType(SkotiqDropdown));
    await tester.pumpAndSettle();

    // Pick a different band; the dropdown menu shows display names.
    await tester.tap(find.text(SurveySource.sdss.displayName).last);
    await tester.pumpAndSettle();

    expect(container.read(framingProvider).surveySource, SurveySource.sdss,
        reason: 'selecting SDSS must call setSurveySource on the notifier');
  });

  testWidgets('FOV reticle renders before any survey image is fetched',
      (tester) async {
    await _pumpCanvas(
      tester,
      framingState: const FramingState(previewFovDegrees: 1.0),
      equipmentResult: _equipmentResult,
    );

    // The FOV painter carries the dedicated tutorial key; its presence proves
    // the synthetic plate-scale fallback produced a renderable reticle with no
    // survey image loaded.
    expect(find.byKey(FramingTutorialKeys.fovRect), findsOneWidget);
  });
}

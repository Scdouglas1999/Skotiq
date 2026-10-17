// The wizard's sky preview must draw the plan it is previewing, including
// panels on the far side of the RA 0h seam.
//
// The planner places each panel from `(panelRa - centreRa) * 15` degrees. RA is
// circular, so a mosaic centred at 0.0h puts its western column at ~23.9h and
// that subtraction reads 358.5 degrees instead of -1.5: the whole column is
// positioned a full sky away and lands off the canvas, leaving the user framing
// a mosaic whose panels they can neither see nor toggle.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mosaic_wizard_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_backend.dart';
import '../../../harness/pump_app_screen.dart';

const _testOptics = OpticalConfig(
  telescopeName: 'Test scope',
  focalLength: 500,
  aperture: 100,
  cameraName: 'Test cam',
  sensorWidth: 4144,
  sensorHeight: 2822,
  pixelSize: 4.63,
);

Future<void> _pumpMosaicAt(
  WidgetTester tester, {
  required double initialRa,
  required double initialDec,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1600, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final backend = mockBackend();
  when(() => backend.hasCheckpoint()).thenAnswer((_) async => false);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider
            .overrideWith((ref) => TestBackendNotifier(ref, backend)),
        smartNightExposureContextProvider.overrideWith((ref) async => null),
        opticalConfigProvider.overrideWithValue(_testOptics),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: MosaicWizardDialog(
            initialRa: initialRa,
            initialDec: initialDec,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Panels whose centre falls inside the planner canvas — i.e. the ones the user
/// can actually see and tap.
int _panelsInsidePlanner(WidgetTester tester, {required int rows, int? cols}) {
  final plannerRect =
      tester.getRect(find.byKey(const ValueKey('mosaic_visual_planner')));
  var visible = 0;
  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < (cols ?? rows); col++) {
      final finder = find.byKey(ValueKey('mosaic_panel_${row}_$col'));
      if (finder.evaluate().isEmpty) continue;
      if (plannerRect.contains(tester.getRect(finder).center)) visible++;
    }
  }
  return visible;
}

void main() {
  testWidgets('every panel of a mosaic centred on RA 0h is drawn on the canvas',
      (tester) async {
    await _pumpMosaicAt(tester, initialRa: 0.0, initialDec: 30.0);

    expect(_panelsInsidePlanner(tester, rows: 3), 9);
  });

  testWidgets('a mosaic centred just west of the seam still draws every panel',
      (tester) async {
    await _pumpMosaicAt(tester, initialRa: 23.9, initialDec: 30.0);

    expect(_panelsInsidePlanner(tester, rows: 3), 9);
  });

  testWidgets('a mosaic far from the seam is unaffected', (tester) async {
    await _pumpMosaicAt(tester, initialRa: 12.5, initialDec: 30.0);

    expect(_panelsInsidePlanner(tester, rows: 3), 9);
  });
}

// Every active mosaic panel must carry a legible number.
//
// A panel number centred in its cell puts the middle panel of any odd grid
// directly under the drag-centre handle — both are drawn at exactly the
// planner's centre point — so the operator cannot tell which cell is panel 5,
// or which one they are about to toggle off.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mosaic_wizard_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

Future<void> _pumpMosaic(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1600, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.exceptionAsString().contains('A RenderFlex overflowed by')) {
      return;
    }
    FlutterError.presentError(details);
  };
  addTearDown(() => FlutterError.onError = FlutterError.presentError);

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
        home: const Scaffold(
          body: MosaicWizardDialog(initialRa: 12.5, initialDec: 30),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Drives the Grid card's Columns/Rows steppers down/up to the wanted size.
/// The steppers carry no keys, so we locate each by its label and tap the
/// minus (first) or plus (second) button inside the same stepper column.
Future<void> _setGrid(
  WidgetTester tester, {
  required int cols,
  required int rows,
}) async {
  for (final entry in <(String, int)>[('Columns', cols), ('Rows', rows)]) {
    final stepper = find
        .ancestor(
          of: find.text(entry.$1),
          matching: find.byType(Column),
        )
        .first;
    for (var current = 3; current != entry.$2;) {
      final buttons =
          find.descendant(of: stepper, matching: find.byType(InkWell));
      final step = current > entry.$2 ? 0 : 1;
      await tester.tap(buttons.at(step), warnIfMissed: false);
      await tester.pumpAndSettle();
      current += current > entry.$2 ? -1 : 1;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every panel of the default 3x3 grid is numbered on the sky map',
      (tester) async {
    await _pumpMosaic(tester);

    final planner = find.byKey(const ValueKey('mosaic_visual_planner'));
    expect(planner, findsOneWidget);

    for (var n = 1; n <= 9; n++) {
      expect(
        find.descendant(of: planner, matching: find.text('$n')),
        findsOneWidget,
        reason: 'panel $n has no visible number on the sky preview',
      );
    }
  });

  testWidgets('the drag-centre handle does not sit on a panel number',
      (tester) async {
    await _pumpMosaic(tester);

    final planner = find.byKey(const ValueKey('mosaic_visual_planner'));
    final handle = tester.getRect(
      find.descendant(
        of: planner,
        matching: find.byKey(const ValueKey('mosaic_center_handle')),
      ),
    );

    for (var n = 1; n <= 9; n++) {
      final label = tester.getRect(
        find.descendant(of: planner, matching: find.text('$n')),
      );
      expect(
        label.overlaps(handle),
        isFalse,
        reason: 'panel $n\'s number is under the drag-centre handle',
      );
    }
  });

  testWidgets('an EVEN grid still wins the z-order against the centre handle',
      (tester) async {
    // The odd-grid case above puts the handle in the middle of one cell, so
    // a top-left badge clears it. An EVEN grid puts the handle on the shared
    // CORNER of four cells - exactly where a top-left badge lives - and the
    // collision comes back (measured at 2x2: the "2" badge overlapped the
    // handle rect). No corner placement clears the handle for both parities,
    // so the invariant that actually protects the operator is paint order:
    // every panel number is drawn AFTER the handle.
    await _pumpMosaic(tester);
    await _setGrid(tester, cols: 2, rows: 2);

    final planner = find.byKey(const ValueKey('mosaic_visual_planner'));
    for (var n = 1; n <= 4; n++) {
      expect(
        find.descendant(of: planner, matching: find.text('$n')),
        findsOneWidget,
        reason: 'panel $n has no visible number on the sky preview',
      );
    }

    // Elements come back in depth-first tree order, which inside one Stack
    // is paint order. The handle must be the FIRST of these and all four
    // numbers must follow it.
    final painted = find
        .byWidgetPredicate((w) {
          final key = w.key;
          if (key == const ValueKey('mosaic_center_handle')) return true;
          return key is ValueKey<String> &&
              key.value.startsWith('mosaic_panel_number_');
        })
        .evaluate()
        .toList();

    expect(
      painted,
      hasLength(5),
      reason: 'expected 4 numbered panel badges plus the centre handle',
    );
    expect(
      painted.first.widget.key,
      const ValueKey('mosaic_center_handle'),
      reason: 'a panel number is painted before the handle, so the handle '
          'draws on top of the digit',
    );
  });

  testWidgets('the corner badge survives a fully zoomed-out planner',
      (tester) async {
    await _pumpMosaic(tester);

    // Smallest panels the planner can draw: three clicks of zoom-out clamps
    // at 25%. The badge must not overflow the cell it sits in.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.pumpAndSettle();
    }

    expect(tester.takeException(), isNull);
    for (var n = 1; n <= 9; n++) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('mosaic_visual_planner')),
          matching: find.text('$n'),
        ),
        findsOneWidget,
      );
    }
  });
}

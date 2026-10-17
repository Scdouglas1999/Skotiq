// Regression tests: the Annotations tab must name the blocker that is actually
// in the way, and must not clip the sentence that names it.
//
// Observed on the running desktop build after 12 successful captures with no
// plate solver installed:
//
//   * the objects list read "No image annotated / Capture an image to see
//     detected objects" — an instruction to redo something already done a
//     dozen times, while the status card two rows above said "No plate solver
//     installed";
//   * that status card's own second line was hard-clipped flat at the panel
//     edge mid-word ("...in Settings to label ob") with no ellipsis, because
//     its text column was laid out at its unconstrained intrinsic width.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_app/screens/imaging/widgets/annotation_panel.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_ui/nightshade_ui.dart';

import '../../harness/harness.dart';

/// The exact state the annotation pipeline lands in on a machine with no
/// external solver: `plateSolveFailed` carrying the "no solver configured"
/// wording that AnnotationStatusIndicator recognises.
const AnnotationState _solverMissingState = AnnotationState(
  status: AnnotationStatus.plateSolveFailed,
  message: 'Plate solve failed',
  errorDetails: 'No supported external plate solver is configured. '
      'Install ASTAP or set its path in Settings.',
);

CapturedImageData _frame() => CapturedImageData(
      width: 4,
      height: 4,
      displayData: Uint8List(4 * 4 * 4),
      histogram: const <int>[],
      stats: const ImageStats(),
      capturedAt: DateTime.utc(2026, 8, 1, 3, 14),
      settings: const ExposureSettings(exposureTime: 30, gain: 100, offset: 10),
      filePath: '/tmp/Unknown_NoFilter_2026-08-01_0012.fits',
    );

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows partial objects while the deep catalog is still searching',
      (tester) async {
    final handle = await pumpAppScreen(
        tester, const AnnotationTabPanel(colors: NightshadeColors.dark),
        size: const Size(360, 1000), settle: false);
    await _drain(tester);
    handle.container.read(currentAnnotationProvider.notifier).state =
        ImageAnnotation(
      imagePath: '/tmp/target.fits',
      timestamp: DateTime.utc(2026, 10, 7),
      plateSolve: const PlateSolveData(
          ra: 341.8,
          dec: 58.1,
          pixelScale: 0.79,
          rotation: 0,
          fieldWidth: 1,
          fieldHeight: 1,
          imageWidth: 1000,
          imageHeight: 1000),
      objects: [
        const CelestialObjectAnnotation(
            id: 'dso_NGC7380',
            name: 'NGC7380',
            type: ObjectType.starCluster,
            ra: 341.8,
            dec: 58.1,
            x: 500,
            y: 500,
            magnitude: 7.2)
      ],
    );
    handle.container.read(annotationStateProvider.notifier).state =
        const AnnotationState(
      status: AnnotationStatus.searchingCatalogs,
      message: 'Found 1 object · searching deep catalog…',
      objectsFound: 1,
    );
    await _drain(tester);
    expect(find.text('NGC7380'), findsOneWidget);
    expect(
        find.text('Found 1 object · searching deep catalog…'), findsOneWidget);
    expect(find.text('No image annotated'), findsNothing);
  });

  testWidgets(
      'empty_state_names_the_missing_solver: with frames on disk and no plate '
      'solver, the objects list stops telling the operator to capture an image',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const AnnotationTabPanel(colors: NightshadeColors.dark),
      size: const Size(320, 900),
      settle: false,
    );
    await _drain(tester);

    // A frame IS on the canvas; the annotator is blocked on a missing solver.
    handle.container.read(currentImageProvider.notifier).state = _frame();
    handle.container.read(annotationStateProvider.notifier).state =
        _solverMissingState;
    await _drain(tester);

    expect(
      find.text('Capture an image to see detected objects'),
      findsNothing,
      reason: 'The operator has already captured; instructing them to capture '
          'again names the wrong blocker.',
    );
    expect(
      find.text('Cannot annotate: no plate solver'),
      findsOneWidget,
      reason: 'The empty state must name the blocker the status card above it '
          'already reports.',
    );
    expect(
      find.text('Install ASTAP or set its path in Settings to label objects.'),
      findsOneWidget,
      reason: 'And it must say what to do about it.',
    );
  });

  testWidgets(
      'empty_state_still_says_capture_when_nothing_captured: with no frame the '
      'original instruction is the correct one', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const AnnotationTabPanel(colors: NightshadeColors.dark),
      size: const Size(320, 900),
      settle: false,
    );
    await _drain(tester);

    // No currentImage seeded, and the solver is just as missing as above.
    handle.container.read(annotationStateProvider.notifier).state =
        _solverMissingState;
    await _drain(tester);

    expect(
      find.text('Capture an image to see detected objects'),
      findsOneWidget,
      reason: 'Before the first frame, "go capture something" IS the blocker — '
          'the fix must not invert into never saying it.',
    );
  });

  testWidgets(
      'empty_state_names_the_missing_catalog: catalogsNotInstalled points at '
      'the catalog, not at the camera', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const AnnotationTabPanel(colors: NightshadeColors.dark),
      size: const Size(320, 900),
      settle: false,
    );
    await _drain(tester);

    handle.container.read(currentImageProvider.notifier).state = _frame();
    handle.container.read(annotationStateProvider.notifier).state =
        const AnnotationState(status: AnnotationStatus.catalogsNotInstalled);
    await _drain(tester);

    expect(find.text('Cannot annotate: no catalog'), findsOneWidget);
    expect(find.text('Capture an image to see detected objects'), findsNothing);
  });

  testWidgets(
      'solver_warning_wraps_inside_the_panel: the status card\'s hint is laid '
      'out within the panel width instead of running off it', (tester) async {
    const panelWidth = 320.0;
    final handle = await pumpAppScreen(
      tester,
      const AnnotationTabPanel(colors: NightshadeColors.dark),
      size: const Size(panelWidth, 900),
      settle: false,
    );
    await _drain(tester);

    handle.container.read(currentImageProvider.notifier).state = _frame();
    handle.container.read(annotationStateProvider.notifier).state =
        _solverMissingState;
    await _drain(tester);

    final hint = find.text(
        'Optional: install ASTAP or set its path in Settings to label objects');
    expect(hint, findsOneWidget,
        reason: 'The solver-missing hint must render in the status card.');

    // The defect: the hint was laid out at its full intrinsic width (one very
    // long line) and the Row simply overflowed the panel, so the tail was
    // clipped flat by the panel edge with no ellipsis. Laid out correctly it
    // can never be wider than the panel it lives in.
    final hintWidth = tester.getSize(hint).width;
    expect(hintWidth, lessThanOrEqualTo(panelWidth),
        reason: 'A hint wider than the panel is a hint whose tail the operator '
            'never sees.');
  });
}

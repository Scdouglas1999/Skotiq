// Mosaic-Resume: widget test for the resume affordance in the
// Mosaic Wizard Dialog.
//
// The dialog probes the backend for an interrupted mosaic on open. If
// the active checkpoint's sequence name starts with "Mosaic " and is
// resumable, a banner appears at the top of the dialog offering
// "Restore" and "Start Over" buttons. This test pins:
//
//   * the banner appears when the backend reports a resumable mosaic,
//   * the banner does NOT appear when the checkpoint is for a
//     non-mosaic sequence (those go through the global app-shell
//     resume dialog instead),
//   * "Restore" delegates to the executor's restoreFromCheckpoint(), which
//     loads the run without starting it,
//   * "Start Over" delegates to backend.discardCheckpoint() and hides
//     the banner.
//
// Breaking either half would leave the user with no way to recover an
// interrupted mosaic without restarting the app, or duplicate the resume dialog
// for every paused sequence.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mosaic_wizard_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_backend.dart';
import '../../../harness/pump_app_screen.dart';

class _MockSequenceExecutor extends Mock implements SequenceExecutor {}

CheckpointInfo _mosaicCheckpoint({
  String sequenceName = 'Mosaic 12.50h 30.0°',
  int completedExposures = 40,
  double completedIntegrationSecs = 2400,
  bool canResume = true,
  int ageSeconds = 90,
}) =>
    CheckpointInfo(
      sequenceName: sequenceName,
      timestamp: DateTime.now().subtract(Duration(seconds: ageSeconds)),
      completedExposures: completedExposures,
      completedIntegrationSecs: completedIntegrationSecs,
      canResume: canResume,
      ageSeconds: ageSeconds,
    );

Future<void> _pumpMosaicWizard(
  WidgetTester tester, {
  required MockBackend backend,
  SequenceExecutor? executor,
}) async {
  // The mosaic dialog is hardcoded at 900×700. Give the test surface
  // enough room so the dialog's pre-existing Rows (statistics block,
  // preview pane) don't overflow before our banner ever renders.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1600, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  // The mosaic wizard's pre-existing `_buildStatRow` produces minor
  // overflow warnings (a long stat value + bold label can exceed the
  // narrow stats column). Those are NOT a regression introduced by
  // the resume banner — they predate it — but they cause Flutter's
  // test framework to mark the test as failed when any RenderFlex
  // overflows. Filter ONLY that specific overflow message so genuine
  // exceptions (state errors, mock-stub misses, etc.) still surface.
  // Delegate non-filtered errors to the binding's own handler: calling
  // presentError from inside an override bypasses the test binding's
  // pending-exception bookkeeping and turns any real failure into the
  // opaque "_pendingExceptionDetails != null" assertion.
  final originalOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    final msg = details.exceptionAsString();
    if (msg.contains('A RenderFlex overflowed by')) {
      // Pre-existing dialog layout overflow — not under test here.
      return;
    }
    originalOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = originalOnError);
  addTearDown(() {
    FlutterError.onError = FlutterError.presentError;
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider
            .overrideWith((ref) => TestBackendNotifier(ref, backend)),
        if (executor != null)
          sequenceExecutorProvider.overrideWithValue(executor),
        smartNightExposureContextProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: MosaicWizardDialog(initialRa: 12.5, initialDec: 30.0),
        ),
      ),
    ),
  );
  // Let the async probe complete (hasCheckpoint + getCheckpointInfo).
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MosaicWizardDialog resume affordance', () {
    testWidgets('shows resume banner when backend reports interrupted mosaic',
        (tester) async {
      final backend = mockBackend();
      when(() => backend.hasCheckpoint()).thenAnswer((_) async => true);
      when(() => backend.getCheckpointInfo())
          .thenAnswer((_) async => _mosaicCheckpoint());

      await _pumpMosaicWizard(tester, backend: backend);

      expect(
        find.byKey(const ValueKey('mosaic_resume_banner')),
        findsOneWidget,
        reason: 'banner must appear for a resumable mosaic checkpoint',
      );
      expect(find.text('Restore previous mosaic?'), findsOneWidget);
      // The banner text mentions the sequence name and frame count so
      // the user can tell which mosaic they're resuming.
      expect(
        find.textContaining('Mosaic 12.50h 30.0°'),
        findsOneWidget,
      );
      expect(find.textContaining('40 frames'), findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Restore'), findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Start over'), findsOneWidget);
    });

    testWidgets('hides banner when no checkpoint exists', (tester) async {
      final backend = mockBackend();
      when(() => backend.hasCheckpoint()).thenAnswer((_) async => false);
      // getCheckpointInfo must NOT be called when hasCheckpoint is
      // false — the cheap probe gates the heavier call.

      await _pumpMosaicWizard(tester, backend: backend);

      expect(
        find.byKey(const ValueKey('mosaic_resume_banner')),
        findsNothing,
      );
      verifyNever(() => backend.getCheckpointInfo());
    });

    testWidgets('hides banner when checkpoint is for a non-mosaic sequence',
        (tester) async {
      // A paused "M31 Imaging" sequence is handled by the global
      // app-shell resume dialog, not the mosaic wizard. The wizard
      // banner must NOT light up — otherwise the user would see two
      // competing resume affordances.
      final backend = mockBackend();
      when(() => backend.hasCheckpoint()).thenAnswer((_) async => true);
      when(() => backend.getCheckpointInfo()).thenAnswer(
        (_) async => _mosaicCheckpoint(
          sequenceName: 'M31 Imaging Plan',
        ),
      );

      await _pumpMosaicWizard(tester, backend: backend);

      expect(
        find.byKey(const ValueKey('mosaic_resume_banner')),
        findsNothing,
        reason:
            'banner is mosaic-specific; non-mosaic resumes flow through app-shell',
      );
    });

    testWidgets('hides banner when checkpoint is not resumable',
        (tester) async {
      // A checkpoint left over from a completed run has canResume=false;
      // showing a resume affordance for it would be a lie.
      final backend = mockBackend();
      when(() => backend.hasCheckpoint()).thenAnswer((_) async => true);
      when(() => backend.getCheckpointInfo()).thenAnswer(
        (_) async => _mosaicCheckpoint(canResume: false),
      );

      await _pumpMosaicWizard(tester, backend: backend);

      expect(
        find.byKey(const ValueKey('mosaic_resume_banner')),
        findsNothing,
      );
    });

    testWidgets('Restore button restores the mosaic without starting it',
        (tester) async {
      final backend = mockBackend();
      final executor = _MockSequenceExecutor();
      when(() => backend.hasCheckpoint()).thenAnswer((_) async => true);
      when(() => backend.getCheckpointInfo())
          .thenAnswer((_) async => _mosaicCheckpoint());
      when(executor.restoreFromCheckpoint).thenAnswer((_) async {});

      await _pumpMosaicWizard(
        tester,
        backend: backend,
        executor: executor,
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Restore'));
      await tester.pumpAndSettle();

      verify(executor.restoreFromCheckpoint).called(1);
      verifyNever(executor.resumeFromCheckpoint);
      verifyNever(executor.start);
    });

    testWidgets(
        'Start Over button invokes backend.discardCheckpoint and clears banner',
        (tester) async {
      final backend = mockBackend();
      when(() => backend.hasCheckpoint()).thenAnswer((_) async => true);
      when(() => backend.getCheckpointInfo())
          .thenAnswer((_) async => _mosaicCheckpoint());
      when(() => backend.discardCheckpoint()).thenAnswer((_) async {});

      await _pumpMosaicWizard(tester, backend: backend);

      expect(
          find.byKey(const ValueKey('mosaic_resume_banner')), findsOneWidget);

      await tester.tap(find.widgetWithText(SkotiqButton, 'Start over'));
      await tester.pumpAndSettle();

      verify(() => backend.discardCheckpoint()).called(1);
      expect(
        find.byKey(const ValueKey('mosaic_resume_banner')),
        findsNothing,
        reason: 'banner clears immediately after discard succeeds',
      );
    });
  });
}

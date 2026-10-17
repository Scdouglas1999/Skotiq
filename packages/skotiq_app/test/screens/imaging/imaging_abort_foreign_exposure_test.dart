// Regression test: the imaging preview's "Abort capture" X must abort ANY
// in-flight exposure, not only one this screen started.
//
// Observed on the running build: the first-light flow was closed mid-capture,
// Imaging read "Exposing... 999858.8s remaining", and the X (tooltip "Abort
// capture", visibly highlighted) was clicked repeatedly over ~90 s while the
// countdown ran on and the native log gained ZERO lines. The button decides to
// SHOW itself from the global exposureProgressProvider, but the handler
// early-returned unless the screen's own `_isSingleCapture || _isLooping`
// flags were set — flags a first-light, centering or sequencer exposure never
// sets. So it was offered and dead.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/widgets/tutorial_keys/imaging_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// An imaging service that records the abort. It never captures here: the
/// exposure under test was started by somebody else (the first-light
/// orchestrator, centering, the sequencer) through this same service.
class _RecordingImagingService extends ImagingService {
  _RecordingImagingService(super.ref);

  int cancelCalls = 0;

  @override
  void cancelExposure() {
    cancelCalls++;
  }
}

List<Override> _connectedCamera() => [
      cameraStateProvider.overrideWith((ref) {
        final notifier = CameraStateNotifier(ref);
        notifier
          ..setConnecting('sim_camera_1', 'Simulated Camera')
          ..setConnected();
        return notifier;
      }),
    ];

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = defaultOnError);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'the abort reaches the camera for an exposure this screen did '
      'not start', (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
      extraOverrides: [
        ..._connectedCamera(),
        imagingServiceProvider.overrideWith(_RecordingImagingService.new),
      ],
    );
    await _drain(tester);
    final service = handle.container.read(imagingServiceProvider)
        as _RecordingImagingService;

    // A foreign exposure: the shared progress state is armed without the
    // Imaging screen ever having pressed Snapshot or Start.
    final progress = handle.container.read(exposureProgressProvider.notifier)
      ..startExposure(999999, 1, null);
    progress.updateProgress(141, 999858, 0);
    await _drain(tester);

    expect(
      find.byKey(ImagingTutorialKeys.abortBtn),
      findsOneWidget,
      reason: 'the toolbar offers the abort off the GLOBAL exposure progress',
    );

    await tester.tap(find.byKey(ImagingTutorialKeys.abortBtn));
    await _drain(tester);

    expect(
      service.cancelCalls,
      1,
      reason: 'a button that is offered must do what it says',
    );

    // Anti-relocation: the screen must not latch its local "stopping" flag for
    // a capture it does not own. That flag is only cleared in the capture
    // methods' finally, which never runs here, so latching it would hide the
    // abort for the rest of the session.
    expect(find.byKey(ImagingTutorialKeys.abortBtn), findsOneWidget);

    // Once the exposure really ends, the button goes away on its own.
    progress.reset();
    await _drain(tester);
    expect(find.byKey(ImagingTutorialKeys.abortBtn), findsNothing);
  });
}

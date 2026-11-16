// While a sequence run exposes, the capture bar's Snapshot button says the
// camera is the run's, as a secondary button: "Taking…" on the page's primary
// slab read as the operator's own snapshot, in the brand red the dark theme
// shares with errors.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_capture_bar.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _ExposingCamera extends CameraStateNotifier {
  _ExposingCamera(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = state.copyWith(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim_camera_1',
      deviceName: 'Simulated Camera',
      isExposing: true,
      exposureProgress: 0.4,
    );
  }
}

void _noop() {}

Future<void> _pumpBar(
  WidgetTester tester, {
  required SequenceExecutionState execution,
}) async {
  await pumpAppScreen(
    tester,
    const Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: 900,
        child: ImagingCaptureBar(
          isLooping: false,
          // The screen reads any exposure it did not start as one in flight.
          isSingleCapture: true,
          isSavingCapture: false,
          isStoppingCapture: false,
          onSnapshot: _noop,
          onToggleLoop: _noop,
        ),
      ),
    ),
    size: const Size(900, 900),
    settle: false,
    extraOverrides: <Override>[
      cameraStateProvider.overrideWith(_ExposingCamera.new),
      runRecordProvider.overrideWith(
        (ref) => RunRecordNotifier(ref, RunRecord(lifecycle: execution)),
      ),
    ],
  );
  await tester.pump(const Duration(milliseconds: 50));
}

SkotiqButton _snapshotButton(WidgetTester tester) =>
    tester.widget<SkotiqButton>(
      find.ancestor(
        of: find.textContaining(RegExp('Run capturing|Taking')),
        matching: find.byType(SkotiqButton),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a run\'s exposure is named as the run\'s', (tester) async {
    await _pumpBar(tester, execution: SequenceExecutionState.running);

    expect(find.text('Run capturing'), findsOneWidget);
    expect(find.text('Taking…'), findsNothing);
    final button = _snapshotButton(tester);
    expect(button.variant, ButtonVariant.secondary);
    expect(button.onPressed, isNull);
    expect(button.isLoading, isFalse);
  });

  testWidgets('an exposure with no run behind it is still "Taking…"',
      (tester) async {
    await _pumpBar(tester, execution: SequenceExecutionState.idle);

    expect(find.text('Taking…'), findsOneWidget);
    expect(_snapshotButton(tester).variant, ButtonVariant.primary);
  });
}

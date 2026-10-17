import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/focus_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

class _MockDeviceService extends Mock implements DeviceService {}

class _ConnectedFocuserNotifier extends FocuserStateNotifier {
  _ConnectedFocuserNotifier(super.ref) {
    state = const FocuserState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'focuser-1',
      deviceName: 'Test Focuser',
      position: 1000,
      isAbsolute: true,
    );
  }
}

class _ConnectedCameraNotifier extends CameraStateNotifier {
  _ConnectedCameraNotifier(super.ref) {
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'camera-1',
      deviceName: 'Test Camera',
    );
  }
}

final _serviceSlotProvider = StateProvider<DeviceService>(
  (ref) => throw UnimplementedError(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('focus panel discards autofocus completion from the old host',
      (tester) async {
    final serviceA = _MockDeviceService();
    final serviceB = _MockDeviceService();
    final resultA = Completer<AutofocusResult>();
    when(() => serviceA.isAutofocusRunning).thenReturn(false);
    when(() => serviceB.isAutofocusRunning).thenReturn(false);
    when(
      () => serviceA.runAutofocus(
        exposureTime: any(named: 'exposureTime'),
        stepSize: any(named: 'stepSize'),
        stepsOut: any(named: 'stepsOut'),
        method: any(named: 'method'),
        binning: any(named: 'binning'),
        useSettingsDefaults: any(named: 'useSettingsDefaults'),
      ),
    ).thenAnswer((_) => resultA.future);

    final handle = await pumpAppScreen(
      tester,
      const FocusPanel(colors: SkotiqColors.dark),
      extraOverrides: [
        focuserStateProvider.overrideWith(_ConnectedFocuserNotifier.new),
        cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
        _serviceSlotProvider.overrideWith((ref) => serviceA),
        deviceServiceProvider.overrideWith(
          (ref) => ref.watch(_serviceSlotProvider),
        ),
      ],
      settle: false,
    );
    await tester.pump();

    await tester.tap(find.text('Run Autofocus'));
    await tester.pump();
    expect(find.text('Running...'), findsOneWidget);

    handle.container.read(_serviceSlotProvider.notifier).state = serviceB;
    await tester.pump();
    expect(find.text('Run Autofocus'), findsOneWidget);

    resultA.complete(
      const AutofocusResult(
        bestPosition: 1200,
        bestHfr: 1.2,
        focusData: [],
        method: 'VCurve',
        timestamp: 0,
        curveFitQuality: 1,
        backlashApplied: false,
      ),
    );
    await tester.pump();
    expect(find.textContaining('Autofocus complete'), findsNothing);
    expect(find.text('Run Autofocus'), findsOneWidget);
  });
}

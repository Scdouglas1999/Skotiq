import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/widgets/focuser_controls.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

class _MockDeviceService extends Mock implements DeviceService {}

final _serviceSlotProvider = StateProvider<DeviceService>(
  (ref) => throw UnimplementedError(),
);

class _FixedFocuserNotifier extends FocuserStateNotifier {
  _FixedFocuserNotifier(super.ref) {
    state = const FocuserState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'focuser-1',
      deviceName: 'Test Focuser',
      position: 1000,
      isAbsolute: true,
    );
  }
}

class _FixedCameraNotifier extends CameraStateNotifier {
  _FixedCameraNotifier(super.ref, {required bool connected}) {
    state = CameraStateSnapshot(
      connectionState: connected
          ? DeviceConnectionState.connected
          : DeviceConnectionState.disconnected,
      deviceId: connected ? 'camera-1' : null,
      deviceName: connected ? 'Test Camera' : null,
    );
  }
}

List<Override> _overrides(
  _MockDeviceService service, {
  required bool cameraConnected,
}) {
  return [
    focuserStateProvider.overrideWith(_FixedFocuserNotifier.new),
    cameraStateProvider.overrideWith(
      (ref) => _FixedCameraNotifier(ref, connected: cameraConnected),
    ),
    deviceServiceProvider.overrideWithValue(service),
  ];
}

void main() {
  testWidgets('autofocus is disabled until both camera and focuser connect',
      (tester) async {
    final service = _MockDeviceService();
    await pumpAppScreen(
      tester,
      const FocuserControls(),
      extraOverrides: _overrides(service, cameraConnected: false),
    );

    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Run Autofocus'),
    );
    expect(button.onPressed, isNull);
    verifyNever(
      () => service.runAutofocus(
        exposureTime: any(named: 'exposureTime'),
        stepSize: any(named: 'stepSize'),
        stepsOut: any(named: 'stepsOut'),
        method: any(named: 'method'),
        binning: any(named: 'binning'),
        useSettingsDefaults: any(named: 'useSettingsDefaults'),
      ),
    );
  });

  testWidgets(
      'stop cancels autofocus and disables manual moves while it settles',
      (tester) async {
    final service = _MockDeviceService();
    final result = Completer<AutofocusResult>();
    when(() => service.isAutofocusRunning).thenReturn(false);
    when(() => service.cancelAutofocus()).thenAnswer((_) async {});
    when(() => service.haltFocuser()).thenAnswer((_) async {});
    when(() => service.moveFocuserRelative(any())).thenAnswer((_) async {});
    when(
      () => service.runAutofocus(
        exposureTime: any(named: 'exposureTime'),
        stepSize: any(named: 'stepSize'),
        stepsOut: any(named: 'stepsOut'),
        method: any(named: 'method'),
        binning: any(named: 'binning'),
        useSettingsDefaults: any(named: 'useSettingsDefaults'),
      ),
    ).thenAnswer((_) => result.future);

    await pumpAppScreen(
      tester,
      const FocuserControls(),
      extraOverrides: _overrides(service, cameraConnected: true),
    );

    await tester.tap(find.text('Run Autofocus'));
    await tester.pump();
    when(() => service.isAutofocusRunning).thenReturn(true);

    expect(find.text('Running...'), findsOneWidget);

    final control = find.byType(FocuserControls);
    final moveButtons = find.descendant(
      of: control,
      matching: find.byType(InkWell),
    );
    expect(moveButtons, findsNWidgets(5));
    for (final index in [0, 1, 3, 4]) {
      expect(tester.widget<InkWell>(moveButtons.at(index)).onTap, isNull);
    }

    await tester.tap(
      find.descendant(of: control, matching: find.byIcon(LucideIcons.octagon)),
    );
    await tester.pump();
    verify(() => service.cancelAutofocus()).called(1);
    verifyNever(() => service.haltFocuser());
    verifyNever(() => service.moveFocuserRelative(any()));

    result.complete(
      const AutofocusResult(
        bestPosition: 1000,
        bestHfr: 1.5,
        focusData: [],
        method: 'VCurve',
        timestamp: 0,
        curveFitQuality: 1,
        backlashApplied: false,
      ),
    );
    await tester.pump();
    expect(find.text('Run Autofocus'), findsOneWidget);
  });

  testWidgets('stop halts manual focuser motion when autofocus is idle',
      (tester) async {
    final service = _MockDeviceService();
    when(() => service.isAutofocusRunning).thenReturn(false);
    when(() => service.haltFocuser()).thenAnswer((_) async {});
    final handle = await pumpAppScreen(
      tester,
      const FocuserControls(),
      extraOverrides: _overrides(service, cameraConnected: true),
    );
    handle.container.read(focuserStateProvider.notifier).setMoving(true);
    await tester.pump();

    await tester.tap(find.byIcon(LucideIcons.octagon));
    await tester.pump();

    verify(() => service.haltFocuser()).called(1);
    verifyNever(() => service.cancelAutofocus());
  });

  testWidgets('stop is disabled when no focuser operation is active',
      (tester) async {
    final service = _MockDeviceService();
    await pumpAppScreen(
      tester,
      const FocuserControls(),
      extraOverrides: _overrides(service, cameraConnected: true),
    );

    final stop = find.ancestor(
      of: find.byIcon(LucideIcons.octagon),
      matching: find.byType(InkWell),
    );
    expect(tester.widget<InkWell>(stop).onTap, isNull);
  });

  testWidgets('late autofocus result from the old host is discarded',
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
    var completions = 0;

    final handle = await pumpAppScreen(
      tester,
      FocuserControls(onAutofocusComplete: () => completions++),
      extraOverrides: [
        focuserStateProvider.overrideWith(_FixedFocuserNotifier.new),
        cameraStateProvider.overrideWith(
          (ref) => _FixedCameraNotifier(ref, connected: true),
        ),
        _serviceSlotProvider.overrideWith((ref) => serviceA),
        deviceServiceProvider.overrideWith(
          (ref) => ref.watch(_serviceSlotProvider),
        ),
      ],
    );

    await tester.tap(find.text('Run Autofocus'));
    await tester.pump();
    expect(find.text('Running...'), findsOneWidget);

    handle.container.read(_serviceSlotProvider.notifier).state = serviceB;
    await tester.pump();
    expect(find.text('Run Autofocus'), findsOneWidget);

    resultA.complete(
      const AutofocusResult(
        bestPosition: 1200,
        bestHfr: 1.25,
        focusData: [],
        method: 'VCurve',
        timestamp: 0,
        curveFitQuality: 1,
        backlashApplied: false,
      ),
    );
    await tester.pump();

    expect(completions, 0);
    expect(find.textContaining('Autofocus complete'), findsNothing);
    expect(find.text('Run Autofocus'), findsOneWidget);
  });
}

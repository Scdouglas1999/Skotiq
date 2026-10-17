import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'device_action_finder.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/harness.dart';

class _MockDeviceService extends Mock implements DeviceService {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

class _ConnectedFocuserNotifier extends FocuserStateNotifier {
  _ConnectedFocuserNotifier(super.ref, {int? maxPosition}) {
    state = FocuserState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'focuser-1',
      deviceName: 'Test Focuser',
      position: 50,
      maxPosition: maxPosition,
      isAbsolute: true,
    );
  }
}

class _ConnectedRotatorNotifier extends RotatorStateNotifier {
  _ConnectedRotatorNotifier(super.ref) {
    state = const RotatorState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'rotator-1',
      deviceName: 'Test Rotator',
      position: 10,
    );
  }
}

class _ConnectedDomeNotifier extends DomeStateNotifier {
  _ConnectedDomeNotifier(super.ref) {
    state = const DomeState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'dome-1',
      deviceName: 'Test Dome',
      azimuth: 20,
    );
  }
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 5]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _waitForDialogToClose(
  WidgetTester tester,
  String title,
) async {
  for (var i = 0; i < 30 && find.text(title).evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('device action dialog closes when the imaging host changes',
      (tester) async {
    final hostA = mockBackend();
    final hostB = mockBackend();
    late _SwappableBackendNotifier notifier;

    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.focuser),
      extraOverrides: [
        backendProvider.overrideWith((ref) {
          notifier = _SwappableBackendNotifier(ref, hostA);
          return notifier;
        }),
        focuserStateProvider.overrideWith(
          (ref) => _ConnectedFocuserNotifier(ref),
        ),
      ],
      settle: false,
    );

    await tapDeviceAction(tester, 'Move to…');
    await _pumpFrames(tester);
    expect(find.text('Move focuser'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pumpAndSettle();

    expect(find.text('Move focuser'), findsNothing);
  });

  testWidgets(
      'focuser move shows an honest unknown maximum and remains retryable',
      (tester) async {
    final service = _MockDeviceService();
    var attempts = 0;
    when(() => service.moveFocuserTo(123)).thenAnswer((_) async {
      attempts++;
      if (attempts == 1) throw Exception('motor jam');
    });

    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.focuser),
      extraOverrides: [
        focuserStateProvider.overrideWith(
          (ref) => _ConnectedFocuserNotifier(ref),
        ),
        deviceServiceProvider.overrideWithValue(service),
      ],
      settle: false,
    );

    await tapDeviceAction(tester, 'Move to…');
    await _pumpFrames(tester);
    expect(find.textContaining('did not report a maximum'), findsOneWidget);
    expect(find.textContaining('50000'), findsNothing);

    await tester.enterText(find.byType(TextField), 'not-a-position');
    await tester.tap(find.text('Move'));
    await tester.pump();
    expect(find.text('Enter a whole-number focuser position.'), findsOneWidget);
    verifyNever(() => service.moveFocuserTo(any()));

    await tester.enterText(find.byType(TextField), '123');
    await tester.tap(find.text('Move'));
    await _pumpFrames(tester);
    expect(find.text('Move focuser'), findsOneWidget);
    expect(find.textContaining('motor jam'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '123',
    );

    await tester.tap(find.text('Move'));
    await _waitForDialogToClose(tester, 'Move focuser');
    expect(find.text('Move focuser'), findsNothing);
    verify(() => service.moveFocuserTo(123)).called(2);
  });

  testWidgets('focuser move enforces a reported travel limit', (tester) async {
    final service = _MockDeviceService();
    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.focuser),
      extraOverrides: [
        focuserStateProvider.overrideWith(
          (ref) => _ConnectedFocuserNotifier(ref, maxPosition: 1000),
        ),
        deviceServiceProvider.overrideWithValue(service),
      ],
      settle: false,
    );

    await tapDeviceAction(tester, 'Move to…');
    await _pumpFrames(tester);
    expect(find.text('Enter target position (0 - 1000):'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '1001');
    await tester.tap(find.text('Move'));
    await tester.pump();

    expect(find.text('Position must be between 0 and 1000.'), findsOneWidget);
    verifyNever(() => service.moveFocuserTo(any()));
  });

  testWidgets('an in-flight equipment focuser move exposes a real halt',
      (tester) async {
    final service = _MockDeviceService();
    final move = Completer<void>();
    when(() => service.moveFocuserTo(123)).thenAnswer((_) => move.future);
    when(() => service.haltFocuser()).thenAnswer((_) async {});

    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.focuser),
      extraOverrides: [
        focuserStateProvider.overrideWith(
          (ref) => _ConnectedFocuserNotifier(ref, maxPosition: 1000),
        ),
        deviceServiceProvider.overrideWithValue(service),
      ],
      settle: false,
    );

    await tapDeviceAction(tester, 'Move to…');
    await _pumpFrames(tester);
    await tester.enterText(find.byType(TextField), '123');
    await tester.tap(find.text('Move'));
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);

    await tester.tap(find.text('Stop'));
    await _waitForDialogToClose(tester, 'Move focuser');
    verify(() => service.haltFocuser()).called(1);
    expect(find.text('Move focuser'), findsNothing);

    move.completeError(StateError('move cancelled by halt'));
    await tester.pump();
  });

  testWidgets('rotator failure keeps the angle and permits a successful retry',
      (tester) async {
    final service = _MockDeviceService();
    var attempts = 0;
    when(() => service.moveRotatorTo(90)).thenAnswer((_) async {
      attempts++;
      if (attempts == 1) throw Exception('gear slip');
    });

    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.rotator),
      extraOverrides: [
        rotatorStateProvider.overrideWith(_ConnectedRotatorNotifier.new),
        equipmentRotatorCapabilitiesProvider('rotator-1').overrideWith(
          (ref) async => const RotatorCapabilities(
            canMoveAbsolute: true,
            minAngleDeg: 0,
            maxAngleDeg: 270,
          ),
        ),
        deviceServiceProvider.overrideWithValue(service),
      ],
      settle: false,
    );

    await tapDeviceAction(tester, 'Rotate to…');
    await _pumpFrames(tester);
    await tester.enterText(find.byType(TextField), '90');
    await tester.tap(find.text('Rotate'));
    await _pumpFrames(tester);

    expect(find.text('Rotate To Angle'), findsOneWidget);
    expect(find.textContaining('gear slip'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '90',
    );

    await tester.tap(find.text('Rotate'));
    await _waitForDialogToClose(tester, 'Rotate To Angle');
    expect(find.text('Rotate To Angle'), findsNothing);
    verify(() => service.moveRotatorTo(90)).called(2);
  });

  testWidgets('dome slew validates finite input and remains retryable on error',
      (tester) async {
    final backend = mockBackend();
    var attempts = 0;
    when(() => backend.domeSlewToAzimuth('dome-1', 42.5)).thenAnswer((_) async {
      attempts++;
      if (attempts == 1) throw Exception('shutter interlock');
    });

    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.dome),
      backend: backend,
      extraOverrides: [
        domeStateProvider.overrideWith(_ConnectedDomeNotifier.new),
        domeCapabilityFetcherProvider.overrideWithValue(
          (_) async => const DomeCapabilities(canSetAzimuth: true),
        ),
      ],
      settle: false,
    );

    await tapDeviceAction(tester, 'Slew…');
    await _pumpFrames(tester);
    await tester.enterText(find.byType(TextField), 'NaN');
    await tester.tap(find.text('Slew'));
    await tester.pump();
    expect(find.text('Enter a finite azimuth in degrees.'), findsOneWidget);
    verifyNever(() => backend.domeSlewToAzimuth(any(), any()));

    await tester.enterText(find.byType(TextField), '42.5');
    await tester.tap(find.text('Slew'));
    await _pumpFrames(tester);
    expect(find.text('Slew Dome To Azimuth'), findsOneWidget);
    expect(find.textContaining('shutter interlock'), findsOneWidget);

    await tester.tap(find.text('Slew'));
    await _waitForDialogToClose(tester, 'Slew Dome To Azimuth');
    expect(find.text('Slew Dome To Azimuth'), findsNothing);
    verify(() => backend.domeSlewToAzimuth('dome-1', 42.5)).called(2);
  });
}

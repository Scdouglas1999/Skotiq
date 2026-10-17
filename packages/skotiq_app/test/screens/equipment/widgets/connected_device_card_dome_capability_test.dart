import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'device_action_finder.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/harness.dart';

class _DomeNotifier extends DomeStateNotifier {
  _DomeNotifier(super.ref, this.initial) {
    state = initial;
  }

  final DomeState initial;
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

Future<void> pumpDome(
  WidgetTester tester, {
  required DomeState state,
  required DomeCapabilities capabilities,
}) async {
  await pumpAppScreen(
    tester,
    const ConnectedDeviceCard(type: ConnectedDeviceType.dome),
    extraOverrides: [
      domeStateProvider.overrideWith((ref) => _DomeNotifier(ref, state)),
      domeCapabilityFetcherProvider.overrideWithValue(
        (_) async => capabilities,
      ),
    ],
  );
}

void main() {
  const connected = DomeState(
    connectionState: DeviceConnectionState.connected,
    deviceId: 'dome-1',
    shutterStatus: ShutterStatus.closed,
  );

  testWidgets('dome actions are disabled when the driver lacks capabilities',
      (tester) async {
    await pumpDome(
      tester,
      state: connected,
      capabilities: const DomeCapabilities(),
    );

    for (final label in ['Open shutter', 'Park', 'Slew…', 'Home', 'Halt']) {
      await expectDeviceAction(tester, label, enabled: false, reason: label);
    }
  });

  testWidgets('supported idle dome actions are enabled but Halt is not',
      (tester) async {
    await pumpDome(
      tester,
      state: connected,
      capabilities: const DomeCapabilities(
        canSetShutter: true,
        canPark: true,
        canSetAzimuth: true,
        canFindHome: true,
        canAbort: true,
      ),
    );

    for (final label in ['Open shutter', 'Park', 'Slew…', 'Home']) {
      await expectDeviceAction(tester, label, enabled: true, reason: label);
    }
    await expectDeviceAction(tester, 'Halt', enabled: false);
  });

  testWidgets('parked dome is not offered a fabricated Unpark command',
      (tester) async {
    await pumpDome(
      tester,
      state: connected.copyWith(isParked: true),
      capabilities: const DomeCapabilities(canPark: true),
    );

    expect(find.text('Unpark'), findsNothing);
    await expectDeviceAction(tester, 'Parked', enabled: false);
  });

  testWidgets('only Halt remains available while the dome is slewing',
      (tester) async {
    await pumpDome(
      tester,
      state: connected.copyWith(isSlewing: true),
      capabilities: const DomeCapabilities(
        canPark: true,
        canSetAzimuth: true,
        canFindHome: true,
        canAbort: true,
      ),
    );

    await expectDeviceAction(tester, 'Park', enabled: false);
    await expectDeviceAction(tester, 'Slew…', enabled: false);
    await expectDeviceAction(tester, 'Home', enabled: false);
    await expectDeviceAction(tester, 'Halt', enabled: true);
  });

  testWidgets(
      'a completed old-host command cannot report success on a new host',
      (tester) async {
    final hostA = mockBackend();
    final hostB = mockBackend();
    final oldHostCommand = Completer<void>();
    late _SwappableBackendNotifier backendNotifier;
    when(() => hostA.domePark('dome-1'))
        .thenAnswer((_) => oldHostCommand.future);
    when(() => hostB.domePark('dome-1')).thenAnswer((_) async {});

    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.dome),
      extraOverrides: [
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwappableBackendNotifier(ref, hostA);
          return backendNotifier;
        }),
        domeStateProvider.overrideWith((ref) => _DomeNotifier(ref, connected)),
        domeCapabilityFetcherProvider.overrideWithValue(
          (_) async => const DomeCapabilities(canPark: true),
        ),
      ],
    );

    await tapDeviceAction(tester, 'Park');
    await tester.pump();
    backendNotifier.switchTo(hostB);
    oldHostCommand.complete();
    await tester.pumpAndSettle();

    expect(find.text('Parking dome'), findsNothing);
    await expectDeviceAction(tester, 'Park', enabled: true);

    await tapDeviceAction(tester, 'Park');
    await tester.pumpAndSettle();
    verify(() => hostB.domePark('dome-1')).called(1);
    expect(find.text('Parking dome'), findsOneWidget);
  });

  testWidgets('an old-host dome failure is not attributed to the new host',
      (tester) async {
    final hostA = mockBackend();
    final hostB = mockBackend();
    final oldHostCommand = Completer<void>();
    late _SwappableBackendNotifier backendNotifier;
    when(() => hostA.domeOpenShutter('dome-1'))
        .thenAnswer((_) => oldHostCommand.future);

    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.dome),
      extraOverrides: [
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwappableBackendNotifier(ref, hostA);
          return backendNotifier;
        }),
        domeStateProvider.overrideWith((ref) => _DomeNotifier(ref, connected)),
        domeCapabilityFetcherProvider.overrideWithValue(
          (_) async => const DomeCapabilities(canSetShutter: true),
        ),
      ],
    );

    // Wherever the action lives: inline, or behind "More actions" when the
    // touch-sized glyph buttons leave the row no room for it.
    await tapDeviceAction(tester, 'Open shutter');
    backendNotifier.switchTo(hostB);
    oldHostCommand.completeError(StateError('host A went away'));
    await tester.pumpAndSettle();

    expect(find.textContaining('host A went away'), findsNothing);
    await expectDeviceAction(tester, 'Open shutter', enabled: true);
  });
}

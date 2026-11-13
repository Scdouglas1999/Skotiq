// Pressing Connect on the guider used to REPLACE the friendly device name with
// the raw device id. Observed live on 2026-08-09 on an Android emulator paired
// to a headless appliance: the Devices tab read "Built-in Multi-Star Guider"
// while offline, and the instant it connected both that card and the
// guide-health card below it read `native:builtin_guider:multi_star`, and kept
// reading it, because nothing later restores the name.
//
// The device service is the one writer of a slot during a connect, so this
// pins what it publishes while the connect is in flight.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../harness/in_memory_database.dart';
import '../mocks/mock_backend.dart';

const _builtinGuiderId = 'native:builtin_guider:multi_star';
const _friendlyName = 'Built-in Multi-Star Guider';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

ProviderContainer _containerWith(List<DeviceInfo> connected) {
  final backend = MockBackend();
  when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
  when(
    () => backend.polarAlignmentEvents,
  ).thenAnswer((_) => const Stream.empty());
  when(() => backend.getConnectedDevices()).thenAnswer((_) async => connected);
  // The driver is still opening: the connect stays in flight.
  when(
    () => backend.connectDevice(
      any(),
      any(),
      expectedModel: any(named: 'expectedModel'),
    ),
  ).thenAnswer((_) => Completer<void>().future);
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith((ref) => _TestBackendNotifier(ref, backend)),
      inMemoryDatabaseOverride(),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<GuiderState> _connecting(ProviderContainer container) async {
  unawaited(
    container
        .read(deviceServiceProvider)
        .connect(DeviceType.guider, _builtinGuiderId),
  );
  for (var i = 0; i < 100; i++) {
    final state = container.read(guiderStateProvider);
    if (state.connectionState == DeviceConnectionState.connecting) {
      return state;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('the guider slot never read Connecting');
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  test('a connect publishes the device name the host reports', () async {
    final state = await _connecting(
      _containerWith(const [
        DeviceInfo(
          id: _builtinGuiderId,
          name: _friendlyName,
          deviceType: DeviceType.guider,
          driverType: DriverType.native,
          description: '',
          driverVersion: '',
        ),
      ]),
    );
    expect(state.deviceName, _friendlyName);
  });
}

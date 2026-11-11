// The host holds Start at dark and runs the end-of-night calibration; a
// linked client shows both as the host has them, from the moment it links.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockRig extends Mock implements EonRig {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// The host's calibration step, put in a phase by the test.
class _HostCalibration extends EndOfNightCalibrationService {
  _HostCalibration() : super(_MockRig(), () async => const EonSettings());

  void show(EonStatus status) => state = status;
}

ProviderContainer _host() {
  final backend = _MockFfiBackend();
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      endOfNightCalibrationProvider.overrideWith((ref) => _HostCalibration()),
    ],
  );
  addTearDown(container.dispose);
  container.read(hostMutationEventHubProvider).wsBroadcast = (_) {};
  container.read(hostRuntimeMirrorProvider);
  return container;
}

({ProviderContainer client, NetworkBackend backend}) _linkedTo(
  ProviderContainer host,
) {
  final backend = _MockNetworkBackend();
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  when(() => backend.getHostRuntimeState()).thenAnswer(
    (_) async => host.read(hostRuntimeStateStoreProvider).snapshot(),
  );
  final client = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  addTearDown(client.dispose);
  return (client: client, backend: backend);
}

void main() {
  test('both channels are in the shared list', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final channels = container.read(runtimeMirrorChannelsProvider);
    expect(
      runtimeChannelFor(channels, 'scheduledStart'),
      isA<ScheduledStartChannel>(),
    );
    expect(runtimeChannelFor(channels, 'endOfNight'), isA<EndOfNightChannel>());
  });

  test('a client that links after Start at dark was armed shows it, and its '
      'cancel', () async {
    final host = _host();
    final dark = DateTime.now().toUtc().add(const Duration(hours: 3));
    host.read(nightArmedStartProvider.notifier).arm(dark, () async {});
    await Future<void>.delayed(Duration.zero);

    final link = _linkedTo(host);
    await hydrateHostRuntimeState(link.client, link.backend);
    expect(link.client.read(hostScheduledStartProvider), dark);
    expect(link.client.read(nightArmedStartProvider), dark);

    host.read(nightArmedStartProvider.notifier).disarm();
    await Future<void>.delayed(Duration.zero);
    await hydrateHostRuntimeState(link.client, link.backend);
    expect(link.client.read(nightArmedStartProvider), isNull);
  });

  test('the host waiting for a cap reaches the client with its deadline, '
      'and is announced once', () async {
    final host = _host();
    final calibration =
        host.read(endOfNightCalibrationProvider.notifier) as _HostCalibration;
    final link = _linkedTo(host);
    await hydrateHostRuntimeState(link.client, link.backend);
    expect(link.client.read(hostEndOfNightStatusProvider)?.phase, EonPhase.idle);

    final deadline = DateTime.utc(2026, 11, 12, 11, 30);
    calibration.show(
      EonStatus(
        phase: EonPhase.waitingForCap,
        message: 'Cap the telescope',
        capDeadline: deadline,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await hydrateHostRuntimeState(link.client, link.backend);

    final shown = link.client.read(hostEndOfNightStatusProvider)!;
    expect(shown.phase, EonPhase.waitingForCap);
    expect(shown.message, 'Cap the telescope');
    expect(shown.capDeadline, deadline.toLocal());
    final warnings = link.client
        .read(uiNotificationProvider)
        .where((n) => n.title == 'Cap the telescope for darks');
    expect(warnings, hasLength(1));
  });

  test('a client that links while the host already waits for a cap shows '
      'the request without a toast', () async {
    final host = _host();
    (host.read(endOfNightCalibrationProvider.notifier) as _HostCalibration)
        .show(const EonStatus(phase: EonPhase.waitingForCap));
    await Future<void>.delayed(Duration.zero);

    final link = _linkedTo(host);
    await hydrateHostRuntimeState(link.client, link.backend);
    expect(
      link.client.read(hostEndOfNightStatusProvider)?.phase,
      EonPhase.waitingForCap,
    );
    expect(link.client.read(uiNotificationProvider), isEmpty);
  });
}

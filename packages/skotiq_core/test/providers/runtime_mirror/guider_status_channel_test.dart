// A client that links while the host is guiding shows it guiding. The host
// reads its guider's status when a guiding event says it changed, never per
// guide step.

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'mirror_link.dart';

const _guiderId = 'native:builtin_guider:multi_star';

SkotiqEvent _guiding(String type) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.info,
  category: EventCategory.guiding,
  eventType: type,
  data: const {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('guide steps cost no status read and no message; a state change '
      'costs one read', () async {
    final host = mirrorHost();
    var status = const Phd2Status(state: 'Stopped', connected: true);
    when(() => host.backend.guiderGetStatus()).thenAnswer((_) async => status);
    final guider = host.container.read(guiderStateProvider.notifier);
    guider.setConnecting(_guiderId, 'Built-in guider');
    guider.setConnected();
    await settle(const Duration(milliseconds: 2600));
    clearInteractions(host.backend);
    host.sent.clear();

    status = const Phd2Status(
      state: 'Guiding',
      connected: true,
      rmsRa: 0.4,
      rmsDec: 0.3,
      rmsTotal: 0.5,
    );
    host.events.add(_guiding('GuidingStarted'));
    for (var step = 0; step < 50; step++) {
      host.events.add(_guiding('GuideStep'));
      host.events.add(_guiding('GuideStats'));
    }
    await settle(const Duration(milliseconds: 100));

    verify(() => host.backend.guiderGetStatus()).called(1);
    // The event says guiding at once; the status read adds the RMS.
    final sent = host.sent.where((u) => u.channel == 'guiderStatus').toList();
    expect(sent.length, inInclusiveRange(1, 2));
    expect(sent.first.value?['state'], 'guiding');
    expect(sent.last.value?['rmsTotal'], 0.5);
  });

  test('a client that links while the host guides shows it guiding, with '
      'the reason a held guider gave', () async {
    final host = mirrorHost();
    when(() => host.backend.guiderGetStatus()).thenAnswer(
      (_) async => const Phd2Status(
        state: 'Guiding',
        connected: true,
        rmsRa: 0.4,
        rmsDec: 0.3,
        rmsTotal: 0.5,
        stopReason: 'autofocus',
      ),
    );
    final guider = host.container.read(guiderStateProvider.notifier);
    guider.setConnecting(_guiderId, 'Built-in guider');
    guider.setConnected();
    await settle(const Duration(milliseconds: 1500));

    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);

    final shown = client.container.read(guiderStateProvider);
    expect(shown.connectionState, DeviceConnectionState.connected);
    expect(shown.deviceId, _guiderId);
    expect(shown.isGuiding, isTrue);
    expect(shown.rmsTotal, 0.5);
    expect(client.container.read(phd2StateProvider), Phd2State.guiding);
    expect(client.container.read(guidingStopReasonProvider), 'autofocus');
  });

  test('a guider whose status still says guiding after it was stopped '
      'shows stopped on the client: its events say so', () async {
    final host = mirrorHost();
    when(() => host.backend.guiderGetStatus()).thenAnswer(
      (_) async => const Phd2Status(state: 'Guiding', connected: true),
    );
    final guider = host.container.read(guiderStateProvider.notifier);
    guider.setConnecting(_guiderId, 'Built-in guider');
    guider.setConnected();
    await settle(const Duration(milliseconds: 1500));
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);
    expect(client.container.read(phd2StateProvider), Phd2State.guiding);

    host.events.add(_guiding('GuidingStopped'));
    await settle(const Duration(milliseconds: 2400));
    await hydrateHostRuntimeState(client.container, client.backend);

    expect(client.container.read(phd2StateProvider), Phd2State.stopped);
    expect(client.container.read(guiderStateProvider).isGuiding, isFalse);
  });

  test('a guider whose status cannot be read stays connected on the '
      'client', () async {
    final host = mirrorHost();
    when(
      () => host.backend.guiderGetStatus(),
    ).thenThrow(StateError('PHD2 not connected'));
    final guider = host.container.read(guiderStateProvider.notifier);
    guider.setConnecting(kPhd2CanonicalId, kPhd2DisplayName);
    guider.setConnected();
    await settle(const Duration(milliseconds: 1500));

    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);

    final shown = client.container.read(guiderStateProvider);
    expect(shown.connectionState, DeviceConnectionState.connected);
    expect(shown.deviceId, kPhd2CanonicalId);
  });

  test('a guider with nothing to report leaves the client as it is', () async {
    final host = mirrorHost();
    final client = mirrorClient(host.container);
    client.container.read(phd2StateProvider.notifier).state = Phd2State.looping;
    await hydrateHostRuntimeState(client.container, client.backend);
    expect(client.container.read(phd2StateProvider), Phd2State.looping);
  });
}

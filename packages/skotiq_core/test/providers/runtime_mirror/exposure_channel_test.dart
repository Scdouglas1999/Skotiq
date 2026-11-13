// The host follows every exposure of its camera and tells its clients, so a
// client shows the exposure in flight from the moment it links and loses it
// when the host does.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import 'mirror_link.dart';

SkotiqEvent _imaging(String type, [Map<String, dynamic> data = const {}]) =>
    SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: EventCategory.imaging,
      eventType: type,
      data: data,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MirrorHost exposingHost() {
    final host = mirrorHost();
    // The service a daemon and a host window both run.
    host.container.listen(hostExposureFollowProvider, (_, _) {});
    return host;
  }

  test('a host with no window shows the frame its run is exposing', () async {
    final host = exposingHost();
    host.events.add(_imaging('ExposureStarted', {'duration_secs': 30.0}));
    await settle();
    expect(host.container.read(cameraStateProvider).isExposing, isTrue);
    expect(host.container.read(exposureProgressProvider).remaining, 30.0);

    host.events.add(_imaging('ExposureComplete'));
    await settle();
    expect(host.container.read(cameraStateProvider).isExposing, isFalse);
  });

  test('a client that links mid-exposure shows it, and its end', () async {
    final host = exposingHost();
    host.events
      ..add(_imaging('ExposureStarted', {'duration_secs': 30.0}))
      ..add(_imaging('ExposureProgress', {'progress': 0.5, 'remainingSecs': 15.0}));
    await settle(const Duration(milliseconds: 600));

    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);
    expect(client.container.read(cameraStateProvider).isExposing, isTrue);
    expect(client.container.read(exposureProgressProvider).remaining, 15.0);

    host.events.add(_imaging('ExposureComplete'));
    await settle(const Duration(milliseconds: 600));
    for (final update in host.sent) {
      applyHostRuntimeUpdate(
        client.container,
        update,
        networkBackend: client.backend,
      );
    }
    expect(client.container.read(cameraStateProvider).isExposing, isFalse);
    expect(
      client.container.read(exposureProgressProvider),
      ExposureProgress.idle(),
    );
  });

  test('the events of a host that tells its exposure are not followed as '
      'well', () async {
    final host = exposingHost();
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);

    applyHostEventOnClient(
      client.container,
      client.backend,
      _imaging('ExposureStarted', {'duration_secs': 30.0}),
    );
    expect(client.container.read(cameraStateProvider).isExposing, isFalse);
  });

  test('a client shows the host\'s exposure from the exposure channel only, '
      'never from the camera\'s own events', () async {
    final client = mirrorClient(
      null,
      snapshot: () => const [
        HostRuntimeUpdate(channel: 'scheduledStart', revision: 1, value: null),
      ],
    );
    await hydrateHostRuntimeState(client.container, client.backend);

    applyHostEventOnClient(
      client.container,
      client.backend,
      _imaging('ExposureStarted', {'duration_secs': 30.0}),
    );
    expect(client.container.read(cameraStateProvider).isExposing, isFalse);
  });
}

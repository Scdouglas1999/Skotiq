// An idle companion polls the imaging host only as often as its screens need:
// guiding events cost it no status read (the host reads its guider once per
// burst and sends the result), the mount position and
// device health are probed at a companion's slower pace, and the narrator feed
// ignores per-tick telemetry.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockHostBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

SkotiqEvent _event(EventCategory category, String type) => SkotiqEvent(
  timestamp: 0,
  severity: EventSeverity.info,
  category: category,
  eventType: type,
  data: const {},
);

const _mountStatus = MountStatus(
  connected: true,
  tracking: true,
  slewing: false,
  parked: false,
  atHome: false,
  sideOfPier: PierSide.east,
  rightAscension: 5,
  declination: 20,
  altitude: 45,
  azimuth: 180,
  siderealTime: 10,
  trackingRate: TrackingRate.sidereal,
  canPark: true,
  canSlew: true,
  canSync: true,
  canPulseGuide: true,
  canSetTrackingRate: true,
);

void main() {
  late _MockNetworkBackend backend;
  late StreamController<SkotiqEvent> events;
  var statusReads = 0;
  var mountReads = 0;

  setUp(() {
    statusReads = 0;
    mountReads = 0;
    events = StreamController<SkotiqEvent>.broadcast();
    backend = _MockNetworkBackend();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.connectionState,
    ).thenReturn(BackendConnectionState.connected);
    when(() => backend.isAuthTokenRejected).thenReturn(false);
    when(() => backend.guiderGetStatus()).thenAnswer((_) async {
      statusReads++;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return kPhd2DisconnectedStatus;
    });
    when(() => backend.getMountStatus(any())).thenAnswer((_) async {
      mountReads++;
      return _mountStatus;
    });
  });

  ProviderContainer containerFor() => ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );

  test('a burst of guiding events costs the host one or two guider status '
      'reads, and a companion none', () {
    fakeAsync((async) {
      final host = _MockHostBackend();
      final hostEvents = StreamController<SkotiqEvent>.broadcast();
      when(() => host.eventStream).thenAnswer((_) => hostEvents.stream);
      when(() => host.guiderGetStatus()).thenAnswer((_) async {
        statusReads++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return kPhd2DisconnectedStatus;
      });
      final hostContainer = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, host),
          ),
        ],
      );
      hostContainer.read(guiderStateProvider.notifier)
        ..setConnecting(kPhd2CanonicalId, kPhd2DisplayName)
        ..setConnected();
      hostContainer.listen(hostGuiderStatusProvider, (_, _) {});
      async.elapse(const Duration(seconds: 10));
      statusReads = 0;

      final companion = containerFor();
      for (var i = 0; i < 20; i++) {
        final event = _event(EventCategory.guiding, 'AppState');
        hostEvents.add(event);
        unawaited(
          applyRemoteSyncEvent(companion, event, networkBackend: backend),
        );
        async.elapse(const Duration(milliseconds: 20));
      }
      async.elapse(const Duration(seconds: 10));
      // One read in flight absorbs the burst; at most one follow-up.
      expect(statusReads, inInclusiveRange(1, 2));
      verifyNever(() => backend.guiderGetStatus());
      hostContainer.dispose();
      companion.dispose();
      unawaited(hostEvents.close());
    });
  });

  test('a companion polls the host mount every 5 seconds when idle', () {
    fakeAsync((async) {
      final container = containerFor();
      container.read(mountStateProvider.notifier)
        ..setConnecting('sim_mount_1', 'Mount')
        ..setConnected();
      async.elapse(const Duration(minutes: 1));
      expect(mountReads, inInclusiveRange(11, 13));
      container.read(mountStateProvider.notifier).setDisconnected();
      container.dispose();
    });
  });

  test('the narrator feed ignores per-tick telemetry', () {
    fakeAsync((async) {
      var feedReads = 0;
      when(() => backend.getRecentNarratorFeed()).thenAnswer((_) async {
        feedReads++;
        return const [];
      });
      final container = containerFor();
      final sub = container.listen(recentNarratorFeedProvider, (_, _) {});
      async.flushMicrotasks();
      for (var i = 0; i < 60; i++) {
        events.add(_event(EventCategory.guiding, 'GuideStep'));
        events.add(_event(EventCategory.imaging, 'ExposureProgress'));
        async.elapse(const Duration(seconds: 1));
      }
      expect(feedReads, 1);
      for (var i = 0; i < 60; i++) {
        events.add(_event(EventCategory.imaging, 'ImageSaved'));
        async.elapse(const Duration(seconds: 1));
      }
      expect(
        feedReads - 1,
        lessThanOrEqualTo(6),
        reason: 'at most one read per 10 s while frames arrive',
      );
      sub.close();
      container.dispose();
    });
  });
}

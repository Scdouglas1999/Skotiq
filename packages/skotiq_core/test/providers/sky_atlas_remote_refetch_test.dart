// A companion's atlas readers must not flood the host: they re-fetch only on
// events that can change the atlas, keep at most one request outstanding,
// coalesce events that arrive meanwhile, respect a minimum interval, and stop
// once nothing watches them.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

SkotiqEvent _event(String type, {Map<String, dynamic> data = const {}}) =>
    SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: EventCategory.system,
      eventType: type,
      data: data,
    );

SkotiqEvent _mutation(String entity) => buildHostMutationEvent(
  entityType: entity,
  action: HostMutationAction.updated,
);

void main() {
  late StreamController<SkotiqEvent> events;
  late _MockNetworkBackend backend;
  late int fetches;
  late List<Completer<List<Map<String, dynamic>>>> open;

  setUp(() {
    events = StreamController<SkotiqEvent>.broadcast();
    backend = _MockNetworkBackend();
    fetches = 0;
    open = [];
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(() => backend.getAtlasRegions()).thenAnswer((_) {
      fetches++;
      final c = Completer<List<Map<String, dynamic>>>();
      open.add(c);
      return c.future;
    });
  });

  ProviderContainer containerFor() => ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );

  void answerAll() {
    for (final c in open) {
      if (!c.isCompleted) c.complete(const []);
    }
  }

  test('telemetry events never trigger a re-fetch', () {
    fakeAsync((async) {
      final container = containerFor();
      final sub = container.listen(skyAtlasRegionsProvider, (_, _) {});
      async.flushMicrotasks();
      answerAll();
      async.flushMicrotasks();
      expect(fetches, 1);

      for (var i = 0; i < 200; i++) {
        events.add(_event('TemperatureChanged'));
        events.add(_event('GuideStep'));
        events.add(_mutation(HostMutationEntity.settings));
        async.elapse(const Duration(seconds: 1));
      }
      expect(fetches, 1);
      sub.close();
      container.dispose();
    });
  });

  test('one request in flight; a burst of atlas events coalesces', () {
    fakeAsync((async) {
      final container = containerFor();
      final sub = container.listen(skyAtlasRegionsProvider, (_, _) {});
      async.flushMicrotasks();
      // First fetch is still outstanding (host busy) while events pour in.
      for (var i = 0; i < 50; i++) {
        events.add(_mutation(HostMutationEntity.atlas));
        async.elapse(const Duration(seconds: 1));
      }
      expect(fetches, 1, reason: 'no second request while one is open');

      answerAll();
      async.flushMicrotasks();
      async.elapse(remoteAtlasRefetchMinInterval);
      expect(fetches, 2, reason: 'the queued events cost exactly one fetch');
      answerAll();
      async.flushMicrotasks();

      // A steady stream of atlas events is bounded by the minimum interval.
      final before = fetches;
      for (var i = 0; i < 60; i++) {
        events.add(_mutation(HostMutationEntity.capturedImage));
        async.elapse(const Duration(seconds: 1));
        answerAll();
        async.flushMicrotasks();
      }
      final perMinute = fetches - before;
      expect(perMinute, lessThanOrEqualTo(5));
      expect(perMinute, greaterThanOrEqualTo(3));
      sub.close();
      container.dispose();
    });
  });

  test('stops polling once nothing listens', () {
    fakeAsync((async) {
      final container = containerFor();
      final sub = container.listen(skyAtlasRegionsProvider, (_, _) {});
      async.flushMicrotasks();
      answerAll();
      async.flushMicrotasks();
      sub.close();
      async.elapse(const Duration(milliseconds: 10));
      expect(events.hasListener, isFalse);

      for (var i = 0; i < 10; i++) {
        events.add(_mutation(HostMutationEntity.atlas));
        async.elapse(const Duration(seconds: 30));
      }
      expect(fetches, 1);
      container.dispose();
    });
  });
}

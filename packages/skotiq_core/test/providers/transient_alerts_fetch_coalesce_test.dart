// activeTransientAlertsProvider fires fetchAlerts() from three triggers
// (immediate subscribe, 15-min poll, and local-detections-change). With no
// in-flight guard a burst spawns concurrent fetches, and out-of-order
// completion overwrites a fresher external alert list. Overlapping triggers
// coalesce into a single in-flight fetch plus at most one queued follow-up,
// newest-wins.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/alerts/transient_alert.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/notification_router_provider.dart';
import 'package:skotiq_core/src/providers/science_provider.dart';
import 'package:skotiq_core/src/providers/transient_alert_provider.dart';
import 'package:skotiq_core/src/providers/transient_detections_provider.dart';
import 'package:skotiq_core/src/services/logging_service.dart';
import 'package:skotiq_core/src/services/notification/secrets_store.dart';
import 'package:skotiq_core/src/services/transient_alert_service.dart';

import '../fakes/fakes.dart';
import '../harness/in_memory_database.dart';

/// Service whose getAllAlerts hands back a controllable completer per call so
/// the test can hold a fetch "in flight" and count how many fetches ran.
class _ControllableService extends TransientAlertService {
  _ControllableService()
    : super(httpClient: FakeNetworkClient(), logger: LoggingService());

  int callCount = 0;
  final List<Completer<List<TransientAlert>>> completers = [];

  @override
  Future<List<TransientAlert>> getAllAlerts(
    TransientAlertSettings settings, {
    int? tnsBotId,
    String? tnsBotName,
    bool tnsUseSandbox = false,
  }) {
    callCount++;
    final completer = Completer<List<TransientAlert>>();
    completers.add(completer);
    return completer.future;
  }
}

class _RecordingService extends TransientAlertService {
  _RecordingService()
    : super(httpClient: FakeNetworkClient(), logger: LoggingService());

  final List<TransientAlertSettings> settingsSeen = [];
  int? botIdSeen;
  String? botNameSeen;

  @override
  Future<List<TransientAlert>> getAllAlerts(
    TransientAlertSettings settings, {
    int? tnsBotId,
    String? tnsBotName,
    bool tnsUseSandbox = false,
  }) {
    settingsSeen.add(settings);
    botIdSeen = tnsBotId;
    botNameSeen = tnsBotName;
    return Future.value(const []);
  }
}

class _TestScienceSettingsNotifier extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async =>
      const ScienceSettings(tnsBotId: 42, tnsBotName: 'skotiq-test');
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

TransientAlert _alert(String id) => TransientAlert(
  id: id,
  name: id,
  type: TransientType.supernova,
  raHours: 1,
  decDegrees: 2,
  discoveryTime: DateTime(2026, 1, 1),
  lastUpdated: DateTime(2026, 1, 1),
  source: TransientSource.tns,
);

Future<void> _pump() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late SkotiqDatabase db;
  late _ControllableService service;
  late StreamController<List<TransientDetectionRow>> detections;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    service = _ControllableService();
    detections = StreamController<List<TransientDetectionRow>>.broadcast();
  });

  tearDown(() async {
    await detections.close();
    await db.close();
  });

  test(
    'out-of-order fetch completion never overwrites the freshest data',
    () async {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          settingsDaoProvider.overrideWithValue(db.settingsDao),
          transientAlertServiceProvider.overrideWithValue(service),
          allTransientDetectionsProvider.overrideWith(
            (ref) => detections.stream,
          ),
        ],
      );
      addTearDown(container.dispose);

      // Subscribe — kicks off the immediate fetch. The provider also rebuilds
      // once when the async settings load resolves, so drain to a quiescent
      // baseline before measuring the burst-coalescing behaviour. Draining
      // completes every in-flight fetch (old rebuilt closures are guarded by
      // `controller.isClosed`) until no fetch is outstanding.
      final sub = container.listen(
        activeTransientAlertsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);
      await _pump();

      Future<void> drain() async {
        while (service.completers.any((c) => !c.isCompleted)) {
          for (final c in service.completers) {
            if (!c.isCompleted) c.complete([_alert('seed')]);
          }
          await _pump();
        }
      }

      await drain();

      // Two external-feed triggers in quick succession, both left in flight.
      detections.add(<TransientDetectionRow>[]);
      await _pump();
      detections.add(<TransientDetectionRow>[]);
      await _pump();

      // The newest in-flight fetch (highest index) is the freshest request.
      // Complete it FIRST with the fresh data.
      final freshIndex = service.completers.length - 1;
      expect(service.completers[freshIndex].isCompleted, isFalse);
      service.completers[freshIndex].complete([_alert('fresh')]);
      await _pump();

      // Now the older, slower fetches resolve LATE with stale data. With the
      // overlap guard in place these out-of-order completions must NOT clobber
      // the fresher result that already landed. (Only older fetches are
      // resolved; any follow-up spawned by the fresh completion is left pending.)
      for (var i = 0; i < freshIndex; i++) {
        if (!service.completers[i].isCompleted) {
          service.completers[i].complete([_alert('stale')]);
        }
      }
      await _pump();

      final value = container.read(activeTransientAlertsProvider).valueOrNull;
      expect(value, isNotNull);
      expect(
        value!.map((a) => a.id),
        equals(['fresh']),
        reason: 'a late stale fetch must not overwrite the freshest result',
      );
    },
  );

  test('injects the keyring TNS key into local alert fetches', () async {
    await db.settingsDao.setSetting(
      'transient_alert_enabled_sources',
      '["tns"]',
    );
    final secureStore = SecretsStore(InMemorySecureKeyValueStore());
    await secureStore.write(SecretField.tnsApiKey, 'secret-tns-key');
    final recordingService = _RecordingService();
    addTearDown(recordingService.dispose);
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        settingsDaoProvider.overrideWithValue(db.settingsDao),
        secretsStoreProvider.overrideWithValue(secureStore),
        scienceSettingsProvider.overrideWith(
          () => _TestScienceSettingsNotifier(),
        ),
        transientAlertServiceProvider.overrideWithValue(recordingService),
        allTransientDetectionsProvider.overrideWith(
          (ref) => Stream.value(const <TransientDetectionRow>[]),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(
      activeTransientAlertsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(sub.close);

    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
      if (recordingService.settingsSeen.any(
        (settings) => settings.tnsApiKey == 'secret-tns-key',
      )) {
        break;
      }
    }

    expect(
      recordingService.settingsSeen,
      contains(
        isA<TransientAlertSettings>().having(
          (settings) => settings.tnsApiKey,
          'tnsApiKey',
          'secret-tns-key',
        ),
      ),
    );
    expect(recordingService.botIdSeen, 42);
    expect(recordingService.botNameSeen, 'skotiq-test');
  });

  test(
    'remote feed rejects malformed rows instead of presenting partial data',
    () async {
      final backend = _MockNetworkBackend();
      final now = DateTime(2026, 1, 1).millisecondsSinceEpoch;
      when(() => backend.getTransientSettings()).thenAnswer((_) async => {});
      when(() => backend.getActiveTransients()).thenAnswer(
        (_) async => {
          'alerts': [
            {
              'id': 'valid',
              'name': 'AT 2026abc',
              'type': 'supernova',
              'raHours': 12.5,
              'decDegrees': -20.0,
              'discoveryTime': now,
              'lastUpdated': now,
              'source': 'tns',
              'priority': 7,
            },
            {'id': 'broken', 'name': 'Missing coordinates'},
            {
              'id': 'valid',
              'name': 'Duplicate copy',
              'type': 'other',
              'raHours': 1.0,
              'decDegrees': 1.0,
              'discoveryTime': now,
              'lastUpdated': now,
              'source': 'tns',
            },
            {
              'id': 'bad-source',
              'name': 'Unknown provenance',
              'type': 'other',
              'raHours': 1.0,
              'decDegrees': 1.0,
              'discoveryTime': now,
              'lastUpdated': now,
              'source': 'invented',
            },
          ],
        },
      );
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          settingsDaoProvider.overrideWithValue(db.settingsDao),
          allTransientDetectionsProvider.overrideWith(
            (ref) => Stream.value(const <TransientDetectionRow>[]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(transientAlertSettingsProvider.notifier).loaded;
      final subscription = container.listen(
        activeTransientAlertsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await expectLater(
        container.read(activeTransientAlertsProvider.future),
        throwsA(isA<FormatException>()),
      );
    },
  );
}

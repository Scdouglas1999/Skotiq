import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _ControllableSettingsDao extends SettingsDao {
  _ControllableSettingsDao(super.db);

  bool failBatchWrites = false;
  bool failSingleWrites = false;

  @override
  Future<void> setSettings(Map<String, String> settings) async {
    if (failBatchWrites) throw StateError('batch write failed');
    await super.setSettings(settings);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (failSingleWrites) throw StateError('single write failed');
    await super.setSetting(key, value);
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late _ControllableSettingsDao dao;
  late LoggingService logger;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = _ControllableSettingsDao(database);
    logger = LoggingService();
  });

  tearDown(() async {
    await logger.dispose();
    await database.close();
  });

  test(
    'failed settings persistence restores the last confirmed values',
    () async {
      final notifier = TransientAlertSettingsNotifier(
        settingsDao: dao,
        logger: logger,
      );
      addTearDown(notifier.dispose);
      await _pump();
      final confirmed = notifier.state.copyWith(notifyOnNew: false);
      await notifier.updateSettings(confirmed);
      dao.failBatchWrites = true;

      await expectLater(notifier.setAutoQueueBright(true), throwsStateError);

      expect(notifier.state, confirmed);
    },
  );

  test(
    'rapid independent settings edits merge into the persisted snapshot',
    () async {
      final notifier = TransientAlertSettingsNotifier(
        settingsDao: dao,
        logger: logger,
      );
      addTearDown(notifier.dispose);
      await _pump();

      // TNS is on by default, so the toggle under test turns it OFF; what is
      // being asserted is that three concurrent independent edits all land in
      // one persisted snapshot, not the direction of any one of them.
      await Future.wait([
        notifier.toggleSource(TransientSource.tns),
        notifier.toggleType(TransientType.nova),
        notifier.setNotifyOnNew(false),
      ]);

      expect(
        notifier.state.enabledSources,
        isNot(contains(TransientSource.tns)),
      );
      expect(
        notifier.state.typesToMonitor,
        isNot(contains(TransientType.nova)),
      );
      expect(notifier.state.notifyOnNew, isFalse);
      final stored = await dao.getAllSettings();
      expect(stored['transient_alert_enabled_sources'], isNot(contains('tns')));
      expect(
        jsonDecode(stored['transient_alert_types_to_monitor']!)
            as List<dynamic>,
        isNot(contains('nova')),
      );
      expect(stored['transient_alert_notify_on_new'], 'false');
    },
  );

  test(
    'first settings edit preserves unrelated persisted preferences',
    () async {
      await dao.setSettings({
        'transient_alert_enabled_sources': '["aavso","tns"]',
        'transient_alert_types_to_monitor': '["supernova"]',
        'transient_alert_magnitude_threshold': '11.5',
        'transient_alert_notify_on_new': 'true',
        'transient_alert_auto_queue_bright': 'false',
        'transient_alert_auto_queue_magnitude': '8.0',
      });
      final notifier = TransientAlertSettingsNotifier(
        settingsDao: dao,
        logger: logger,
      );
      addTearDown(notifier.dispose);

      // Deliberately mutate immediately, before the asynchronous load gets an
      // opportunity to complete.
      await notifier.setNotifyOnNew(false);

      expect(notifier.state.notifyOnNew, isFalse);
      expect(notifier.state.enabledSources, {
        TransientSource.aavso,
        TransientSource.tns,
      });
      expect(notifier.state.typesToMonitor, {TransientType.supernova});
      expect(notifier.state.magnitudeThreshold, 11.5);
    },
  );

  test('failed alert-state persistence leaves the alert unchanged', () async {
    final notifier = TransientAlertStatesNotifier(
      settingsDao: dao,
      logger: logger,
    );
    addTearDown(notifier.dispose);
    await _pump();
    dao.failSingleWrites = true;

    await expectLater(notifier.dismiss('alert-1'), throwsStateError);

    expect(notifier.getState('alert-1'), isNull);
  });

  test(
    'alert-state changes serialize without dropping distinct alerts',
    () async {
      final notifier = TransientAlertStatesNotifier(
        settingsDao: dao,
        logger: logger,
      );
      addTearDown(notifier.dispose);
      await _pump();

      await Future.wait([
        notifier.acknowledge('alert-1'),
        notifier.dismiss('alert-2'),
      ]);

      expect(notifier.getState('alert-1'), TransientAlertState.acknowledged);
      expect(notifier.getState('alert-2'), TransientAlertState.dismissed);
    },
  );

  test('first alert action preserves other persisted alert states', () async {
    await dao.setSetting(
      'transient_alert_state_existing',
      TransientAlertState.dismissed.name,
    );
    final notifier = TransientAlertStatesNotifier(
      settingsDao: dao,
      logger: logger,
    );
    addTearDown(notifier.dispose);

    // Deliberately act before the asynchronous hydration finishes.
    await notifier.acknowledge('new-alert');

    expect(notifier.getState('existing'), TransientAlertState.dismissed);
    expect(notifier.getState('new-alert'), TransientAlertState.acknowledged);
  });

  test(
    'remote settings hydrate from and persist to the imaging host',
    () async {
      final backend = _MockNetworkBackend();
      when(backend.getTransientSettings).thenAnswer(
        (_) async => {
          'enabledSources': ['tns', 'unknown-source'],
          'typesToMonitor': ['supernova', 'unknown-type'],
          'magnitudeThreshold': 13.5,
          'notifyOnNew': false,
          'autoQueueBright': true,
          'autoQueueMagnitude': 9.5,
        },
      );
      when(
        () => backend.updateTransientSettings(any()),
      ).thenAnswer((_) async {});
      final notifier = TransientAlertSettingsNotifier(
        settingsDao: dao,
        logger: logger,
        remote: backend,
      );
      addTearDown(notifier.dispose);

      await notifier.loaded;
      expect(notifier.state.enabledSources, {TransientSource.tns});
      expect(notifier.state.typesToMonitor, {TransientType.supernova});
      expect(notifier.state.magnitudeThreshold, 13.5);
      expect(notifier.state.notifyOnNew, isFalse);

      await notifier.setNotifyOnNew(true);

      final saved =
          verify(
                () => backend.updateTransientSettings(captureAny()),
              ).captured.single
              as Map<String, dynamic>;
      expect(saved['notifyOnNew'], isTrue);
      expect(saved['enabledSources'], ['tns']);
      expect(
        (await dao.getAllSettings()).keys.where(
          (key) => key.startsWith('transient_alert_'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'remote alert states hydrate from and persist to the imaging host',
    () async {
      final backend = _MockNetworkBackend();
      when(() => backend.getTransientStates()).thenAnswer(
        (_) async => {'existing': 'observed', 'unknown-state': 'invented'},
      );
      when(
        () => backend.updateTransientState(any(), any()),
      ).thenAnswer((_) async {});
      final notifier = TransientAlertStatesNotifier(
        settingsDao: dao,
        logger: logger,
        remote: backend,
      );
      addTearDown(notifier.dispose);

      await notifier.loaded;
      expect(notifier.getState('existing'), TransientAlertState.observed);
      expect(notifier.getState('unknown-state'), isNull);

      await notifier.dismiss('remote-alert');

      verify(
        () => backend.updateTransientState('remote-alert', 'dismissed'),
      ).called(1);
      expect(notifier.getState('remote-alert'), TransientAlertState.dismissed);
      expect(
        (await dao.getAllSettings()).keys.where(
          (key) => key.startsWith('transient_alert_state_'),
        ),
        isEmpty,
      );
    },
  );
}

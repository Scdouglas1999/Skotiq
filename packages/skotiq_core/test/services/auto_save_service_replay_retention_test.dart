import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';
import 'package:skotiq_core/src/services/auto_save_service.dart';
import 'package:skotiq_core/src/services/backup_service.dart';
import 'package:skotiq_core/src/services/replay_debug_service.dart';
import 'package:skotiq_core/src/services/sequence_repository.dart';

class _MockSequenceRepository extends Mock implements SequenceRepository {}

class _MockBackupService extends Mock implements BackupService {}

class _MockReplayDebugService extends Mock implements ReplayDebugService {}

class _MockSettingsDao extends Mock implements SettingsDao {}

Sequence _sequence(String name) => Sequence(
  id: 'seq',
  name: name,
  nodes: const {},
  createdAt: DateTime.utc(2026),
  modifiedAt: DateTime.utc(2026),
);

void main() {
  setUpAll(() {
    registerFallbackValue(DateTime.utc(2026));
    registerFallbackValue(
      Sequence(
        id: 'seq',
        name: 'Test sequence',
        nodes: const {},
        createdAt: DateTime.utc(2026),
        modifiedAt: DateTime.utc(2026),
      ),
    );
  });

  group('AutoSaveService replay retention', () {
    test(
      'prunes replay decisions once on startup using retention days',
      () async {
        final replayDebugService = _MockReplayDebugService();
        when(
          () => replayDebugService.pruneOlderThan(any()),
        ).thenAnswer((_) async => 3);

        final service = AutoSaveService(
          sequenceRepository: _MockSequenceRepository(),
          backupService: _MockBackupService(),
          replayDebugService: replayDebugService,
          replayRetentionDays: () async => 90,
          clock: () => DateTime.utc(2026, 5, 21, 12),
        );

        service.start(
          const AutoSaveConfig(sequenceEnabled: false, backupEnabled: false),
        );
        await Future<void>.delayed(Duration.zero);

        verify(
          () =>
              replayDebugService.pruneOlderThan(DateTime.utc(2026, 2, 20, 12)),
        ).called(1);

        await service.stop();
        service.dispose();
      },
    );
  });

  group('AutoSaveService backup lifecycle', () {
    test('status stream immediately reports current restored status', () async {
      final service = AutoSaveService(
        sequenceRepository: _MockSequenceRepository(),
        backupService: _MockBackupService(),
      );
      final restored = DateTime.utc(2026, 7, 12, 3);

      service.start(
        const AutoSaveConfig(sequenceEnabled: false, backupEnabled: false),
        restored,
      );

      expect((await service.statusStream.first).lastBackup, restored);
      await service.stop();
      service.dispose();
    });

    test('overlapping manual backups share one database export', () async {
      final backup = _MockBackupService();
      final completion = Completer<BackupResult>();
      when(backup.autoSaveBackup).thenAnswer((_) => completion.future);
      when(backup.listBackups).thenAnswer((_) async => <File>[]);
      final service = AutoSaveService(
        sequenceRepository: _MockSequenceRepository(),
        backupService: backup,
      );

      final first = service.backupNow();
      final second = service.backupNow();
      completion.complete(
        BackupResult(
          success: true,
          filePath: '/tmp/autosave.nsbackup',
          timestamp: DateTime.utc(2026, 7, 12),
        ),
      );

      expect((await first).success, isTrue);
      expect((await second).success, isTrue);
      verify(backup.autoSaveBackup).called(1);
      service.dispose();
    });

    test('configuration is persisted before it becomes active', () async {
      AutoSaveConfig? persisted;
      final service = AutoSaveService(
        sequenceRepository: _MockSequenceRepository(),
        backupService: _MockBackupService(),
        persistConfig: (config) async => persisted = config,
      );
      const config = AutoSaveConfig(
        sequenceEnabled: false,
        backupEnabled: false,
        backupInterval: Duration(hours: 6),
        maxBackups: 12,
      );

      await service.updateConfig(config);

      expect(persisted, same(config));
      expect(service.config.backupInterval, const Duration(hours: 6));
      expect(service.config.maxBackups, 12);
      service.dispose();
    });
  });

  group('AutoSaveService sequence lifecycle', () {
    test(
      'saveNow drains a newer edit queued while an older save is in flight',
      () async {
        final repository = _MockSequenceRepository();
        final first = _sequence('first');
        final newer = _sequence('newer');
        final firstSave = Completer<int>();
        when(() => repository.saveSequence(any())).thenAnswer((invocation) {
          final sequence = invocation.positionalArguments.single as Sequence;
          return identical(sequence, first)
              ? firstSave.future
              : Future<int>.value(22);
        });
        final saved = <Sequence>[];
        final service = AutoSaveService(
          sequenceRepository: repository,
          backupService: _MockBackupService(),
          onSequenceSaved: (sequence, _) => saved.add(sequence),
        );

        service.markSequenceChanged(first);
        final active = service.saveNow();
        await untilCalled(() => repository.saveSequence(first));
        service.markSequenceChanged(newer);
        firstSave.complete(21);
        await active;

        expect(service.hasUnsavedChanges, isFalse);
        expect(saved, hasLength(1));
        expect(saved.single, same(newer));
        verify(() => repository.saveSequence(any())).called(2);
        service.dispose();
      },
    );

    test('overlapping saveNow calls share one repository save', () async {
      final repository = _MockSequenceRepository();
      final completion = Completer<int>();
      when(
        () => repository.saveSequence(any()),
      ).thenAnswer((_) => completion.future);
      final service = AutoSaveService(
        sequenceRepository: repository,
        backupService: _MockBackupService(),
      );
      service.markSequenceChanged(_sequence('pending'));

      final first = service.saveNow();
      final second = service.saveNow();
      completion.complete(1);
      await Future.wait([first, second]);

      verify(() => repository.saveSequence(any())).called(1);
      service.dispose();
    });

    test('stop drains an edit queued behind an active timer save', () async {
      final repository = _MockSequenceRepository();
      final first = _sequence('first');
      final newer = _sequence('newer');
      final firstSave = Completer<int>();
      when(() => repository.saveSequence(any())).thenAnswer((invocation) {
        final sequence = invocation.positionalArguments.single as Sequence;
        return identical(sequence, first)
            ? firstSave.future
            : Future<int>.value(22);
      });
      final service = AutoSaveService(
        sequenceRepository: repository,
        backupService: _MockBackupService(),
      );
      service.start(
        const AutoSaveConfig(
          sequenceInterval: Duration(milliseconds: 1),
          sequenceEnabled: true,
          backupEnabled: false,
        ),
      );

      service.markSequenceChanged(first);
      await untilCalled(() => repository.saveSequence(first));
      service.markSequenceChanged(newer);
      final stopping = service.stop();
      firstSave.complete(21);
      await stopping;

      expect(service.hasUnsavedChanges, isFalse);
      verify(() => repository.saveSequence(any())).called(2);
      service.dispose();
    });

    test('dispose does not launch a database write during graph teardown', () {
      final repository = _MockSequenceRepository();
      final service = AutoSaveService(
        sequenceRepository: repository,
        backupService: _MockBackupService(),
      );
      service.markSequenceChanged(_sequence('pending'));

      service.dispose();

      verifyNever(() => repository.saveSequence(any()));
    });

    test('an in-flight save may finish safely after dispose', () async {
      final repository = _MockSequenceRepository();
      final completion = Completer<int>();
      when(
        () => repository.saveSequence(any()),
      ).thenAnswer((_) => completion.future);
      final service = AutoSaveService(
        sequenceRepository: repository,
        backupService: _MockBackupService(),
      );
      service.markSequenceChanged(_sequence('pending'));

      final saving = service.saveNow();
      await untilCalled(() => repository.saveSequence(any()));
      service.dispose();
      completion.complete(1);

      await expectLater(saving, completes);
    });

    test('lifecycle queues real editor mutations when enabled', () async {
      final repository = _MockSequenceRepository();
      when(() => repository.saveSequence(any())).thenAnswer((_) async => 1);
      final settingsDao = _MockSettingsDao();
      when(settingsDao.getAllSettings).thenAnswer(
        (_) async => <String, String>{
          'autosave.sequence_enabled': 'true',
          'autosave.sequence_interval_minutes': '2',
          'autosave.backup_enabled': 'false',
        },
      );
      when(() => settingsDao.getSetting(any())).thenAnswer((_) async => null);
      final service = AutoSaveService(
        sequenceRepository: repository,
        backupService: _MockBackupService(),
      );
      final container = ProviderContainer(
        overrides: [
          autoSaveServiceProvider.overrideWithValue(service),
          settingsDaoProvider.overrideWithValue(settingsDao),
        ],
      );
      addTearDown(container.dispose);
      await container.read(autoSaveLifecycleProvider.future);

      final editor = container.read(currentSequenceProvider.notifier);
      editor.createSequence();
      editor.setName('Changed locally');
      await Future<void>.delayed(Duration.zero);

      expect(service.hasUnsavedChanges, isTrue);
      await service.stop();
      service.dispose();
    });
  });
}

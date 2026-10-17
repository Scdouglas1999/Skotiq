/// The hydrated "last backup" timestamp reaches listeners.
///
/// `statusStream` seeds late subscribers with the current status, but a listener
/// that attaches BEFORE the lifecycle provider finishes hydrating — which is
/// what happens when the settings Backup screen is built during boot — gets the
/// pre-hydration status and never hears about the hydrated one if `start()`
/// mutates `_status` without emitting. The Backup & Restore screen then shows
/// "Last Full Backup: Never" on a machine whose `autosave.last_backup_at` was
/// persisted hours earlier and which has backup files sitting on disk.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/services/auto_save_service.dart';
import 'package:skotiq_core/src/services/backup_service.dart';
import 'package:skotiq_core/src/services/sequence_repository.dart';

class _MockSequenceRepository extends Mock implements SequenceRepository {}

class _MockBackupService extends Mock implements BackupService {}

AutoSaveService _service() => AutoSaveService(
  sequenceRepository: _MockSequenceRepository(),
  backupService: _MockBackupService(),
);

const _idleConfig = AutoSaveConfig(
  sequenceEnabled: false,
  backupEnabled: false,
);

void main() {
  group('AutoSaveService status hydration', () {
    test(
      'a listener attached BEFORE start() receives the hydrated lastBackup',
      () async {
        final service = _service();
        addTearDown(service.dispose);

        final seen = <AutoSaveStatus>[];
        final sub = service.statusStream.listen(seen.add);
        addTearDown(sub.cancel);
        // Let the seeded (pre-hydration) status arrive first, exactly like the
        // settings screen subscribing during boot.
        await pumpEventQueue();
        expect(seen.single.lastBackup, isNull);

        final hydrated = DateTime(2026, 7, 24, 22, 42);
        service.start(_idleConfig, hydrated);
        await pumpEventQueue();

        expect(
          seen.last.lastBackup,
          hydrated,
          reason:
              'start() must publish the hydrated timestamp, not just store '
              'it, or an already-attached listener shows "Never" forever',
        );
      },
    );

    test('a listener attached AFTER start() is seeded with it too', () async {
      final service = _service();
      addTearDown(service.dispose);

      final hydrated = DateTime(2026, 7, 24, 22, 42);
      service.start(_idleConfig, hydrated);

      final first = await service.statusStream.first;
      expect(first.lastBackup, hydrated);
    });

    test('no hydrated timestamp leaves lastBackup null', () async {
      final service = _service();
      addTearDown(service.dispose);

      service.start(_idleConfig);

      final first = await service.statusStream.first;
      expect(first.lastBackup, isNull);
    });
  });
}

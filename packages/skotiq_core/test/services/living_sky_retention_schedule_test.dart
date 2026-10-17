// The Sky Atlas cutout/delta cache and the pulled swarm blobs are the two
// derived-artifact stores that grow without bound on a host that runs for
// months. `SkyAtlasService.sweepCache` and
// `ConstellationService.sweepSwarmBlobs` reclaim them, and both doc comments
// assert a maintenance schedule — these tests pin that the schedule exists.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/providers/app_version_provider.dart';
import 'package:skotiq_core/src/services/auto_save_service.dart';
import 'package:skotiq_core/src/services/backup_service.dart';
import 'package:skotiq_core/src/services/sequence_repository.dart';

import '../harness/in_memory_database.dart';

class _MockSequenceRepository extends Mock implements SequenceRepository {}

class _MockBackupService extends Mock implements BackupService {}

void main() {
  const idleConfig = AutoSaveConfig(
    sequenceEnabled: false,
    backupEnabled: false,
  );

  AutoSaveService serviceWith(Future<void> Function()? sweep) =>
      AutoSaveService(
        sequenceRepository: _MockSequenceRepository(),
        backupService: _MockBackupService(),
        livingSkyRetentionSweep: sweep,
      );

  test('the retention sweep runs once on host start', () async {
    var sweeps = 0;
    final service = serviceWith(() async => sweeps++);
    addTearDown(service.dispose);

    expect(sweeps, 0, reason: 'nothing runs before start()');
    service.start(idleConfig);
    await Future<void>.delayed(Duration.zero);

    expect(sweeps, 1);
    await service.stop();
  });

  test(
    'a failing sweep is logged, not fatal to the maintenance cycle',
    () async {
      final service = serviceWith(() async => throw StateError('disk gone'));
      addTearDown(service.dispose);

      service.start(idleConfig);
      await Future<void>.delayed(Duration.zero);

      expect(service.status.lastError, isNull);
      await service.stop();
    },
  );

  test('stopping the host cancels the daily sweep timer', () async {
    var sweeps = 0;
    final service = serviceWith(() async => sweeps++);
    addTearDown(service.dispose);

    service.start(idleConfig);
    await Future<void>.delayed(Duration.zero);
    await service.stop();
    await Future<void>.delayed(Duration.zero);

    expect(sweeps, 1, reason: 'the start-up sweep only; no timer left running');
  });

  test(
    'the production wiring supplies the sweep — without it both reclaimers are '
    'unreachable code and the disk grows without bound',
    () {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '6.1.0', buildNumber: 1),
          ),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(autoSaveServiceProvider);
      addTearDown(service.dispose);

      expect(service.livingSkyRetentionSweep, isNotNull);
    },
  );
}

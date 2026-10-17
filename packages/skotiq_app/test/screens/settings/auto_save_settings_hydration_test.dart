// Settings > Files & Storage > Auto-Save & Backups must render what is on
// disk.
//
// The page used to watch the raw `autoSaveServiceProvider`, which hands back
// whichever service instance the last backend swap built — un-started, so its
// config is the compiled-in defaults and its status says the machine has never
// been backed up. Two visible lies followed:
//
//   * "Last backup / Never" on a host whose `autosave.last_backup_at` was
//     written minutes earlier, while Settings > Backup & Restore (which reads
//     the persisted key) showed the real timestamp in the same session, and
//   * the saved schedule replaced by defaults — and, because
//     `_persistAutoSaveConfig` rewrites all five `autosave.*` keys from the
//     object the page edited, one change to the backup interval wrote those
//     defaults back over the operator's settings, silently turning sequence
//     auto-save off.
//
// These tests pin the page to `autoSaveLifecycleProvider`, the only provider
// that loads the persisted keys and calls `start(config, lastBackup)`.
//
// The card is fed by TWO independent truthful sources — the hydrated service
// and the `autoSaveStatusProvider` backfill from `autosave.last_backup_at`.
// That redundancy is deliberate, but it means a test that only checks the
// rendered text keeps passing when EITHER source is deleted, so a refactor
// could quietly remove one and leave the card one edit from lying again. The
// two "with only the ... path" cases below therefore disable one source each
// and assert the other still tells the truth on its own.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/auto_save_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _MockSequenceRepository extends Mock implements SequenceRepository {}

class _MockBackupService extends Mock implements BackupService {}

/// Build a service wired like `autoSaveServiceProvider` does for the seam this
/// page depends on: [persistConfig] stands in for `_persistAutoSaveConfig`,
/// which rewrites every `autosave.*` key from the config it is handed — so
/// whatever lands in [captured] is what the database ends up holding.
AutoSaveService _serviceCapturing(List<AutoSaveConfig> captured) {
  return AutoSaveService(
    sequenceRepository: _MockSequenceRepository(),
    backupService: _MockBackupService(),
    persistConfig: (config) async => captured.add(config),
  );
}

Future<void> _seedPersistedAutoSave(
  SkotiqDatabase database, {
  required DateTime lastBackup,
}) async {
  await SettingsDao(database).setSettings(<String, String>{
    'autosave.sequence_enabled': 'true',
    'autosave.sequence_interval_minutes': '9',
    'autosave.backup_enabled': 'false',
    'autosave.backup_interval_hours': '24',
    'autosave.max_backups': '50',
    BackupService.lastBackupSettingKey: lastBackup.toUtc().toIso8601String(),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Status shows the persisted last backup, not "Never"',
      (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);
    final lastBackup = DateTime.now().subtract(const Duration(hours: 2));
    await _seedPersistedAutoSave(database, lastBackup: lastBackup);

    final service = _serviceCapturing(<AutoSaveConfig>[]);

    await pumpAppScreen(
      tester,
      const AutoSaveSettings(),
      database: database,
      extraOverrides: [autoSaveServiceProvider.overrideWithValue(service)],
    );

    expect(find.text('2h ago'), findsOneWidget);
    expect(find.text('Never'), findsNothing);
    // The trailing "next backup" hint is derived from the same timestamp, so a
    // truthful card also stops saying the first backup is still pending.
    expect(find.text('Pending'), findsNothing);
    // 24h interval minus the ~2h since the backup, floored to whole hours.
    expect(find.textContaining(RegExp(r'^In 2[12]h$')), findsOneWidget);

    // Cancel the schedule's periodic timers inside the body: flutter_test's
    // pending-timer invariant runs before tearDown callbacks.
    service.dispose();
  });

  testWidgets('truthful with only the lifecycle-hydration path',
      (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);
    await _seedPersistedAutoSave(
      database,
      lastBackup: DateTime.now().subtract(const Duration(hours: 2)),
    );

    final service = _serviceCapturing(<AutoSaveConfig>[]);
    // Silence the persisted-key backfill: a stream that never emits leaves
    // `autoSaveStatusProvider` in AsyncLoading, so `valueOrNull` is null and
    // the card can only be truthful if it renders the service the LIFECYCLE
    // provider hydrated. Watching the raw `autoSaveServiceProvider` — the
    // instance the last backend swap built, never started — puts "Never" back.
    //
    // Backed by an uncompleted Future rather than a StreamController: a
    // single-subscription controller's `close()` never completes while nothing
    // has listened, and severing the page's `ref.watch` is exactly what stops
    // anything from listening — so a controller here would hang the whole file
    // in tearDown instead of failing this one case.
    final silent = Completer<AutoSaveStatus>().future.asStream();

    await pumpAppScreen(
      tester,
      const AutoSaveSettings(),
      database: database,
      extraOverrides: [
        autoSaveServiceProvider.overrideWithValue(service),
        autoSaveStatusProvider.overrideWith((ref) => silent),
      ],
    );

    expect(find.text('2h ago'), findsOneWidget);
    expect(find.text('Never'), findsNothing);

    service.dispose();
  });

  testWidgets('truthful with only the persisted-key backfill', (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);
    await _seedPersistedAutoSave(
      database,
      lastBackup: DateTime.now().subtract(const Duration(hours: 2)),
    );

    // An un-started service is exactly what a backend swap leaves behind:
    // `autoSaveServiceProvider` watches `backendProvider`, so the placeholder →
    // FFI swap rebuilds it, and the page can be handed an instance whose
    // `_status.lastBackup` is null. Overriding the lifecycle provider with that
    // instance removes the hydration path, leaving only the
    // `autoSaveStatusProvider` backfill from `autosave.last_backup_at` — the
    // same key Settings > Advanced > Backup & Restore reads, which is why the
    // two surfaces contradicted each other in the first place.
    final orphan = _serviceCapturing(<AutoSaveConfig>[]);
    addTearDown(orphan.dispose);
    expect(orphan.status.lastBackup, isNull);

    await pumpAppScreen(
      tester,
      const AutoSaveSettings(),
      database: database,
      extraOverrides: [
        autoSaveServiceProvider.overrideWithValue(orphan),
        autoSaveLifecycleProvider.overrideWith((ref) async => orphan),
      ],
    );

    expect(find.text('2h ago'), findsOneWidget);
    expect(find.text('Never'), findsNothing);
  });

  testWidgets('renders the persisted schedule rather than compiled-in defaults',
      (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);
    await _seedPersistedAutoSave(
      database,
      lastBackup: DateTime.now().subtract(const Duration(hours: 2)),
    );

    final service = _serviceCapturing(<AutoSaveConfig>[]);

    await pumpAppScreen(
      tester,
      const AutoSaveSettings(),
      database: database,
      extraOverrides: [autoSaveServiceProvider.overrideWithValue(service)],
    );

    final sequenceSwitch =
        tester.widget<SkotiqSwitch>(find.byType(SkotiqSwitch).first);
    expect(sequenceSwitch.value, isTrue,
        reason: 'autosave.sequence_enabled=true was persisted');
    // Defaults are a 2 min sequence interval and 7 retained backups — neither
    // may appear once the persisted 9 / 50 are hydrated.
    expect(find.text('9'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(find.text('7'), findsNothing);
    expect(find.text('2'), findsNothing);

    service.dispose();
  });

  testWidgets('editing one field does not overwrite the other saved settings',
      (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);
    await _seedPersistedAutoSave(
      database,
      lastBackup: DateTime.now().subtract(const Duration(hours: 2)),
    );

    final captured = <AutoSaveConfig>[];
    final service = _serviceCapturing(captured);

    await pumpAppScreen(
      tester,
      const AutoSaveSettings(),
      database: database,
      extraOverrides: [autoSaveServiceProvider.overrideWithValue(service)],
    );

    // Change ONLY the backup interval, the way the operator did.
    await tester.enterText(find.text('24'), '12');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(captured, isNotEmpty,
        reason: 'the edit must reach the persistence seam');
    final written = captured.last;
    expect(written.backupInterval, const Duration(hours: 12));
    expect(written.sequenceEnabled, isTrue,
        reason: 'editing the interval must not turn sequence auto-save off');
    expect(written.maxBackups, 50,
        reason: 'editing the interval must not reset the retention count');
    expect(written.sequenceInterval, const Duration(minutes: 9));

    service.dispose();
  });
}

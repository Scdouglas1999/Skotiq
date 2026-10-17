// Settings > Files & Storage > Automatic Backups belongs to the machine whose
// database is being backed up.
//
// `apps/desktop/lib/main.dart` starts `autoSaveLifecycleProvider` only when
// `remoteTarget == null` — the client ROLE — because backup files and the
// database belong to the host. The page's refusal was gated on
// `isRemoteModeProvider` instead, which answers the narrower question "is a
// connection open right now". The two disagree for the whole window before a
// client's first handshake and again after every drop, and in that window the
// page rendered the full editor: it wrote `autosave.*` into the client's own
// database, and watching the lifecycle provider from `build` started, from the
// settings screen, the very service the entry point had declined to start for
// this role.

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/auto_save_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _MockSequenceRepository extends Mock implements SequenceRepository {}

class _MockBackupService extends Mock implements BackupService {}

AutoSaveService _service() {
  return AutoSaveService(
    sequenceRepository: _MockSequenceRepository(),
    backupService: _MockBackupService(),
    persistConfig: (config) async {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AutoSaveService> pumpAs(
    WidgetTester tester, {
    required bool launchedAsClient,
    required bool connected,
    required SkotiqDatabase database,
  }) async {
    final service = _service();
    await pumpAppScreen(
      tester,
      const AutoSaveSettings(),
      database: database,
      extraOverrides: [
        autoSaveServiceProvider.overrideWithValue(service),
        remoteClientLaunchProvider.overrideWithValue(launchedAsClient),
        isRemoteModeProvider.overrideWithValue(connected),
      ],
    );
    return service;
  }

  testWidgets('a connected client is told where the schedule lives',
      (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);

    final service = await pumpAs(
      tester,
      launchedAsClient: false,
      connected: true,
      database: database,
    );

    expect(find.text('Configure on the host'), findsOneWidget);
    expect(find.text('Enable automatic backups'), findsNothing);
    service.dispose();
  });

  testWidgets(
      'a client that has not reached its rig yet is still that rig\'s client',
      (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);

    final service = await pumpAs(
      tester,
      launchedAsClient: true,
      connected: false,
      database: database,
    );

    expect(find.text('Configure on the host'), findsOneWidget);
    expect(
      find.text('Enable automatic backups'),
      findsNothing,
      reason: 'this process never starts the backup service at all',
    );
    expect(
      await SettingsDao(database).getSetting('autosave.backup_enabled'),
      isNull,
      reason: 'rendering the page must not seed the client\'s own schedule',
    );
    service.dispose();
  });

  testWidgets('a host launch keeps its own schedule editor', (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);

    final service = await pumpAs(
      tester,
      launchedAsClient: false,
      connected: false,
      database: database,
    );

    expect(find.text('Configure on the host'), findsNothing);
    expect(find.text('Enable automatic backups'), findsOneWidget);
    service.dispose();
  });
}

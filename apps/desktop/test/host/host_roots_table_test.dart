// Where every start mode keeps its data, logs, native profile store,
// checkpoints, database and documents. Existing installs depend on each of
// these: a root that moves strands a night's frames, the operator's site or a
// resumable run. Rows are the published ways to start Skotiq: an ordinary
// desktop or Windows install (no variables), a second instance relocated by
// SKOTIQ_DATA_DIR, an instance pinned to its own database, the systemd unit
// and Docker image (both variables), and the phone app, which shares the
// core resolvers but has no native store or checkpoints.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_desktop/desktop_logging_init.dart';
import 'package:skotiq_desktop/host/host_checkpoint_directory.dart';

typedef _Roots = ({
  String data,
  String logs,
  String profiles,
  String checkpoints,
  String database,
  String documents,
});

void main() {
  late Directory root;
  late Directory support;
  late Directory documents;

  setUp(() {
    root = Directory.systemTemp.createTempSync('sk-host-roots-');
    support = Directory(p.join(root.path, 'support'))..createSync();
    documents = Directory(p.join(root.path, 'Documents'))..createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<_Roots> resolve(Map<String, String> env) async {
    final log = await prepareDesktopLogDirectory(
      environment: env,
      applicationSupportDirectory: () async => support,
      documentsDirectory: () async => documents,
    );
    final profiles = await resolveDesktopProfileDirectory(
      environment: env,
      documentsDirectoryProvider: () async => documents,
    );
    final checkpoints = await resolveHostCheckpointDirectory(
      environment: env,
      applicationSupportDirectoryProvider: () async => support,
      documentsDirectoryProvider: () async => documents,
    );
    final database = await resolveDefaultDatabaseFile(
      environment: env,
      documentsDirectoryProvider: () async => documents,
    );
    final docs = await resolveSkotiqDocumentsDirectory(
      environment: env,
      documentsDirectoryProvider: () async => documents,
    );
    return (
      data: log.dataRoot,
      logs: log.logDirectory,
      profiles: profiles,
      checkpoints: checkpoints.path,
      database: database.path,
      documents: docs.path,
    );
  }

  String r(String relative) => p.join(root.path, relative);

  final rows =
      <
        String,
        (
          Map<String, String> Function(String Function(String)),
          _Roots Function(String Function(String)),
        )
      >{
        'ordinary install (Linux, Windows, macOS, scheduled task)': (
          (_) => const {},
          (r) => (
            data: r('support'),
            logs: r('support/logs'),
            profiles: r('Documents/Skotiq/profiles'),
            checkpoints: r('Documents/Skotiq/checkpoints'),
            database: r('Documents/Skotiq/skotiq.db'),
            documents: r('Documents'),
          ),
        ),
        'second instance relocated by SKOTIQ_DATA_DIR': (
          (r) => {skotiqDataDirEnv: r('instance')},
          (r) => (
            data: r('instance'),
            logs: r('instance/logs'),
            profiles: r('instance/documents/Skotiq/profiles'),
            checkpoints: r('instance/documents/Skotiq/checkpoints'),
            database: r('instance/documents/Skotiq/skotiq.db'),
            documents: r('instance/documents'),
          ),
        ),
        'instance pinned to its own database': (
          (r) => {skotiqDatabaseDirEnv: r('db')},
          (r) => (
            data: r('support'),
            logs: r('support/logs'),
            profiles: r('db/profiles'),
            checkpoints: r('db/checkpoints'),
            database: r('db/skotiq.db'),
            documents: r('Documents'),
          ),
        ),
        'systemd unit and Docker image (both variables)': (
          (r) => {
            skotiqDataDirEnv: r('var/lib/skotiq/data'),
            skotiqDatabaseDirEnv: r('var/lib/skotiq/database'),
          },
          (r) => (
            data: r('var/lib/skotiq/data'),
            logs: r('var/lib/skotiq/data/logs'),
            profiles: r('var/lib/skotiq/database/profiles'),
            checkpoints: r('var/lib/skotiq/database/checkpoints'),
            database: r('var/lib/skotiq/database/skotiq.db'),
            documents: r('var/lib/skotiq/data/documents'),
          ),
        ),
      };

  for (final MapEntry(key: mode, value: (env, expected)) in rows.entries) {
    test(mode, () async {
      expect(await resolve(env(r)), expected(r));
    });
  }

  test('phone app: data, logs, database and documents', () async {
    // The phone opens no native store and runs no sequence, so only the core
    // resolvers apply, with no variables.
    final data = await resolveSkotiqDataDirectory(
      environment: const {},
      applicationSupportDirectoryProvider: () async => support,
    );
    final database = await resolveDefaultDatabaseFile(
      environment: const {},
      documentsDirectoryProvider: () async => documents,
    );
    expect(data.path, r('support'));
    expect(database.path, r('Documents/Skotiq/skotiq.db'));
  });
}

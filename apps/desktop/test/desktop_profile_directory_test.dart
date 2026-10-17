// The native profile/settings store holds the observer site the sequencer and
// the planetarium gate on. It has to follow the same operator-configured data
// directory as `skotiq.db` and `pairing.db`, or an instance pinned to its
// own database reads — and rewrites — the machine-wide file: one process then
// answers `GET /api/settings` with the pinned database's 0,0 and
// `GET /api/settings/location` with a different install's real site, and every
// scratch or harness run mutates the operator's own settings.
//
// These tests pin the resolver against the same override every other store
// honours, and against the default that existing installs depend on.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/desktop_logging_init.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('desktop_profile_dir_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('the configured data directory owns the native profile store', () async {
    final dataDir = Directory(p.join(root.path, 'daemon-state'))
      ..createSync(recursive: true);
    final docs = Directory(p.join(root.path, 'Documents'))
      ..createSync(recursive: true);

    final resolved = await resolveDesktopProfileDirectory(
      environment: {skotiqDatabaseDirEnv: dataDir.path},
      documentsDirectoryProvider: () async => docs,
    );

    expect(resolved, p.join(dataDir.path, 'profiles'));
  });

  test('without an override the store stays in Documents/Skotiq', () async {
    final docs = Directory(p.join(root.path, 'Documents'))
      ..createSync(recursive: true);

    final resolved = await resolveDesktopProfileDirectory(
      environment: const {},
      documentsDirectoryProvider: () async => docs,
    );

    expect(resolved, p.join(docs.path, 'Skotiq', 'profiles'));
  });

  test('an empty override is ignored rather than resolving to a bare '
      'relative path', () async {
    final docs = Directory(p.join(root.path, 'Documents'))
      ..createSync(recursive: true);

    final resolved = await resolveDesktopProfileDirectory(
      environment: const {skotiqDatabaseDirEnv: '   '},
      documentsDirectoryProvider: () async => docs,
    );

    expect(resolved, p.join(docs.path, 'Skotiq', 'profiles'));
  });

  test('two pinned instances never share a settings file', () async {
    final docs = Directory(p.join(root.path, 'Documents'))
      ..createSync(recursive: true);
    final rig = Directory(p.join(root.path, 'rig-state'))
      ..createSync(recursive: true);
    final scratch = Directory(p.join(root.path, 'scratch-state'))
      ..createSync(recursive: true);

    final rigStore = await resolveDesktopProfileDirectory(
      environment: {skotiqDatabaseDirEnv: rig.path},
      documentsDirectoryProvider: () async => docs,
    );
    final scratchStore = await resolveDesktopProfileDirectory(
      environment: {skotiqDatabaseDirEnv: scratch.path},
      documentsDirectoryProvider: () async => docs,
    );
    final defaultStore = await resolveDesktopProfileDirectory(
      environment: const {},
      documentsDirectoryProvider: () async => docs,
    );

    expect(rigStore, isNot(scratchStore));
    expect(rigStore, isNot(defaultStore));
    expect(scratchStore, isNot(defaultStore));
    // The pinned stores live under their own data directory, so neither one
    // can reach the machine-wide file at all.
    expect(p.isWithin(rig.path, rigStore), isTrue);
    expect(p.isWithin(scratch.path, scratchStore), isTrue);
    expect(p.isWithin(docs.path, rigStore), isFalse);
    expect(p.isWithin(docs.path, scratchStore), isFalse);
  });

  test('the resolved store sits beside the database the same override '
      'pins', () async {
    final dataDir = Directory(p.join(root.path, 'daemon-state'))
      ..createSync(recursive: true);
    final docs = Directory(p.join(root.path, 'Documents'))
      ..createSync(recursive: true);

    final store = await resolveDesktopProfileDirectory(
      environment: {skotiqDatabaseDirEnv: dataDir.path},
      documentsDirectoryProvider: () async => docs,
    );
    final database = await resolveDefaultDatabaseFile(
      environment: {skotiqDatabaseDirEnv: dataDir.path},
      documentsDirectoryProvider: () async => docs,
    );

    expect(p.dirname(store), p.dirname(database.path));
  });
}

// First-launch migration of a pre-rename install's on-disk state.
//
// The fixture layouts mirror the REAL old paths, read from the pre-rename
// snapshot (663267b75):
//   * Linux app support:  $XDG_DATA_HOME/com.example.nightshade_desktop
//     (path_provider_linux resolves <dataHome>/<APPLICATION_ID>; the old
//     executable fallback is $XDG_DATA_HOME/nightshade_desktop)
//   * Windows app support: %APPDATA%/com.example/nightshade_desktop
//     (path_provider_windows builds <CompanyName>/<ProductName> out of the
//     old Runner.rc)
//   * macOS app support + prefs: ~/Library/Application Support/
//     com.example.nightshadeDesktop and ~/Library/Preferences/
//     com.example.nightshadeDesktop.plist
//   * Documents subtree: <documents>/Nightshade holding nightshade.db,
//     pairing.db, profiles/, and nightshade-*.log / -corrupt-*.db names
//
// This file is allowlisted in tools/rebrand/legacy_allowlist.txt — it has to
// spell the old name to lay out the fixture.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('skotiq-migration');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  File fileIn(Directory root, String name, [String contents = 'x']) {
    final f = File(p.join(root.path, name));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(contents);
    return f;
  }

  /// Linux fixture: old app-support root at the application-id path, plus a
  /// parallel old documents subtree, plus an executable-name fallback dir.
  ({
    Directory oldDataRoot,
    Directory newDataRoot,
    Directory oldDocuments,
    Directory newDocuments,
    Directory fallbackRoot,
  }) linuxFixture() {
    final dataHome = Directory(p.join(tempRoot.path, 'datahome'))
      ..createSync();
    final docsHome = Directory(p.join(tempRoot.path, 'docs'))..createSync();
    final oldRoot = Directory(
      p.join(dataHome.path, 'com.example.nightshade_desktop'),
    );
    final newRoot = Directory(
      p.join(dataHome.path, 'com.skotiq.desktop'),
    );
    final fallback = Directory(p.join(dataHome.path, 'nightshade_desktop'));

    // Old application-support contents: preferences file, catalogs, secrets
    // and a log dir with the old log basename.
    fileIn(oldRoot, 'shared_preferences.json', '{"k":1}');
    fileIn(oldRoot, 'push_config.json');
    fileIn(oldRoot, 'logs/nightshade.log', 'old log');
    fileIn(oldRoot, 'logs/nightshade-dart.log', 'old dart log');

    // Old documents subtree: database, pairing database, profiles, plus a
    // corrupt-db backup the doctor flow stashed.
    final oldDocs = Directory(p.join(docsHome.path, 'Nightshade'));
    fileIn(oldDocs, 'nightshade.db', 'database-bytes');
    fileIn(oldDocs, 'pairing.db');
    fileIn(oldDocs, 'nightshade-corrupt-1710000000000.db', 'backup');
    // The doctor flow also embeds the db name: a fully-purged file looks
    // like what a fresh Skotiq install would have written.
    fileIn(
      oldDocs,
      'nightshade-corrupt-1710000000001-nightshade.db',
      'backup',
    );
    fileIn(oldDocs, 'profiles/default.json');

    final newDocs = Directory(p.join(docsHome.path, 'Skotiq'));

    return (
      oldDataRoot: oldRoot,
      newDataRoot: newRoot,
      oldDocuments: oldDocs,
      newDocuments: newDocs,
      fallbackRoot: fallback,
    );
  }

  Map<String, String> linuxEnv(Directory dataHome) =>
      {'HOME': tempRoot.path, 'XDG_DATA_HOME': dataHome.path};

  group('linux data root', () {
    test('moves the old application-support root and renames inner files',
        () async {
      final fixture = linuxFixture();
      final dataHome = fixture.oldDataRoot.parent;

      final report = await migrateLegacyInstall(
        dataRoot: fixture.newDataRoot.path,
        environment: linuxEnv(dataHome),
        operatingSystem: 'linux',
        log: (_) {},
      );

      // The whole tree moved under the new application-id directory.
      expect(fixture.oldDataRoot.existsSync(), isFalse);
      expect(fixture.newDataRoot.existsSync(), isTrue);
      expect(
        File(
          p.join(fixture.newDataRoot.path, 'shared_preferences.json'),
        ).existsSync(),
        isTrue,
      );
      // Log basenames carried the old prefix; they rename in place.
      expect(
        File(p.join(fixture.newDataRoot.path, 'logs', 'skotiq.log'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(p.join(fixture.newDataRoot.path, 'logs', 'skotiq-dart.log'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(p.join(fixture.newDataRoot.path, 'logs', 'nightshade.log'))
            .existsSync(),
        isFalse,
      );
      expect(report.didWork, isTrue);
      expect(report.warnings, isEmpty);
    });

    test('falls back to the executable-name root when the app-id root is '
        'absent', () async {
      final fixture = linuxFixture();
      final dataHome = fixture.oldDataRoot.parent;
      fixture.oldDataRoot.deleteSync(recursive: true);
      fileIn(fixture.fallbackRoot, 'shared_preferences.json');

      final report = await migrateLegacyInstall(
        dataRoot: fixture.newDataRoot.path,
        environment: linuxEnv(dataHome),
        operatingSystem: 'linux',
        log: (_) {},
      );

      expect(fixture.fallbackRoot.existsSync(), isFalse);
      expect(
        File(
          p.join(fixture.newDataRoot.path, 'shared_preferences.json'),
        ).existsSync(),
        isTrue,
      );
      expect(report.didWork, isTrue);
    });

    test('merges into a populated new root without overwriting', () async {
      final fixture = linuxFixture();
      final dataHome = fixture.oldDataRoot.parent;
      // The new install already ran once and wrote its own preferences.
      fileIn(
        fixture.newDataRoot,
        'shared_preferences.json',
        '{"fresh":true}',
      );

      final report = await migrateLegacyInstall(
        dataRoot: fixture.newDataRoot.path,
        environment: linuxEnv(dataHome),
        operatingSystem: 'linux',
        log: (_) {},
      );

      // Existing content won; the colliding old file stayed in the old tree.
      expect(
        File(
          p.join(fixture.newDataRoot.path, 'shared_preferences.json'),
        ).readAsStringSync(),
        '{"fresh":true}',
      );
      expect(
        File(
          p.join(fixture.oldDataRoot.path, 'shared_preferences.json'),
        ).existsSync(),
        isTrue,
      );
      // Non-colliding content still moved across.
      expect(
        File(p.join(fixture.newDataRoot.path, 'push_config.json'))
            .existsSync(),
        isTrue,
      );
      expect(
        report.warnings.where((w) => w.contains('kept both')),
        isNotEmpty,
      );
    });
  });

  group('documents subtree', () {
    test('renames Nightshade/ to Skotiq/ and the inner database names',
        () async {
      final fixture = linuxFixture();
      final dataHome = fixture.oldDataRoot.parent;

      await migrateLegacyInstall(
        dataRoot: fixture.newDataRoot.path,
        documentsRoot: fixture.newDocuments.parent.path,
        environment: linuxEnv(dataHome),
        operatingSystem: 'linux',
        log: (_) {},
      );

      expect(fixture.oldDocuments.existsSync(), isFalse);
      expect(fixture.newDocuments.existsSync(), isTrue);
      expect(
        File(p.join(fixture.newDocuments.path, 'skotiq.db'))
            .readAsStringSync(),
        'database-bytes',
      );
      expect(
        File(p.join(fixture.newDocuments.path, 'pairing.db')).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(
            fixture.newDocuments.path,
            'skotiq-corrupt-1710000000000.db',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(
            fixture.newDocuments.path,
            'skotiq-corrupt-1710000000001-skotiq.db',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(fixture.newDocuments.path, 'profiles', 'default.json'))
            .existsSync(),
        isTrue,
      );
    });

    test('a colliding skotiq.db keeps the legacy file as .legacy', () async {
      final fixture = linuxFixture();
      final dataHome = fixture.oldDataRoot.parent;
      // A partially-upgraded install: the new documents tree already has a
      // skotiq.db (e.g. the user ran a nightly between the rename landing
      // and this migration). Nothing may be silently lost.
      fileIn(fixture.newDocuments, 'skotiq.db', 'new-database');

      await migrateLegacyInstall(
        dataRoot: fixture.newDataRoot.path,
        documentsRoot: fixture.newDocuments.parent.path,
        environment: linuxEnv(dataHome),
        operatingSystem: 'linux',
        log: (_) {},
      );

      expect(
        File(p.join(fixture.newDocuments.path, 'skotiq.db'))
            .readAsStringSync(),
        'new-database',
      );
      expect(
        File(p.join(fixture.newDocuments.path, 'skotiq.db.legacy'))
            .readAsStringSync(),
        'database-bytes',
      );
    });
  });

  group('SKOTIQ_DATA_DIR relocation', () {
    test('old roots are left alone but reported', () async {
      final fixture = linuxFixture();
      final dataHome = fixture.oldDataRoot.parent;
      final relocated = Directory(p.join(tempRoot.path, 'relocated'));

      final report = await migrateLegacyInstall(
        dataRoot: relocated.path,
        environment: {
          ...linuxEnv(dataHome),
          skotiqDataDirEnv: relocated.path,
        },
        operatingSystem: 'linux',
        log: (_) {},
      );

      expect(fixture.oldDataRoot.existsSync(), isTrue);
      expect(
        report.warnings.where((w) => w.contains('legacy data root')),
        isNotEmpty,
      );
    });
  });

  group('old environment variables', () {
    test('a set NIGHTSHADE_DATA_DIR is surfaced, not honored', () async {
      final fixture = linuxFixture();
      final dataHome = fixture.oldDataRoot.parent;

      final report = await migrateLegacyInstall(
        dataRoot: fixture.newDataRoot.path,
        environment: {
          ...linuxEnv(dataHome),
          'NIGHTSHADE_DATA_DIR': '/somewhere/else',
        },
        operatingSystem: 'linux',
        log: (_) {},
      );

      expect(
        report.warnings.where((w) => w.contains('NIGHTSHADE_DATA_DIR')),
        isNotEmpty,
      );
      // The normal migration still ran — the warning is informational.
      expect(fixture.newDataRoot.existsSync(), isTrue);
    });
  });

  group('windows', () {
    test('moves %APPDATA%/com.example/nightshade_desktop and the '
        '%LOCALAPPDATA% cache', () async {
      final appData = Directory(p.join(tempRoot.path, 'AppData', 'Roaming'))
        ..createSync(recursive: true);
      final local = Directory(p.join(tempRoot.path, 'AppData', 'Local'))
        ..createSync(recursive: true);
      final oldRoot = Directory(
        p.join(appData.path, 'com.example', 'nightshade_desktop'),
      );
      final newRoot = Directory(p.join(appData.path, 'Skotiq', 'Skotiq'));
      fileIn(oldRoot, 'shared_preferences.json');
      // Windows secure storage is an encrypted file inside app support —
      // moving the root carries it.
      fileIn(
        oldRoot,
        'flutter_secure_storage.dat',
        'ciphertext',
      );
      fileIn(
        Directory(p.join(local.path, 'com.example', 'nightshade_desktop')),
        'cache.bin',
      );

      final report = await migrateLegacyInstall(
        dataRoot: newRoot.path,
        environment: {
          'APPDATA': appData.path,
          'LOCALAPPDATA': local.path,
        },
        operatingSystem: 'windows',
        log: (_) {},
      );

      expect(oldRoot.existsSync(), isFalse);
      expect(
        File(p.join(newRoot.path, 'shared_preferences.json')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(newRoot.path, 'flutter_secure_storage.dat')).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(local.path, 'Skotiq', 'Skotiq', 'cache.bin'),
        ).existsSync(),
        isTrue,
      );
      expect(report.warnings, isEmpty);
    });
  });

  group('macos', () {
    test('moves Application Support and renames the preferences plist',
        () async {
      final home = Directory(p.join(tempRoot.path, 'home'))..createSync();
      final oldRoot = Directory(
        p.join(
          home.path,
          'Library',
          'Application Support',
          'com.example.nightshadeDesktop',
        ),
      );
      final newRoot = Directory(
        p.join(
          home.path,
          'Library',
          'Application Support',
          'com.skotiq.desktop',
        ),
      );
      fileIn(oldRoot, 'push_config.json');
      fileIn(
        Directory(
          p.join(
            home.path,
            'Library',
            'Caches',
            'com.example.nightshadeDesktop',
          ),
        ),
        'catalog.bin',
      );
      fileIn(
        Directory(p.join(home.path, 'Library', 'Preferences')),
        'com.example.nightshadeDesktop.plist',
        '<plist/>',
      );

      final report = await migrateLegacyInstall(
        dataRoot: newRoot.path,
        environment: {'HOME': home.path},
        operatingSystem: 'macos',
        log: (_) {},
      );

      expect(oldRoot.existsSync(), isFalse);
      expect(
        File(p.join(newRoot.path, 'push_config.json')).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(
            home.path,
            'Library',
            'Caches',
            'com.skotiq.desktop',
            'catalog.bin',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(
            home.path,
            'Library',
            'Preferences',
            'com.skotiq.desktop.plist',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(report.warnings, isEmpty);
    });
  });

  group('pinned database directory', () {
    test('renames old database files outside the data root', () async {
      final fixture = linuxFixture();
      final dataHome = fixture.oldDataRoot.parent;
      final dbDir = Directory(p.join(tempRoot.path, 'db'))..createSync();
      fileIn(dbDir, 'nightshade.db', 'database-bytes');
      fileIn(dbDir, 'nightshade.db-journal');

      await migrateLegacyInstall(
        dataRoot: fixture.newDataRoot.path,
        databaseDirectory: dbDir.path,
        environment: linuxEnv(dataHome),
        operatingSystem: 'linux',
        log: (_) {},
      );

      expect(File(p.join(dbDir.path, 'skotiq.db')).existsSync(), isTrue);
      expect(
        File(p.join(dbDir.path, 'skotiq.db-journal')).existsSync(),
        isTrue,
      );
    });
  });

  group('appliance', () {
    test('folds the legacy sibling state dir into a relocated skotiq root',
        () async {
      // headless.env pins SKOTIQ_DATA_DIR=/var/lib/skotiq; the old appliance
      // kept its state at /var/lib/nightshade. Fixture mirrors that under the
      // temp dir: <tmp>/var/lib/{nightshade,skotiq}.
      final varLib = Directory(p.join(tempRoot.path, 'var', 'lib'))
        ..createSync(recursive: true);
      final legacyState = Directory(p.join(varLib.path, 'nightshade'));
      final newState = Directory(p.join(varLib.path, 'skotiq'));
      fileIn(legacyState, 'database/nightshade.db', 'database-bytes');
      fileIn(legacyState, 'logs/nightshade.log', 'old log');

      await migrateLegacyInstall(
        dataRoot: newState.path,
        databaseDirectory: p.join(newState.path, 'database'),
        environment: {
          'HOME': tempRoot.path,
          skotiqDataDirEnv: newState.path,
        },
        operatingSystem: 'linux',
        legacyApplianceStateDirOverride: legacyState.path,
        legacyApplianceConfDirOverride:
            p.join(tempRoot.path, 'etc', 'nightshade'),
        applianceConfDir: p.join(tempRoot.path, 'etc', 'skotiq'),
        legacyApplianceUnitFileOverride:
            p.join(tempRoot.path, 'units', 'nightshade-headless.service'),
        log: (_) {},
      );

      // The sibling folded in; inner db renamed by the data-root pass.
      expect(
        File(p.join(newState.path, 'database', 'skotiq.db'))
            .readAsStringSync(),
        'database-bytes',
      );
      expect(
        File(p.join(newState.path, 'logs', 'skotiq.log')).existsSync(),
        isTrue,
      );
    });

    test('translates headless.env when the process can write the conf dir',
        () async {
      final legacyConf = Directory(
        p.join(tempRoot.path, 'etc', 'nightshade'),
      );
      final confDir = Directory(p.join(tempRoot.path, 'etc', 'skotiq'));
      fileIn(
        legacyConf,
        'headless.env',
        'NIGHTSHADE_AUTH_TOKEN=tok123\n'
            'NIGHTSHADE_DATA_DIR=/var/lib/nightshade\n'
            'NIGHTSHADE_DATABASE_DIR=/var/lib/nightshade/database\n'
            'NIGHTSHADE_PORT=9090\n',
      );

      final report = await migrateLegacyInstall(
        dataRoot: p.join(tempRoot.path, 'data'),
        environment: {'HOME': tempRoot.path},
        operatingSystem: 'linux',
        legacyApplianceConfDirOverride: legacyConf.path,
        applianceConfDir: confDir.path,
        legacyApplianceStateDirOverride:
            p.join(tempRoot.path, 'var', 'lib', 'nightshade'),
        legacyApplianceUnitFileOverride:
            p.join(tempRoot.path, 'units', 'nightshade-headless.service'),
        log: (_) {},
      );

      final translated =
          File(p.join(confDir.path, 'headless.env')).readAsStringSync();
      expect(translated, contains('SKOTIQ_AUTH_TOKEN=tok123'));
      expect(translated, contains('SKOTIQ_DATA_DIR=/var/lib/skotiq'));
      expect(
        translated,
        contains('SKOTIQ_DATABASE_DIR=/var/lib/skotiq/database'),
      );
      expect(translated, contains('SKOTIQ_PORT=9090'));
      expect(translated, isNot(contains('NIGHTSHADE')));
      // The original stays put as a backup.
      expect(
        File(p.join(legacyConf.path, 'headless.env')).existsSync(),
        isTrue,
      );
      expect(
        report.actions.where((a) => a.contains('translated')),
        isNotEmpty,
      );
    });

    test('an existing new headless.env wins; the old file only warns',
        () async {
      final legacyConf = Directory(
        p.join(tempRoot.path, 'etc', 'nightshade'),
      );
      final confDir = Directory(p.join(tempRoot.path, 'etc', 'skotiq'));
      fileIn(legacyConf, 'headless.env', 'NIGHTSHADE_AUTH_TOKEN=old\n');
      fileIn(confDir, 'headless.env', 'SKOTIQ_AUTH_TOKEN=new\n');

      final report = await migrateLegacyInstall(
        dataRoot: p.join(tempRoot.path, 'data'),
        environment: {'HOME': tempRoot.path},
        operatingSystem: 'linux',
        legacyApplianceConfDirOverride: legacyConf.path,
        applianceConfDir: confDir.path,
        legacyApplianceStateDirOverride:
            p.join(tempRoot.path, 'var', 'lib', 'nightshade'),
        legacyApplianceUnitFileOverride:
            p.join(tempRoot.path, 'units', 'nightshade-headless.service'),
        log: (_) {},
      );

      expect(
        File(p.join(confDir.path, 'headless.env')).readAsStringSync(),
        'SKOTIQ_AUTH_TOKEN=new\n',
      );
      expect(
        report.warnings.where((w) => w.contains('headless.env')),
        isNotEmpty,
      );
    });

    test('a leftover legacy systemd unit is surfaced', () async {
      final unit = File(
        p.join(tempRoot.path, 'units', 'nightshade-headless.service'),
      )..createSync(recursive: true);
      unit.writeAsStringSync('[Service]\n');

      final report = await migrateLegacyInstall(
        dataRoot: p.join(tempRoot.path, 'data'),
        environment: {'HOME': tempRoot.path},
        operatingSystem: 'linux',
        legacyApplianceStateDirOverride:
            p.join(tempRoot.path, 'var', 'lib', 'nightshade'),
        legacyApplianceConfDirOverride:
            p.join(tempRoot.path, 'etc', 'nightshade'),
        applianceConfDir: p.join(tempRoot.path, 'etc', 'skotiq'),
        legacyApplianceUnitFileOverride: unit.path,
        log: (_) {},
      );

      expect(
        report.warnings.where((w) => w.contains('systemd unit')),
        isNotEmpty,
      );
    });
  });

  group('idempotency', () {
    test('a second run does nothing', () async {
      final fixture = linuxFixture();
      final dataHome = fixture.oldDataRoot.parent;

      await migrateLegacyInstall(
        dataRoot: fixture.newDataRoot.path,
        documentsRoot: fixture.newDocuments.parent.path,
        environment: linuxEnv(dataHome),
        operatingSystem: 'linux',
        log: (_) {},
      );
      final second = await migrateLegacyInstall(
        dataRoot: fixture.newDataRoot.path,
        documentsRoot: fixture.newDocuments.parent.path,
        environment: linuxEnv(dataHome),
        operatingSystem: 'linux',
        log: (_) {},
      );

      expect(second.actions, isEmpty);
      // The first pass already moved everything; no leftovers should warn.
      expect(second.warnings, isEmpty);
      expect(
        File(p.join(fixture.newDocuments.path, 'skotiq.db')).existsSync(),
        isTrue,
      );
    });
  });

  group('secure-storage namespace', () {
    test('re-keys old-namespace entries and deletes the old keys', () async {
      final backing = <String, String>{
        'ns.notif.v1.email.password': 'secret1',
        'ns.notif.v1.mqtt.password': 'secret2',
        'unrelated.key': 'leave-me',
      };
      Future<String?> read(String k) async => backing[k];
      Future<void> write(String k, String v) async => backing[k] = v;
      Future<void> delete(String k) async => backing.remove(k);

      final moved = await migrateLegacySecretsNamespace(
        read,
        write,
        delete,
        const ['email.password', 'mqtt.password', 'telegram.bot_token'],
        'skotiq.notif.v1.',
      );

      expect(moved, 2);
      expect(backing['skotiq.notif.v1.email.password'], 'secret1');
      expect(backing['skotiq.notif.v1.mqtt.password'], 'secret2');
      expect(backing['ns.notif.v1.email.password'], isNull);
      expect(backing['unrelated.key'], 'leave-me');

      // Idempotent: nothing under the old prefix remains.
      expect(
        await migrateLegacySecretsNamespace(
          read,
          write,
          delete,
          const ['email.password', 'mqtt.password'],
          'skotiq.notif.v1.',
        ),
        0,
      );
    });

    test('does not clobber a value already under the new key', () async {
      final backing = <String, String>{
        'ns.notif.v1.email.password': 'old-secret',
        'skotiq.notif.v1.email.password': 'new-secret',
      };
      Future<String?> read(String k) async => backing[k];
      Future<void> write(String k, String v) async => backing[k] = v;
      Future<void> delete(String k) async => backing.remove(k);

      await migrateLegacySecretsNamespace(
        read,
        write,
        delete,
        const ['email.password'],
        'skotiq.notif.v1.',
      );

      expect(backing['skotiq.notif.v1.email.password'], 'new-secret');
      expect(backing['ns.notif.v1.email.password'], isNull);
    });
  });
}

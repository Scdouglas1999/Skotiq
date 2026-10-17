// One resolver decides where this instance's data lives.
//
// Live defect (fresh-install audit, 2026-09-01): SKOTIQ_DATA_DIR relocated
// the Rust side's persistence and the Dart log directory, and nothing else.
// Catalogs, catalog caches, checkpoints, the sky atlas, staged updates, the
// remote-access token and the push secret went on resolving
// `getApplicationSupportDirectory()` directly, so an instance pointed at its
// own tree still read three fully-populated catalogs out of
// `~/.local/share/com.skotiq.desktop/` — and still wrote its
// credentials there. A "fresh install" launched on empty directories was
// therefore only fresh for the halves the env vars happened to cover.
//
// These tests pin the two halves of the contract: the override wins when set,
// and when it is unset the answer is byte-for-byte `path_provider`'s, so a
// real install cannot lose its catalogs or tokens.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempRoot;
  late Directory platformSupport;
  late Directory platformDocuments;
  late Directory relocated;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('sk-dir-resolver');
    platformSupport = Directory(p.join(tempRoot.path, 'platform-support'))
      ..createSync(recursive: true);
    platformDocuments = Directory(p.join(tempRoot.path, 'platform-documents'))
      ..createSync(recursive: true);
    relocated = Directory(p.join(tempRoot.path, 'relocated'));
    debugResetSkotiqProcessEnvironment();
  });

  tearDown(() {
    debugResetSkotiqProcessEnvironment();
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  Future<Directory> platformSupportProvider() async => platformSupport;
  Future<Directory> platformDocumentsProvider() async => platformDocuments;

  group('application-support root', () {
    test('SKOTIQ_DATA_DIR wins over the platform folder', () async {
      final resolved = await resolveSkotiqDataDirectory(
        environment: {skotiqDataDirEnv: relocated.path},
        applicationSupportDirectoryProvider: platformSupportProvider,
      );

      expect(resolved.path, relocated.path);
      // The catalogs, the token and the push secret all hang off this root, so
      // a relocated instance that never creates it is the same defect again.
      expect(resolved.existsSync(), isTrue);
    });

    test('unset is a pass-through to path_provider', () async {
      final resolved = await resolveSkotiqDataDirectory(
        environment: const <String, String>{},
        applicationSupportDirectoryProvider: platformSupportProvider,
      );

      expect(resolved.path, platformSupport.path);
    });

    test('a blank value counts as unset', () async {
      final resolved = await resolveSkotiqDataDirectory(
        environment: const {skotiqDataDirEnv: '   '},
        applicationSupportDirectoryProvider: platformSupportProvider,
      );

      expect(resolved.path, platformSupport.path);
    });
  });

  group('documents root', () {
    test('SKOTIQ_DATA_DIR moves it under the relocated tree', () async {
      final resolved = await resolveSkotiqDocumentsDirectory(
        environment: {skotiqDataDirEnv: relocated.path},
        documentsDirectoryProvider: platformDocumentsProvider,
      );

      expect(
        resolved.path,
        p.join(relocated.path, skotiqRelocatedDocumentsDirName),
      );
      expect(resolved.existsSync(), isTrue);
    });

    test('it does not collide with the app-private root', () async {
      final support = await resolveSkotiqDataDirectory(
        environment: {skotiqDataDirEnv: relocated.path},
        applicationSupportDirectoryProvider: platformSupportProvider,
      );
      final documents = await resolveSkotiqDocumentsDirectory(
        environment: {skotiqDataDirEnv: relocated.path},
        documentsDirectoryProvider: platformDocumentsProvider,
      );

      expect(documents.path, isNot(support.path));
      expect(p.isWithin(support.path, documents.path), isTrue);
    });

    test('unset is a pass-through to path_provider', () async {
      final resolved = await resolveSkotiqDocumentsDirectory(
        environment: const <String, String>{},
        documentsDirectoryProvider: platformDocumentsProvider,
      );

      expect(resolved.path, platformDocuments.path);
      // Nothing may be invented next to the user's real Documents folder.
      expect(
        Directory(
          p.join(platformDocuments.path, skotiqRelocatedDocumentsDirName),
        ).existsSync(),
        isFalse,
      );
    });
  });

  group('process-environment snapshot', () {
    test('the first snapshot wins', () {
      captureSkotiqProcessEnvironment({skotiqDataDirEnv: '/first'});
      captureSkotiqProcessEnvironment({skotiqDataDirEnv: '/second'});

      expect(skotiqProcessEnvironment[skotiqDataDirEnv], '/first');
    });

    test('a value written back into the environment after the snapshot cannot '
        'relocate this instance', () async {
      // apps/desktop publishes its resolved data root back into the C
      // environment so Rust lands in the same tree, and with nothing set by
      // the operator that value IS the platform application-support path.
      // Read afterwards it would look like a relocation and drag the
      // documents root off ~/Documents on an ordinary install.
      captureSkotiqProcessEnvironment(const <String, String>{});

      final documents = await resolveSkotiqDocumentsDirectory(
        documentsDirectoryProvider: platformDocumentsProvider,
      );
      final support = await resolveSkotiqDataDirectory(
        applicationSupportDirectoryProvider: platformSupportProvider,
      );

      expect(documents.path, platformDocuments.path);
      expect(support.path, platformSupport.path);
    });

    test('with no snapshot the resolvers read the live environment', () async {
      // Mobile and any process that never calls the capture must keep working:
      // the getter falls through to Platform.environment.
      expect(
        skotiqProcessEnvironment[skotiqDataDirEnv],
        Platform.environment[skotiqDataDirEnv],
      );
    });
  });
}

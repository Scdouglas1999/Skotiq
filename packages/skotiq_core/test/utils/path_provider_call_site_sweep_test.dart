// The data-directory seam is only worth anything while it is the ONLY seam.
//
// Before the fresh-install audit of 2026-09-01 there were 56 direct
// `getApplicationSupportDirectory()` / `getApplicationDocumentsDirectory()`
// calls spread over four packages, and SKOTIQ_DATA_DIR reached none of
// them: catalogs, caches, checkpoints, the remote-access token and the push
// secret all went to `~/.local/share/com.skotiq.desktop/` whatever
// the operator configured. Routing them once fixes it; nothing keeps it fixed
// except a test that fails the moment a fifty-seventh call appears.
//
// If this test fails, the fix is to call `resolveSkotiqDataDirectory` (app
// state) or `resolveSkotiqDocumentsDirectory` (user-facing output) from
// `package:skotiq_core/skotiq_core.dart` instead — not to add the new
// file to the exemption list. The list is closed; see the entry for the one
// member it has.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Files allowed to name `path_provider`'s directory functions directly,
/// each with the reason it cannot go through the resolver.
const Map<String, String> _exemptions = <String, String>{
  // The resolver itself: someone has to make the platform call.
  'packages/skotiq_core/lib/src/utils/skotiq_data_directory.dart':
      'defines the resolver',

  // skotiq_core depends on skotiq_remote_protocol, so importing the
  // resolver here would close a dependency cycle. Nothing leaks: this file's
  // root is the database directory, which SKOTIQ_DATABASE_DIR already
  // relocates, and the platform documents folder is only the default.
  'packages/skotiq_remote_protocol/lib/src/database/pairing_database.dart':
      'no dependency edge to skotiq_core (core depends on it)',
};

const List<String> _bannedSymbols = <String>[
  'getApplicationSupportDirectory',
  'getApplicationDocumentsDirectory',
];

/// Repo root, found by walking up from the test's working directory to the
/// melos workspace file. Works whether the suite is run from the package or
/// from the workspace root.
Directory _repoRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    if (File(p.join(dir.path, 'melos.yaml')).existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'melos.yaml not found above ${Directory.current.path}; the sweep cannot '
    'tell which tree it is meant to scan.',
  );
}

bool _isScannable(String relativePath) {
  if (!relativePath.endsWith('.dart')) return false;
  const skipSegments = <String>[
    '/test/',
    '/build/',
    '/.dart_tool/',
    '/ephemeral/',
    '/.plugin_symlinks/',
    '/generated/',
  ];
  final probe = '/$relativePath';
  return !skipSegments.any(probe.contains);
}

void main() {
  test('every application directory is resolved in exactly one place', () {
    final root = _repoRoot();
    final scanRoots = <Directory>[
      Directory(p.join(root.path, 'packages')),
      Directory(p.join(root.path, 'apps')),
    ];

    final offenders = <String>[];
    final exemptionsSeen = <String>{};

    for (final scanRoot in scanRoots) {
      if (!scanRoot.existsSync()) continue;
      for (final entity in scanRoot.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final relative = p
            .relative(entity.path, from: root.path)
            .replaceAll(r'\', '/');
        if (!_isScannable(relative)) continue;

        final source = entity.readAsStringSync();
        final hits = _bannedSymbols
            .where((symbol) => source.contains(symbol))
            .toList(growable: false);
        if (hits.isEmpty) continue;

        if (_exemptions.containsKey(relative)) {
          exemptionsSeen.add(relative);
          continue;
        }
        offenders.add('$relative -> ${hits.join(', ')}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files call path_provider directly instead of going through '
          'resolveSkotiqDataDirectory / '
          'resolveSkotiqDocumentsDirectory, so SKOTIQ_DATA_DIR does '
          'not reach the data they store:\n  ${offenders.join('\n  ')}',
    );

    // A stale exemption is its own defect: it tells the next reader a
    // constraint still exists when it does not.
    expect(
      exemptionsSeen,
      unorderedEquals(_exemptions.keys),
      reason:
          'An exemption no longer matches a file that calls path_provider. '
          'Remove it from _exemptions.',
    );
  });
}

// One-shot carry-forward of a pre-rename install's on-disk state.
//
// Skotiq used to ship as a different product name. The old install kept the
// same shape — an application-support root, a Documents subtree, a database,
// logs, preferences and a secure-storage key namespace — under directories
// and file names derived from that name. The first launch after the rename
// must move all of it, because the owner and every beta tester have real
// sequences, equipment profiles, pairings and calibration masters sitting in
// the old tree.
//
// THIS FILE IS THE ONLY PLACE IN THE REPOSITORY ALLOWED TO NAME THE OLD
// PRODUCT. It is registered in tools/rebrand/legacy_allowlist.txt. Do not
// import these constants to reintroduce the old name elsewhere; if a new
// call site needs an old-name literal, the design is wrong — keep it here.
//
// Scope:
//   * Application-support / data root: moved (rename, verified copy as
//     fallback) into the location the new resolvers already picked.
//   * Documents subtree `Nightshade/` -> `Skotiq/` (database, pairing.db,
//     profiles, exports, reports).
//   * Inner file/dir names that carried the old name (`nightshade.db`,
//     `nightshade-corrupt-*.db`, `nightshade*.log`, `Nightshade/` subdirs).
//   * macOS preferences plist rename (old bundle id -> new bundle id).
//   * Linux/macOS cache directory move (rebuildable, but cheap to carry).
//   * Secure-storage key namespace `ns.notif.v1.*` -> `skotiq.notif.v1.*`
//     via [migrateLegacySecretsNamespace], driven from SecretsStore.
//
// Explicitly NOT migrated:
//   * Android/iOS: the application id changed, so the old app is a separate
//     sandboxed install; no in-place filesystem migration is possible.
//   * Old NIGHTSHADE_* environment variables: not honoured. The install.sh
//     appliance migration rewrites them inside headless.env instead.
//   * Absolute paths stored inside database rows (e.g. a capture directory a
//     profile saved). Rows are user data; rewriting strings in SQLite here
//     would risk corrupting real installs.

import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;

import 'skotiq_data_directory.dart' show skotiqDataDirEnv;

// --- Pre-rename literals ----------------------------------------------------
// These strings describe where the OLD product stored things. They must not
// appear anywhere else in the tree.

/// App-data subdirectory names the old product used for its
/// application-support root on each platform.
const String legacyProductDirName = 'Nightshade';
const String legacyLinuxApplicationId = 'com.example.nightshade_desktop';
const String legacyMacBundleId = 'com.example.nightshadeDesktop';
const String legacyWindowsCompanyDir = 'com.example';
const String legacyWindowsProductDir = 'nightshade_desktop';

/// path_provider on Linux falls back to the executable name when no
/// GApplication id is registered; the old binary was `nightshade_desktop`.
const String legacyExecutableName = 'nightshade_desktop';

/// Appliance (systemd headless) layout the old installer used. A Skotiq
/// appliance keeps the same shape under `skotiq` names, so the legacy side
/// is a fixed sibling pair.
const String legacyApplianceStateDir = '/var/lib/nightshade';
const String legacyApplianceConfDir = '/etc/nightshade';
const String legacyApplianceUnitFile =
    '/etc/systemd/system/nightshade-headless.service';

/// File basenames starting with this prefix belonged to the old product
/// (`nightshade.db`, `nightshade-corrupt-<ts>.db`, `nightshade.log`,
/// `nightshade-dart.log`, `nightshade-premigration-*.db`, ...).
const String legacyFilePrefix = 'nightshade';

/// Environment variables the old product read. Not honoured — surfaced in
/// the migration report so an operator who set one learns it no longer
/// applies.
const String legacyDataDirEnv = 'NIGHTSHADE_DATA_DIR';
const String legacyDatabaseDirEnv = 'NIGHTSHADE_DATABASE_DIR';

/// Key namespace the old product used inside the platform secure store for
/// notification/transport secrets (`ns.` = old product initials).
const String legacySecretsKeyNamespace = 'ns.notif.v1.';

// --- New-name anchors --------------------------------------------------------

/// Directory name the product writes inside the documents root and inside
/// the data root (`Skotiq/push_config.json`, `Skotiq/plugins`).
const String skotiqProductDirName = 'Skotiq';
const String skotiqFilePrefix = 'skotiq';

/// Application id the Linux/macOS builds now register under.
const String skotiqLinuxApplicationId = 'com.skotiq.desktop';
const String skotiqMacBundleId = 'com.skotiq.desktop';

/// New appliance paths — the counterpart of the legacy constants above.
const String skotiqApplianceStateDir = '/var/lib/skotiq';
const String skotiqApplianceConfDir = '/etc/skotiq';

/// What the migration did, for logging and tests.
class LegacyInstallMigrationReport {
  /// Completed actions, in order ("moved X -> Y", "renamed A -> B").
  final List<String> actions = [];

  /// Non-fatal problems: collisions left in place, partial copies, unreadable
  /// entries. Anything here means a human should look.
  final List<String> warnings = [];

  bool get didWork => actions.isNotEmpty;
}

/// Sink for migration progress lines.
typedef MigrationLogFn = void Function(String message);

/// Runs the whole first-launch migration against the already-resolved new
/// roots. Pure filesystem: every path arrives as a parameter or is derived
/// from [environment], so a test can point it at a synthetic tree.
///
/// [dataRoot] is this process's resolved data root (the value
/// `resolveSkotiqDataDirectory` already produced). [documentsRoot] is the
/// resolved documents directory when the caller has one. [databaseDirectory]
/// is the resolved `SKOTIQ_DATABASE_DIR` when set — it can live outside
/// [dataRoot]. [operatingSystem] exists so tests can exercise the Windows
/// and macOS layouts from Linux; it defaults to the real platform.
///
/// The appliance overrides exist for tests — production callers leave them
/// null so the real `/var/lib/...`, `/etc/...` and `/etc/systemd/...` paths
/// are used.
///
/// This function MUST NOT crash startup: every filesystem step converts
/// failures (permissions, half-readable trees, locked files) into warnings.
Future<LegacyInstallMigrationReport> migrateLegacyInstall({
  required String dataRoot,
  String? documentsRoot,
  String? databaseDirectory,
  Map<String, String>? environment,
  String? operatingSystem,
  String? applianceConfDir,
  String? legacyApplianceStateDirOverride,
  String? legacyApplianceConfDirOverride,
  String? legacyApplianceUnitFileOverride,
  MigrationLogFn? log,
}) async {
  final report = LegacyInstallMigrationReport();
  final env = environment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;
  final emit = log ??
      (String m) =>
          developer.log(m, name: 'skotiq.legacy_migration', level: 900);

  // Run a step, folding any failure into a warning. First-launch migration
  // is strictly best-effort — a failed move must never stop the app booting
  // on the new roots.
  Future<void> attempt(String what, Future<void> Function() step) async {
    try {
      await step();
    } catch (e) {
      report.warnings.add('could not $what: $e — left in place');
    }
  }

  // An operator who exported the old env var names should hear once that
  // they stopped doing anything, rather than debug a missing data dir.
  for (final legacyVar in [legacyDataDirEnv, legacyDatabaseDirEnv]) {
    if ((env[legacyVar] ?? '').trim().isNotEmpty) {
      report.warnings.add(
        '$legacyVar is set but is no longer read — the SKOTIQ_* variables '
        'replaced it. Update the launch environment.',
      );
    }
  }

  final relocated = (env[skotiqDataDirEnv] ?? '').trim().isNotEmpty;

  // 1. Move a legacy application-support root into the new one.
  if (!relocated) {
    String? movedFrom;
    for (final candidate in _legacyDataRootCandidates(os, env)) {
      if (!await Directory(candidate).exists()) continue;
      await attempt('move $candidate', () async {
        await _moveOrMerge(candidate, dataRoot, report, emit);
      });
      movedFrom = candidate;
      break;
    }
    for (final candidate in _legacyDataRootCandidates(os, env)) {
      if (candidate != movedFrom && await Directory(candidate).exists()) {
        report.warnings.add(
          'additional legacy data root left at $candidate — merge by hand if '
          'it holds anything the first candidate did not',
        );
      }
    }
  } else {
    for (final candidate in _legacyDataRootCandidates(os, env)) {
      if (await Directory(candidate).exists()) {
        report.warnings.add(
          'legacy data root exists at $candidate but this instance is '
          'relocated by $skotiqDataDirEnv; not merging — point the variable '
          'at it or move it by hand',
        );
      }
    }
    // A relocated root whose basename is `skotiq` is almost always the
    // appliance layout (`/var/lib/skotiq` pinned by headless.env) or a
    // deliberately mirrored custom one. The pre-rename install used the same
    // path under the old product name; fold that sibling in so the pinned
    // database, logs and plugins carry forward. Unprivileged daemons cannot
    // read the old service-owned tree — the failure lands as a warning, not
    // a crash.
    if (p.basename(dataRoot) == skotiqFilePrefix) {
      final sibling = p.join(p.dirname(dataRoot), legacyFilePrefix);
      if (await Directory(sibling).exists()) {
        await attempt('fold $sibling into $dataRoot', () async {
          await _moveOrMerge(sibling, dataRoot, report, emit);
        });
      }
    }
  }

  // 2. Rename inner entries that carried the old name, inside the data root.
  if (await Directory(dataRoot).exists()) {
    await attempt('rename legacy entries under $dataRoot', () async {
      await _renameLegacyEntries(Directory(dataRoot), report, emit);
    });
  }

  // 3. Documents subtree: `Nightshade/` -> `Skotiq/` inside the resolved
  //    documents root. When SKOTIQ_DATA_DIR is set this is
  //    `<dataRoot>/documents` and step 2 already renamed it; the check is
  //    cheap either way.
  if (documentsRoot != null) {
    final legacyDocs = p.join(documentsRoot, legacyProductDirName);
    if (await Directory(legacyDocs).exists()) {
      await attempt('move $legacyDocs', () async {
        await _moveOrMerge(
          legacyDocs,
          p.join(documentsRoot, skotiqProductDirName),
          report,
          emit,
        );
      });
    }
    // Only the app's own subtree is renamed — the documents root is the
    // user's whole Documents folder and must not be walked.
    final skotiqDocs = p.join(documentsRoot, skotiqProductDirName);
    if (await Directory(skotiqDocs).exists()) {
      await attempt('rename legacy entries under $skotiqDocs', () async {
        await _renameLegacyEntries(Directory(skotiqDocs), report, emit);
      });
    }
  }

  // 4. A pinned database directory can sit outside the data root entirely
  //    (the appliance's /var/lib/skotiq/database). Rename `nightshade.db*`
  //    inside it.
  if (databaseDirectory != null && databaseDirectory != dataRoot) {
    final dir = Directory(databaseDirectory);
    if (await dir.exists()) {
      await attempt(
        'rename legacy entries under $databaseDirectory',
        () async {
          await _renameLegacyEntries(dir, report, emit);
        },
      );
    }
  }

  // 5. Platform extras: caches and the macOS preferences plist.
  for (final move in _legacyCacheMoves(os, env)) {
    if (await Directory(move.$1).exists()) {
      await attempt('move ${move.$1}', () async {
        await _moveOrMerge(move.$1, move.$2, report, emit);
      });
    }
  }
  if (os == 'macos') {
    await attempt('migrate macOS preferences', () async {
      await _migrateMacPreferences(env, report, emit);
    });
  }

  // 6. Appliance leftovers. The headless daemon runs as an unprivileged
  // service user, so most of this only succeeds when the process happens to
  // be root (e.g. a manual sudo launch); otherwise the warnings spell out
  // exactly what an operator must run. None of it is fatal.
  if (os == 'linux') {
    final confDir = applianceConfDir ?? skotiqApplianceConfDir;
    final legacyConf =
        legacyApplianceConfDirOverride ?? legacyApplianceConfDir;
    final legacyState =
        legacyApplianceStateDirOverride ?? legacyApplianceStateDir;
    final legacyUnit =
        legacyApplianceUnitFileOverride ?? legacyApplianceUnitFile;
    await attempt('migrate $legacyConf/headless.env', () async {
      await _migrateApplianceEnv(legacyConf, confDir, report);
    });
    if (await File(legacyUnit).exists()) {
      report.warnings.add(
        'pre-rename systemd unit still installed at $legacyUnit — it can '
        'bind the same port on boot. Run: sudo systemctl disable --now '
        '${p.basenameWithoutExtension(legacyUnit)} && sudo rm $legacyUnit',
      );
    }
    if (await Directory(legacyState).exists() &&
        !p.equals(legacyState, dataRoot)) {
      report.warnings.add(
        'pre-rename appliance state remains at $legacyState. Merge it into '
        '$dataRoot (sudo mv + chown) if it holds data this instance did not '
        'already carry.',
      );
    }
  }

  if (report.didWork || report.warnings.isNotEmpty) {
    for (final line in report.actions) {
      emit('[migration] $line');
    }
    for (final line in report.warnings) {
      emit('[migration] WARNING: $line');
    }
  }
  return report;
}

// --- Legacy root discovery ---------------------------------------------------

/// Candidate application-support roots the old product used, in priority
/// order, for [os]. Derived from [env] so tests control the answers.
List<String> _legacyDataRootCandidates(String os, Map<String, String> env) {
  switch (os) {
    case 'linux':
      final dataHome = _xdgDir(env, 'XDG_DATA_HOME', '.local/share');
      if (dataHome == null) return const [];
      return [
        p.join(dataHome, legacyLinuxApplicationId),
        p.join(dataHome, legacyExecutableName),
      ];
    case 'macos':
      final home = env['HOME'];
      if (home == null || home.isEmpty) return const [];
      return [
        p.join(home, 'Library', 'Application Support', legacyMacBundleId),
      ];
    case 'windows':
      final appData = env['APPDATA'];
      if (appData == null || appData.isEmpty) return const [];
      return [
        p.join(appData, legacyWindowsCompanyDir, legacyWindowsProductDir),
      ];
    default:
      return const [];
  }
}

/// (legacyPath -> newPath) pairs for rebuildable-but-cheap-to-carry caches.
List<(String, String)> _legacyCacheMoves(String os, Map<String, String> env) {
  switch (os) {
    case 'linux':
      final cacheHome = _xdgDir(env, 'XDG_CACHE_HOME', '.cache');
      if (cacheHome == null) return const [];
      return [
        (
          p.join(cacheHome, legacyLinuxApplicationId),
          p.join(cacheHome, skotiqLinuxApplicationId),
        ),
        (
          p.join(cacheHome, legacyExecutableName),
          p.join(cacheHome, skotiqFilePrefix),
        ),
      ];
    case 'macos':
      final home = env['HOME'];
      if (home == null || home.isEmpty) return const [];
      return [
        (
          p.join(home, 'Library', 'Caches', legacyMacBundleId),
          p.join(home, 'Library', 'Caches', skotiqMacBundleId),
        ),
      ];
    case 'windows':
      final local = env['LOCALAPPDATA'];
      if (local == null || local.isEmpty) return const [];
      return [
        (
          p.join(local, legacyWindowsCompanyDir, legacyWindowsProductDir),
          // Mirror of Runner.rc: CompanyName `Skotiq`, ProductName `Skotiq`.
          p.join(local, 'Skotiq', 'Skotiq'),
        ),
      ];
    default:
      return const [];
  }
}

String? _xdgDir(Map<String, String> env, String varName, String homeRelative) {
  final direct = env[varName];
  if (direct != null && direct.trim().isNotEmpty) return direct;
  final home = env['HOME'];
  if (home == null || home.isEmpty) return null;
  return p.join(home, homeRelative);
}

/// macOS stores shared_preferences as NSUserDefaults, one plist per bundle
/// id. cfprefsd resolves the domain from the file on first read after a cold
/// start — renaming it here, before any prefs are touched, carries the old
/// install's settings across.
Future<void> _migrateMacPreferences(
  Map<String, String> env,
  LegacyInstallMigrationReport report,
  MigrationLogFn emit,
) async {
  final home = env['HOME'];
  if (home == null || home.isEmpty) return;
  final prefs = p.join(home, 'Library', 'Preferences');
  await _moveOrMerge(
    p.join(prefs, '$legacyMacBundleId.plist'),
    p.join(prefs, '$skotiqMacBundleId.plist'),
    report,
    emit,
  );
}

// --- Appliance (headless systemd) leftovers ----------------------------------

/// Rewrite a pre-rename `headless.env` into its Skotiq equivalent: the
/// `NIGHTSHADE_*` variable names the old unit exported become `SKOTIQ_*`,
/// and the three appliance path prefixes point at the new directories.
/// Pure string transformation — exposed so the translation itself is
/// unit-testable without touching /etc.
String translateLegacyHeadlessEnv(String content) {
  return content
      .replaceAllMapped(
        RegExp(r'^NIGHTSHADE_', multiLine: true),
        (_) => 'SKOTIQ_',
      )
      .replaceAll(legacyApplianceStateDir, skotiqApplianceStateDir)
      .replaceAll(
        legacyApplianceConfDir,
        p.join('/etc', skotiqFilePrefix),
      )
      .replaceAll(
        p.join('/opt', legacyFilePrefix),
        p.join('/opt', skotiqFilePrefix),
      );
}

/// Carry the old appliance's `headless.env` (auth token, port overrides,
/// browse roots) into the new conf dir. The file is mode 0640 root:<old
/// group> on a real install, so an unprivileged daemon can only warn — the
/// warning spells out the exact commands. When this process is root it does
/// the translation itself and leaves the original in place as a backup.
Future<void> _migrateApplianceEnv(
  String legacyConfDir,
  String confDir,
  LegacyInstallMigrationReport report,
) async {
  final src = p.join(legacyConfDir, 'headless.env');
  final dst = p.join(confDir, 'headless.env');
  if (!await File(src).exists()) return;
  if (await File(dst).exists()) {
    report.warnings.add(
      'pre-rename $src exists but $dst already does — merge any custom '
      'values by hand, then remove the old file',
    );
    return;
  }
  try {
    final translated = translateLegacyHeadlessEnv(await File(src).readAsString());
    await Directory(confDir).create(recursive: true);
    await File(dst).writeAsString(translated);
    report.actions.add(
      'translated $src -> $dst (old file left in place; adjust with '
      'sudo chown root:skotiq $dst && sudo chmod 640 $dst)',
    );
  } on FileSystemException catch (e) {
    report.warnings.add(
      'could not migrate $src ($e). Carry the settings across with: '
      "sudo sed -e 's/^NIGHTSHADE_/SKOTIQ_/' "
      '-e s|$legacyApplianceStateDir|$skotiqApplianceStateDir|g '
      '-e s|$legacyApplianceConfDir|${p.join('/etc', skotiqFilePrefix)}|g '
      '-e s|${p.join('/opt', legacyFilePrefix)}|${p.join('/opt', skotiqFilePrefix)}|g '
      '$src | sudo tee $dst >/dev/null && sudo chmod 640 $dst',
    );
  }
}

// --- Move / merge machinery --------------------------------------------------

/// True when [dir] exists and contains no entries.
Future<bool> _isEmptyDir(Directory dir) async {
  if (!await dir.exists()) return false;
  return await dir.list(followLinks: false).isEmpty;
}

/// Move [src] onto [dst]: plain rename when dst is absent (with a
/// copy-verify-delete fallback for cross-device moves); remove an empty dst
/// first; merge non-destructively when dst already holds content.
Future<void> _moveOrMerge(
  String src,
  String dst,
  LegacyInstallMigrationReport report,
  MigrationLogFn emit,
) async {
  if (p.equals(src, dst)) return;
  final srcType = await FileSystemEntity.type(src, followLinks: false);
  if (srcType == FileSystemEntityType.notFound) return;
  if (srcType != FileSystemEntityType.directory) {
    if (await FileSystemEntity.type(dst, followLinks: false) !=
        FileSystemEntityType.notFound) {
      report.warnings.add('kept both: $src and existing $dst');
      return;
    }
    await File(dst).parent.create(recursive: true);
    await File(src).rename(dst);
    report.actions.add('moved $src -> $dst');
    return;
  }

  final srcDir = Directory(src);
  final dstDir = Directory(dst);
  if (await _isEmptyDir(dstDir)) {
    await dstDir.delete();
  }
  if (!await dstDir.exists()) {
    try {
      await srcDir.rename(dst);
      report.actions.add('moved $src -> $dst');
      return;
    } on FileSystemException {
      // Cross-device or locked-entry rename: verified copy, then remove the
      // original only when the copy is provably complete.
      await _copyTree(srcDir, dstDir);
      final (srcFiles, srcBytes) = await _treeStats(srcDir);
      final (dstFiles, dstBytes) = await _treeStats(dstDir);
      if (srcFiles == dstFiles && srcBytes == dstBytes) {
        await srcDir.delete(recursive: true);
        report.actions.add('copied $src -> $dst (verified, original removed)');
      } else {
        report.warnings.add(
          'copy of $src to $dst did not verify ($srcFiles files/$srcBytes B '
          'vs $dstFiles files/$dstBytes B) — original left in place',
        );
      }
      return;
    }
  }

  // dst exists with content: fold src in without overwriting anything.
  await _mergeTree(srcDir, dstDir, report, emit);
  if (await _isEmptyDir(srcDir)) {
    await srcDir.delete();
  }
}

Future<void> _mergeTree(
  Directory src,
  Directory dst,
  LegacyInstallMigrationReport report,
  MigrationLogFn emit,
) async {
  await dst.create(recursive: true);
  // Collect first: renaming while a lazy list() stream is open can skip
  // entries on some platforms.
  final entries = await src.list(followLinks: false).toList();
  for (final entity in entries) {
    final base = p.basename(entity.path);
    final target = p.join(dst.path, base);
    if (entity is Directory) {
      if (await Directory(target).exists()) {
        await _mergeTree(entity, Directory(target), report, emit);
      } else {
        await entity.rename(target);
      }
    } else if (await File(target).exists() ||
        await Directory(target).exists() ||
        await Link(target).exists()) {
      report.warnings.add(
        'kept both: ${entity.path} and existing $target — merge by hand',
      );
    } else {
      try {
        await entity.rename(target);
      } on FileSystemException {
        report.warnings.add(
          'could not move ${entity.path} -> $target; left in place',
        );
      }
    }
  }
  // Drop directories that emptied out during the merge.
  for (final entity in entries) {
    if (entity is Directory && await _isEmptyDir(entity)) {
      await entity.delete();
    }
  }
}

Future<void> _copyTree(Directory src, Directory dst) async {
  await dst.create(recursive: true);
  await for (final entity in src.list(followLinks: false)) {
    final target = p.join(dst.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyTree(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}

Future<(int, int)> _treeStats(Directory dir) async {
  var files = 0;
  var bytes = 0;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      files++;
      bytes += await entity.length();
    }
  }
  return (files, bytes);
}

// --- Inner-name renames ------------------------------------------------------

/// Rename entries under [root] that carry the old product name. Depth-first,
/// children before parents, so a `nightshade.db` inside a `Nightshade/`
/// directory becomes `skotiq.db` inside `Skotiq/` in one pass.
///
/// Rule: every `nightshade` in the basename becomes `skotiq` and every
/// `Nightshade` becomes `Skotiq`, embedded occurrences included, so
/// generated names such as `nightshade-corrupt-<ts>-nightshade.db` land on
/// the same `skotiq-corrupt-<ts>-skotiq.db` a fresh install would produce.
/// Every scanned root is app-owned, so any match is a name this product
/// generated. Replacement is case-sensitive: `NIGHTSHADE_` env-style names
/// do not appear as filenames, and mixed-case user files keep their case.
/// Collisions never overwrite: the incoming file lands as `<target>.legacy`
/// (then `.legacy2`, `.legacy3`, ...) so an install that already produced a
/// `skotiq.db` keeps it and still retains the old file's data.
Future<void> _renameLegacyEntries(
  Directory dir,
  LegacyInstallMigrationReport report,
  MigrationLogFn emit,
) async {
  if (!await dir.exists()) return;
  // Collect first: renaming while a lazy list() stream is open can skip
  // entries on some platforms.
  final entries = await dir.list(followLinks: false).toList();
  for (final entity in entries) {
    if (entity is Directory) {
      // A subtree we cannot read (e.g. the old appliance's service-owned
      // directory seen by the unprivileged daemon) must not abort the rest.
      try {
        await _renameLegacyEntries(entity, report, emit);
      } on FileSystemException catch (e) {
        report.warnings.add(
          'could not scan ${entity.path} for renames: $e',
        );
      }
    }
    final base = p.basename(entity.path);
    final newBase = base
        .replaceAll(legacyFilePrefix, skotiqFilePrefix)
        .replaceAll(legacyProductDirName, skotiqProductDirName);
    if (newBase == base) continue;

    var target = p.join(dir.path, newBase);
    var n = 0;
    while (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      n++;
      target = '${p.join(dir.path, newBase)}.legacy${n > 1 ? '$n' : ''}';
    }
    try {
      await entity.rename(target);
      report.actions.add('renamed ${entity.path} -> $target');
    } on FileSystemException catch (e) {
      report.warnings.add(
        'could not rename ${entity.path} -> $target: $e',
      );
    }
  }
}

// --- Secure-storage namespace ------------------------------------------------

/// Re-key secrets stored under the old product's namespace onto
/// [newNamespace]. Idempotent: a re-run finds no old keys. Never throws —
/// individual failures are logged and the old key is left so the value is
/// not lost.
///
/// [store] is the same triple of operations `flutter_secure_storage`
/// performs. [fields] enumerates the logical keys to carry (the caller owns
/// the list because it owns the field names). The old namespace literal
/// lives here; callers must not spell it themselves.
Future<int> migrateLegacySecretsNamespace(
  Future<String?> Function(String key) read,
  Future<void> Function(String key, String value) write,
  Future<void> Function(String key) delete,
  Iterable<String> fields,
  String newNamespace,
) async {
  var moved = 0;
  for (final field in fields) {
    final oldKey = '$legacySecretsKeyNamespace$field';
    final newKey = '$newNamespace$field';
    try {
      final value = await read(oldKey);
      if (value == null) continue;
      // Never clobber a value already present under the new key.
      if (await read(newKey) == null) {
        await write(newKey, value);
      }
      await delete(oldKey);
      moved++;
    } catch (e) {
      developer.log(
        'legacy secrets re-key $field failed: $e',
        name: 'skotiq.legacy_migration',
        level: 1000,
        error: e,
      );
    }
  }
  return moved;
}

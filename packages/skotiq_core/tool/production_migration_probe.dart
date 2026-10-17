// Developer tool CLI: prints are intentional human-readable status output.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

const _jsonOutputPath =
    '../../docs/production-readiness/manual-migration-probe.json';
const _markdownOutputPath =
    '../../docs/production-readiness/manual-migration-probe.md';

const _requiredDefaultSettings = [
  'theme',
  'auto_connect_equipment',
  'notifications_enabled',
  'science.feature.photometry',
  'science.feature.frame_quality_maps',
  'dark_library.auto_subtract',
  'dark_library.temp_tolerance',
];

void main() {
  test('records manual older-profile migration evidence', () async {
    const defineDatabasePath = String.fromEnvironment('SKOTIQ_OLD_DATABASE');
    const requireArtifact = bool.fromEnvironment('REQUIRE_MIGRATION_ARTIFACT');
    final databaseArg = defineDatabasePath.trim().isNotEmpty
        ? defineDatabasePath
        : Platform.environment['SKOTIQ_OLD_DATABASE'];

    final reportDir = Directory('../../docs/production-readiness');
    await reportDir.create(recursive: true);

    final sourcePath = databaseArg?.trim();
    if (sourcePath == null || sourcePath.isEmpty) {
      await _writeReport(
        const _ProbeReport(
          artifactProvided: false,
          sourcePath: null,
          sourceExists: false,
          qualifiesAsOlderProfile: false,
          migrationVerified: false,
          blocker:
              'No older release-authentic Skotiq database/profile was supplied. Set SKOTIQ_OLD_DATABASE or pass --dart-define=SKOTIQ_OLD_DATABASE=<path>.',
        ),
      );
      print('Manual migration probe complete.');
      print('No older database artifact supplied.');
      print('JSON: $_jsonOutputPath');
      print('Markdown: $_markdownOutputPath');
      if (requireArtifact) {
        fail(
          'No older release-authentic Skotiq database/profile was supplied.',
        );
      }
      return;
    }

    final source = File(sourcePath);
    if (!await source.exists()) {
      await _writeReport(
        _ProbeReport(
          artifactProvided: true,
          sourcePath: _evidencePath(source),
          sourceExists: false,
          qualifiesAsOlderProfile: false,
          migrationVerified: false,
          blocker: 'Supplied database path does not exist.',
        ),
      );
      fail('Supplied database path does not exist: $sourcePath');
    }

    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_manual_migration_',
    );
    final copy = File('${tempDir.path}/skotiq_migration_probe.db');

    try {
      final sourceSizeBytes = await source.length();
      final sourceSha256 = await _sha256(source);
      await source.copy(copy.path);
      final copiedSourceSha256 = await _sha256(copy);
      final copiedSourceSha256Matches =
          sourceSha256 != null && copiedSourceSha256 == sourceSha256;
      final sourceUserVersion = await _readSqliteUserVersion(source);
      final db = SkotiqDatabase.forTesting(NativeDatabase(copy));
      try {
        final finalVersionRow = await db
            .customSelect('PRAGMA user_version')
            .getSingle();
        final finalUserVersion = (finalVersionRow.data['user_version'] as num?)
            ?.toInt();
        final schemaVersion = db.schemaVersion;
        final tableNames = await _sqliteTableNames(db);
        final expectedTables = db.allTables
            .map((table) => table.actualTableName)
            .toSet();
        final expectedTableCount = expectedTables.length;
        final migratedTableCount = tableNames.length;
        final missingTables = expectedTables.difference(tableNames).toList()
          ..sort();
        final settings = await db.settingsDao.getAllSettings();
        final defaultSettingCount = settings.length;
        final missingSettings = _requiredDefaultSettings
            .where((key) => settings[key] == null)
            .toList();
        final qualifiesAsOlderProfile =
            sourceUserVersion != null && sourceUserVersion < schemaVersion;
        final migrationVerified =
            qualifiesAsOlderProfile &&
            finalUserVersion == schemaVersion &&
            missingTables.isEmpty &&
            missingSettings.isEmpty;

        await _writeReport(
          _ProbeReport(
            artifactProvided: true,
            sourcePath: _evidencePath(source),
            sourceExists: true,
            sourceSizeBytes: sourceSizeBytes,
            sourceSha256: sourceSha256,
            copiedPath: _evidencePath(copy),
            copiedSourceSha256: copiedSourceSha256,
            copiedSourceSha256Matches: copiedSourceSha256Matches,
            sourceUserVersion: sourceUserVersion,
            finalUserVersion: finalUserVersion,
            currentSchemaVersion: schemaVersion,
            expectedTableCount: expectedTableCount,
            migratedTableCount: migratedTableCount,
            defaultSettingCount: defaultSettingCount,
            qualifiesAsOlderProfile: qualifiesAsOlderProfile,
            migrationVerified: migrationVerified,
            missingTables: missingTables,
            missingDefaultSettings: missingSettings,
            blocker: migrationVerified
                ? null
                : _migrationBlocker(
                    sourceUserVersion: sourceUserVersion,
                    finalUserVersion: finalUserVersion,
                    schemaVersion: schemaVersion,
                    qualifiesAsOlderProfile: qualifiesAsOlderProfile,
                    missingTables: missingTables,
                    missingSettings: missingSettings,
                  ),
          ),
        );

        print('Manual migration probe complete.');
        print('Source user_version: $sourceUserVersion');
        print('Final user_version: $finalUserVersion');
        print('Current schema version: $schemaVersion');
        print('Older profile artifact: $qualifiesAsOlderProfile');
        print('Migration verified: $migrationVerified');
        print('JSON: $_jsonOutputPath');
        print('Markdown: $_markdownOutputPath');

        if (requireArtifact && !migrationVerified) {
          fail('Supplied database did not satisfy manual migration criteria.');
        }
      } finally {
        await db.close();
      }
    } catch (error, stackTrace) {
      await _writeReport(
        _ProbeReport(
          artifactProvided: true,
          sourcePath: _evidencePath(source),
          sourceExists: true,
          sourceSizeBytes: await source.length(),
          sourceSha256: await _sha256(source),
          qualifiesAsOlderProfile: false,
          migrationVerified: false,
          blocker: 'Migration probe failed: $error',
          error: error.toString(),
          stackTrace: stackTrace.toString(),
        ),
      );
      fail('Manual migration probe failed: $error\n$stackTrace');
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });
}

/// Keeps committed evidence reproducible and avoids recording a maintainer's
/// home-directory path. The content hash remains the artifact identity.
String _evidencePath(File source) {
  final absolute = source.absolute.path.replaceAll('\\', '/');
  final repoRoot = Directory.current.parent.parent.absolute.path.replaceAll(
    '\\',
    '/',
  );
  if (absolute.startsWith('$repoRoot/')) {
    return absolute.substring(repoRoot.length + 1);
  }
  return source.uri.pathSegments.isEmpty
      ? source.path
      : source.uri.pathSegments.last;
}

Future<int?> _readSqliteUserVersion(File file) async {
  final bytes = await file.openRead(0, 64).expand((chunk) => chunk).toList();
  if (bytes.length < 64) return null;
  final header = ascii.decode(bytes.take(16).toList(), allowInvalid: true);
  if (!header.startsWith('SQLite format 3')) return null;
  return (bytes[60] << 24) | (bytes[61] << 16) | (bytes[62] << 8) | bytes[63];
}

Future<String?> _sha256(File file) async {
  final result = Platform.isWindows
      ? await Process.run('certutil', ['-hashfile', file.path, 'SHA256'])
      : await Process.run('sha256sum', [file.path]);
  if (result.exitCode != 0) {
    return null;
  }
  final output = result.stdout.toString();
  final match = RegExp(r'\b[0-9a-fA-F]{64}\b').firstMatch(output);
  return match?.group(0)?.toLowerCase();
}

Future<Set<String>> _sqliteTableNames(SkotiqDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
      .get();
  return rows.map((row) => row.data['name']?.toString() ?? '').toSet();
}

String _migrationBlocker({
  required int? sourceUserVersion,
  required int? finalUserVersion,
  required int schemaVersion,
  required bool qualifiesAsOlderProfile,
  required List<String> missingTables,
  required List<String> missingSettings,
}) {
  if (sourceUserVersion == null) {
    return 'Supplied file was not recognized as a SQLite database with a readable user_version.';
  }
  if (!qualifiesAsOlderProfile) {
    return 'Supplied database is not older than the current schema version.';
  }
  if (finalUserVersion != schemaVersion) {
    return 'Migrated database user_version $finalUserVersion did not match current schema $schemaVersion.';
  }
  if (missingTables.isNotEmpty) {
    return 'Migrated database is missing current tables: ${missingTables.join(', ')}.';
  }
  if (missingSettings.isNotEmpty) {
    return 'Migrated database is missing default settings: ${missingSettings.join(', ')}.';
  }
  return 'Migration did not meet release criteria.';
}

Future<void> _writeReport(_ProbeReport report) async {
  await File(
    _jsonOutputPath,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report.toJson()));
  await File(_markdownOutputPath).writeAsString(report.toMarkdown());
}

class _ProbeReport {
  final bool artifactProvided;
  final String? sourcePath;
  final bool sourceExists;
  final int? sourceSizeBytes;
  final String? sourceSha256;
  final String? copiedPath;
  final String? copiedSourceSha256;
  final bool copiedSourceSha256Matches;
  final int? sourceUserVersion;
  final int? finalUserVersion;
  final int? currentSchemaVersion;
  final int? expectedTableCount;
  final int? migratedTableCount;
  final int? defaultSettingCount;
  final bool qualifiesAsOlderProfile;
  final bool migrationVerified;
  final List<String> missingTables;
  final List<String> missingDefaultSettings;
  final String? blocker;
  final String? error;
  final String? stackTrace;

  const _ProbeReport({
    required this.artifactProvided,
    required this.sourcePath,
    required this.sourceExists,
    this.sourceSizeBytes,
    this.sourceSha256,
    this.copiedPath,
    this.copiedSourceSha256,
    this.copiedSourceSha256Matches = false,
    this.sourceUserVersion,
    this.finalUserVersion,
    this.currentSchemaVersion,
    this.expectedTableCount,
    this.migratedTableCount,
    this.defaultSettingCount,
    required this.qualifiesAsOlderProfile,
    required this.migrationVerified,
    this.missingTables = const [],
    this.missingDefaultSettings = const [],
    this.blocker,
    this.error,
    this.stackTrace,
  });

  Map<String, Object?> toJson() => {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'artifactProvided': artifactProvided,
    'sourcePath': sourcePath,
    'sourceExists': sourceExists,
    'sourceSizeBytes': sourceSizeBytes,
    'sourceSha256': sourceSha256,
    'copiedPath': copiedPath,
    'copiedSourceSha256': copiedSourceSha256,
    'copiedSourceSha256Matches': copiedSourceSha256Matches,
    'sourceUserVersion': sourceUserVersion,
    'finalUserVersion': finalUserVersion,
    'currentSchemaVersion': currentSchemaVersion,
    'expectedTableCount': expectedTableCount,
    'migratedTableCount': migratedTableCount,
    'defaultSettingCount': defaultSettingCount,
    'qualifiesAsOlderProfile': qualifiesAsOlderProfile,
    'migrationVerified': migrationVerified,
    'missingTables': missingTables,
    'missingDefaultSettings': missingDefaultSettings,
    'blocker': blocker,
    'error': error,
    'stackTrace': stackTrace,
    'scope':
        'Manual older-profile migration evidence probe. Synthetic migration tests remain separate.',
  };

  String toMarkdown() {
    final buffer = StringBuffer()
      ..writeln('# Manual Migration Probe')
      ..writeln()
      ..writeln('- Artifact provided: `$artifactProvided`')
      ..writeln('- Source exists: `$sourceExists`')
      ..writeln('- Source path: `${sourcePath ?? 'none'}`')
      ..writeln('- Source size bytes: `${sourceSizeBytes ?? 'unknown'}`')
      ..writeln('- Source SHA256: `${sourceSha256 ?? 'unknown'}`')
      ..writeln('- Copied source SHA256: `${copiedSourceSha256 ?? 'unknown'}`')
      ..writeln('- Copied source SHA256 matches: `$copiedSourceSha256Matches`')
      ..writeln('- Source user_version: `${sourceUserVersion ?? 'unknown'}`')
      ..writeln('- Final user_version: `${finalUserVersion ?? 'unknown'}`')
      ..writeln(
        '- Current schema version: `${currentSchemaVersion ?? 'unknown'}`',
      )
      ..writeln('- Expected table count: `${expectedTableCount ?? 'unknown'}`')
      ..writeln('- Migrated table count: `${migratedTableCount ?? 'unknown'}`')
      ..writeln(
        '- Default setting count: `${defaultSettingCount ?? 'unknown'}`',
      )
      ..writeln('- Older profile artifact: `$qualifiesAsOlderProfile`')
      ..writeln('- Migration verified: `$migrationVerified`')
      ..writeln()
      ..writeln(
        'Scope: this probe validates a supplied older release-authentic SQLite profile/database by migrating a temporary copy. The checked-in v4.3.0 fixture was created by the tagged v4.3.0 database code; synthetic schema tests remain a separate layer.',
      )
      ..writeln();

    if (blocker != null) {
      buffer
        ..writeln('## Blocker')
        ..writeln()
        ..writeln(blocker)
        ..writeln();
    }

    buffer
      ..writeln('## Missing Tables')
      ..writeln()
      ..writeln(missingTables.isEmpty ? 'None.' : missingTables.join('\n'))
      ..writeln()
      ..writeln('## Missing Default Settings')
      ..writeln()
      ..writeln(
        missingDefaultSettings.isEmpty
            ? 'None.'
            : missingDefaultSettings.join('\n'),
      );

    return buffer.toString();
  }
}

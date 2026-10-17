part of '../backup_service.dart';

extension _BackupRestoreValidation on BackupService {
  /// P1 DATA-LOSS GUARD — fully parse and validate a backup payload before
  /// the caller is allowed to touch the live database.
  ///
  /// Validates, in order:
  ///   * the file is valid JSON and decodes to a top-level object;
  ///   * a non-null `version` string is present;
  ///   * each present top-level section has the expected shape
  ///     (`settings` is an object; `equipmentProfiles` / `sequences` /
  ///     `targets` are lists);
  ///   * every profile / target row is an object carrying a non-empty
  ///     `name` (the only NOT NULL column the importer relies on);
  ///   * every sequence entry decodes end-to-end (root + all nodes) — a
  ///     malformed sequence aborts rather than being silently dropped
  ///     into a half-wiped database.
  ///
  /// Throws [_BackupValidationException] (caught by [restoreBackup]) on the
  /// first problem. On success returns a [_ValidatedBackup] holding both the
  /// raw map (for the never-cleared extended tables) and the eagerly-decoded
  /// typed sections so the apply phase never re-parses.
  _ValidatedBackup _validateBackupPayload(String jsonString) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (e) {
      throw _BackupValidationException(
        'Invalid backup file: not valid JSON ($e)',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const _BackupValidationException(
        'Invalid backup file: root is not a JSON object',
      );
    }
    final backup = decoded;

    final version = backup['version'];
    if (version is! String || version.isEmpty) {
      throw const _BackupValidationException(
        'Invalid backup file: missing version',
      );
    }
    final versionMatch = RegExp(r'^(\d+)\.(\d+)$').firstMatch(version);
    if (versionMatch == null) {
      throw _BackupValidationException(
        'Invalid backup file: unsupported version format "$version"',
      );
    }
    final major = int.parse(versionMatch.group(1)!);
    final minor = int.parse(versionMatch.group(2)!);
    final currentParts = BackupService.backupVersion.split('.');
    final currentMajor = int.parse(currentParts[0]);
    final currentMinor = int.parse(currentParts[1]);
    if (major > currentMajor ||
        (major == currentMajor && minor > currentMinor)) {
      throw _BackupValidationException(
        'Backup version $version is newer than supported version '
        '${BackupService.backupVersion}. Update Skotiq before restoring it.',
      );
    }

    // Settings — must be a JSON object when present.
    Map<String, dynamic>? settings;
    if (backup.containsKey('settings')) {
      final raw = backup['settings'];
      if (raw is! Map<String, dynamic>) {
        throw const _BackupValidationException(
          'Invalid backup file: "settings" is not an object',
        );
      }
      settings = raw;
    }

    // Equipment profiles — list of objects each carrying a non-empty name.
    List<Map<String, dynamic>>? profiles;
    if (backup.containsKey('equipmentProfiles')) {
      profiles = _validateNamedRows(
        backup['equipmentProfiles'],
        section: 'equipmentProfiles',
      );
    }

    // Targets — same contract as profiles.
    List<Map<String, dynamic>>? targets;
    if (backup.containsKey('targets')) {
      targets = _validateNamedRows(backup['targets'], section: 'targets');
    }

    // Sequences — must be a list, and every entry must decode fully.
    List<Sequence>? sequences;
    if (backup.containsKey('sequences')) {
      final raw = backup['sequences'];
      if (raw is! List) {
        throw const _BackupValidationException(
          'Invalid backup file: "sequences" is not a list',
        );
      }
      final decodedSequences = <Sequence>[];
      for (var i = 0; i < raw.length; i++) {
        final entry = raw[i];
        if (entry is! Map<String, dynamic>) {
          throw _BackupValidationException(
            'Invalid backup file: sequences[$i] is not an object',
          );
        }
        final sequence = _jsonToSequence(entry);
        if (sequence == null) {
          throw _BackupValidationException(
            'Invalid backup file: sequences[$i] failed to decode '
            '(name: ${entry['name'] ?? '<unknown>'})',
          );
        }
        decodedSequences.add(sequence);
      }
      sequences = decodedSequences;
    }

    return _ValidatedBackup(
      version: version,
      backup: backup,
      settings: settings,
      profiles: profiles,
      targets: targets,
      sequences: sequences,
    );
  }

  /// Shared validator for the profile/target sections: the value must be a
  /// list of JSON objects, each with a non-empty `name` (the importer inserts
  /// that as a NOT NULL column, so a missing name would otherwise blow up
  /// *after* the live DB has already been wiped).
  List<Map<String, dynamic>> _validateNamedRows(
    Object? raw, {
    required String section,
  }) {
    if (raw is! List) {
      throw _BackupValidationException(
        'Invalid backup file: "$section" is not a list',
      );
    }
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! Map<String, dynamic>) {
        throw _BackupValidationException(
          'Invalid backup file: $section[$i] is not an object',
        );
      }
      final name = entry['name'];
      if (name is! String || name.isEmpty) {
        throw _BackupValidationException(
          'Invalid backup file: $section[$i] is missing a non-empty "name"',
        );
      }
      out.add(entry);
    }
    return out;
  }

  Future<void> _clearAllData() async {
    // Clear all tables (except settings if desired)
    await database.delete(database.equipmentProfiles).go();
    await database.delete(database.sequences).go();
    await database.delete(database.sequenceNodes).go();
    await database.delete(database.targets).go();
    // Note: Not clearing imaging_sessions and captured_images to preserve historical data
    _logger.debug('Cleared existing data');
  }
}

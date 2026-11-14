part of '../backup_service.dart';

class BackupResult {
  final bool success;
  final String? filePath;
  final String? errorMessage;
  final DateTime timestamp;
  final int itemsBackedUp;

  const BackupResult({
    required this.success,
    this.filePath,
    this.errorMessage,
    required this.timestamp,
    this.itemsBackedUp = 0,
  });
}

class RestoreResult {
  final bool success;
  final String? errorMessage;
  final DateTime timestamp;
  final int itemsRestored;
  final Map<String, int> categoryCounts;

  /// Backup rows a merge kept out, by table: the database already holds a
  /// different row under the same key, or such a row is the one they belong
  /// to. They stay in the backup file.
  final Map<String, int> notRestored;

  const RestoreResult({
    required this.success,
    this.errorMessage,
    required this.timestamp,
    this.itemsRestored = 0,
    this.categoryCounts = const {},
    this.notRestored = const {},
  });

  /// What a merge kept out and why, for the operator; null when it kept
  /// nothing out.
  String? get notRestoredNotice => restoreNotRestoredNotice(notRestored);
}

/// [RestoreResult.notRestoredNotice] for [notRestored] (table to rows), also
/// for a restore result read from a linked host.
String? restoreNotRestoredNotice(Map<String, int> notRestored) {
  final total = notRestored.values.fold<int>(0, (sum, n) => sum + n);
  if (total == 0) return null;
  final tables = [
    for (final MapEntry(key: table, value: rows) in notRestored.entries)
      '${table.replaceAll('_', ' ')} $rows',
  ].join(', ');
  return '$total backup ${total == 1 ? 'row was' : 'rows were'} not restored '
      '($tables): this database already holds a different record under the '
      'same id, or one is the record they belong to, and a merge never '
      'replaces or re-links your records. They are still in the backup file.';
}

class BackupMetadata {
  final String version;
  final DateTime createdAt;
  final String appVersion;
  final String platform;
  final int settingsCount;
  final int profilesCount;
  final int sequencesCount;
  final int targetsCount;

  const BackupMetadata({
    required this.version,
    required this.createdAt,
    required this.appVersion,
    required this.platform,
    this.settingsCount = 0,
    this.profilesCount = 0,
    this.sequencesCount = 0,
    this.targetsCount = 0,
  });

  factory BackupMetadata.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'] as Map<String, dynamic>?;
    return BackupMetadata(
      version: json['version'] as String? ?? '1.0',
      createdAt: DateTime.parse(json['createdAt'] as String),
      appVersion: json['appVersion'] as String? ?? 'unknown',
      platform: json['platform'] as String? ?? 'unknown',
      settingsCount:
          metadata?['settingsCount'] as int? ??
          json['settingsCount'] as int? ??
          0,
      profilesCount:
          metadata?['profilesCount'] as int? ??
          json['profilesCount'] as int? ??
          0,
      sequencesCount:
          metadata?['sequencesCount'] as int? ??
          json['sequencesCount'] as int? ??
          0,
      targetsCount:
          metadata?['targetsCount'] as int? ??
          json['targetsCount'] as int? ??
          0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'createdAt': createdAt.toIso8601String(),
      'appVersion': appVersion,
      'platform': platform,
      'settingsCount': settingsCount,
      'profilesCount': profilesCount,
      'sequencesCount': sequencesCount,
      'targetsCount': targetsCount,
    };
  }
}

/// Where backups live when no explicit directory is injected: a `backups/`
/// folder beside the database they were taken from.
///
/// WHY resolved from [resolveDefaultDatabaseFile] rather than straight from
/// `resolveSkotiqDocumentsDirectory()`: a bundle only means anything next to
/// the database it snapshotted. Following the configured data directory keeps
/// each install's history its own, so "Recent Backups" cannot list bundles from
/// a database this instance has never seen and offer Restore on one.
///
/// The default (no override) resolves to `<documents>/Skotiq/backups`.
Future<Directory> resolveDefaultBackupDirectory({
  Map<String, String>? environment,
  Future<Directory> Function()? documentsDirectoryProvider,
}) async {
  final databaseFile = await resolveDefaultDatabaseFile(
    environment: environment,
    documentsDirectoryProvider: documentsDirectoryProvider,
  );
  return Directory(path.join(databaseFile.parent.path, 'backups'));
}

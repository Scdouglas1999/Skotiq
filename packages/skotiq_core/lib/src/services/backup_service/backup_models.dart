part of '../backup_service.dart';

/// Result of a backup operation
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

/// Result of a restore operation
class RestoreResult {
  final bool success;
  final String? errorMessage;
  final DateTime timestamp;
  final int itemsRestored;
  final Map<String, int> categoryCounts;

  const RestoreResult({
    required this.success,
    this.errorMessage,
    required this.timestamp,
    this.itemsRestored = 0,
    this.categoryCounts = const {},
  });
}

/// Metadata about a backup file
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

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

/// How a backup is restored.
enum RestoreMode {
  /// Add the records the backup has and this database does not.
  merge,

  /// Make this database the backup.
  replace;

  /// The name on the wire.
  String get wireName => name;

  static RestoreMode fromWire(Object? value) =>
      value == 'replace' ? RestoreMode.replace : RestoreMode.merge;

  /// What this mode does, said to the operator before they confirm.
  String get summary => switch (this) {
    RestoreMode.merge =>
      'Adds the targets, sequences, sessions, frames, masters, library '
          'entries and equipment profiles that are in the backup and not in '
          'this database. Nothing you have is changed or removed: your '
          'settings stay as they are, a record you already have keeps your '
          'version, and nothing is added inside it.',
    RestoreMode.replace =>
      'Makes this database the backup: its settings, profiles, sequences, '
          'targets, sessions and frames replace everything here, and what '
          'was recorded after the backup is no longer in the database. A '
          'safety backup of the database as it is now is written first, and '
          'the switch happens when Skotiq next starts. Image files on disk '
          'are not touched.',
  };
}

/// Why a merge left a backup row out.
enum RestoreLeftOut {
  /// This database has its own version of the record; that one was kept.
  yoursKept('this database has its own version of the record, which was kept'),

  /// The record it belongs to was left out.
  ownerLeftOut('the record they belong to was left out'),

  /// The record it belongs to is not in the backup.
  ownerNotInBackup('the record they belong to is not in the backup'),

  /// It is part of a record this database already has.
  insideYours(
    'they are part of a record this database already has, and a merge adds '
    'nothing inside your records',
  ),

  /// A rule of this database (a unique value) does not allow it.
  conflict('this database has a different record in their place'),

  /// It is data this database builds up from its own sessions.
  yoursOnly(
    'this database has built up its own data of that kind (the sky atlas), '
    'which a merge does not mix with another',
  );

  const RestoreLeftOut(this.reason);

  /// The reason, to follow "N rows were left out because ".
  final String reason;
}

/// Where a restore is, for a progress bar.
class RestoreProgress {
  const RestoreProgress(this.step, this.fraction);

  /// What is being done, in a few words.
  final String step;

  /// How far the whole restore is, 0 to 1.
  final double fraction;

  Map<String, Object?> toJson() => {'step': step, 'fraction': fraction};

  factory RestoreProgress.fromJson(Map<dynamic, dynamic> json) =>
      RestoreProgress(
        json['step'] as String,
        (json['fraction'] as num).toDouble(),
      );
}

class RestoreResult {
  final bool success;
  final String? errorMessage;
  final DateTime timestamp;
  final RestoreMode mode;

  /// Rows written: added by a merge, or in the database a replace built.
  final int itemsRestored;

  /// [itemsRestored] by table (`settings` for the settings of a replace).
  final Map<String, int> categoryCounts;

  /// Backup rows a merge found here already, unchanged.
  final int alreadyHere;

  /// Backup rows a merge left out, by table. They stay in the backup file.
  final Map<String, int> notRestored;

  /// The same rows by reason.
  final Map<RestoreLeftOut, int> leftOut;

  /// A replace is built and waits for the next start to take effect.
  final bool pendingRestart;

  /// The backup of the database as it was, written before a replace.
  final String? safetyBackupPath;

  const RestoreResult({
    required this.success,
    this.errorMessage,
    required this.timestamp,
    this.mode = RestoreMode.merge,
    this.itemsRestored = 0,
    this.categoryCounts = const {},
    this.alreadyHere = 0,
    this.notRestored = const {},
    this.leftOut = const {},
    this.pendingRestart = false,
    this.safetyBackupPath,
  });

  /// What a merge left out and why, for the operator; null when it left
  /// nothing out.
  String? get notRestoredNotice =>
      restoreNotRestoredNotice(notRestored, leftOut);

  /// The whole outcome in words.
  String get report => restoreReport(
    mode: mode,
    itemsRestored: itemsRestored,
    alreadyHere: alreadyHere,
    notRestored: notRestored,
    leftOut: leftOut,
    safetyBackupName: safetyBackupPath == null
        ? null
        : path.basename(safetyBackupPath!),
  );

  /// The outcome as the host sends it to a linked client.
  Map<String, Object?> toWire() => {
    'mode': mode.wireName,
    'itemsRestored': itemsRestored,
    'categoryCounts': categoryCounts,
    'alreadyHere': alreadyHere,
    'notRestored': notRestored,
    'leftOut': {for (final e in leftOut.entries) e.key.name: e.value},
    'pendingRestart': pendingRestart,
    if (safetyBackupPath != null)
      'safetyBackup': path.basename(safetyBackupPath!),
    'timestamp': timestamp.millisecondsSinceEpoch,
  };
}

/// [RestoreResult.report] for an outcome read off the wire
/// ([RestoreResult.toWire]).
String restoreReportFromWire(Map<String, dynamic> body) {
  Map<String, int> counts(Object? raw) => {
    if (raw is Map)
      for (final MapEntry(:key, :value) in raw.entries)
        if (key is String && value is int) key: value,
  };
  final reasons = counts(body['leftOut']);
  return restoreReport(
    mode: RestoreMode.fromWire(body['mode']),
    itemsRestored: body['itemsRestored'] as int,
    alreadyHere: body['alreadyHere'] as int,
    notRestored: counts(body['notRestored']),
    leftOut: {
      for (final reason in RestoreLeftOut.values)
        if (reasons[reason.name] case final n?) reason: n,
    },
    safetyBackupName: body['safetyBackup'] as String?,
  );
}

/// What a restore did, in words: one rule for the window and a linked client.
String restoreReport({
  required RestoreMode mode,
  required int itemsRestored,
  required int alreadyHere,
  required Map<String, int> notRestored,
  required Map<RestoreLeftOut, int> leftOut,
  String? safetyBackupName,
}) {
  String rows(int n) => '$n ${n == 1 ? 'row' : 'rows'}';
  if (mode == RestoreMode.replace) {
    return 'The backup (${rows(itemsRestored)}) is ready to replace this '
        'database, and takes its place when Skotiq next starts. Until then '
        'this database is in use, and what is recorded in it from now on is '
        'not kept.'
        '${safetyBackupName == null ? '' : ' The database as it is now is saved as $safetyBackupName.'}';
  }
  return [
    'Added ${rows(itemsRestored)} from the backup.',
    if (alreadyHere > 0)
      '${rows(alreadyHere)} ${alreadyHere == 1 ? 'was' : 'were'} here already.',
    'Your settings were not changed.',
    ?restoreNotRestoredNotice(notRestored, leftOut),
  ].join(' ');
}

/// What a merge left out ([notRestored]: table to rows) and why ([leftOut]);
/// null when it left nothing out.
String? restoreNotRestoredNotice(
  Map<String, int> notRestored,
  Map<RestoreLeftOut, int> leftOut,
) {
  final total = notRestored.values.fold<int>(0, (sum, n) => sum + n);
  if (total == 0) return null;
  final tables = [
    for (final MapEntry(key: table, value: rows) in notRestored.entries)
      '${table.replaceAll('_', ' ')} $rows',
  ].join(', ');
  final reasons = [
    for (final MapEntry(key: reason, value: rows) in leftOut.entries)
      '$rows because ${reason.reason}',
  ].join('; ');
  return '$total backup ${total == 1 ? 'row was' : 'rows were'} left out '
      '($tables): $reasons. '
      '${total == 1 ? 'It is' : 'They are'} still in the backup file.';
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

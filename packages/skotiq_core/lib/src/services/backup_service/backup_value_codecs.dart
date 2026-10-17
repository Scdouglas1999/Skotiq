part of '../backup_service.dart';

String? _stringOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  return value.toString();
}

double? _doubleOrNull(Object? value) {
  return (value as num?)?.toDouble();
}

double _doubleOrDefault(Object? value, double fallback) {
  return (value as num?)?.toDouble() ?? fallback;
}

int? _intOrNull(Object? value) {
  return (value as num?)?.toInt();
}

int _intOrDefault(Object? value, int fallback) {
  return (value as num?)?.toInt() ?? fallback;
}

Value<DateTime> _dateTimeValue(Object? value) {
  if (value is DateTime) return Value(value);
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return Value(parsed);
  }
  return const Value.absent();
}

/// Raised by [BackupService._validateBackupPayload] when a backup file is
/// structurally invalid. Caught inside [BackupService.restoreBackup] and
/// turned into a non-destructive failure result so live data is never wiped
/// for a corrupt payload.
class _BackupValidationException implements Exception {
  final String message;
  const _BackupValidationException(this.message);

  @override
  String toString() => 'BackupValidationException: $message';
}

/// Fully-validated, eagerly-decoded backup payload produced by
/// [BackupService._validateBackupPayload]. Holds the raw map (consumed by the
/// never-cleared extended-table importers) alongside the typed sections so the
/// apply phase never re-parses what validation already proved sound.
class _ValidatedBackup {
  final String version;
  final Map<String, dynamic> backup;
  final Map<String, dynamic>? settings;
  final List<Map<String, dynamic>>? profiles;
  final List<Map<String, dynamic>>? targets;
  final List<Sequence>? sequences;

  const _ValidatedBackup({
    required this.version,
    required this.backup,
    required this.settings,
    required this.profiles,
    required this.targets,
    required this.sequences,
  });
}

/// Adapts an [IOSink] to the `Sink<List<int>>` that
/// [JsonUtf8Encoder.startChunkedConversion] writes its blocks into. Closing is
/// the archive writer's job (it must flush first), so `close` is a no-op here.
class _IOSinkBytes implements Sink<List<int>> {
  _IOSinkBytes(this._sink);

  final IOSink _sink;

  @override
  void add(List<int> data) => _sink.add(data);

  @override
  void close() {}
}

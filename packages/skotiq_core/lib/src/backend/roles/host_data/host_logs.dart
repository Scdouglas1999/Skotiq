import 'package:skotiq_core/skotiq_core.dart';

/// The log entries and log files of a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostLogs {
  Future<void> clearServerLogs();

  Future<void> downloadServerLogFile(
    String fileName,
    String localPath, {
    void Function(double)? onProgress,
  });

  Future<List<LogEntry>> fetchRecentServerLogs({
    int limit = 200,
    String? severityMin,
    String? categoryFilter,
  });

  Future<List<RemoteLogFileInfo>> listServerLogFiles();
}

import 'dart:convert';
import 'dart:io';

/// Run configuration written by run-science.sh.
class SandboxConfig {
  SandboxConfig({
    required this.dbDir,
    required this.dataDir,
    required this.outDir,
    required this.sessionName,
    required this.frames,
    required this.astapPath,
    required this.astapDbDir,
    this.rigDb,
    this.movingObjects = false,
    this.differential,
    this.settingOverrides = const {},
    this.keepFrames = false,
    this.keepRecent = 6,
    this.foldWaitSeconds = 180,
    this.settleMs = 400,
    this.skipDone = false,
  });

  final String dbDir;
  final String dataDir;
  final String outDir;
  final String sessionName;
  final List<String> frames;
  final String astapPath;
  final String astapDbDir;
  final String? rigDb;
  final bool movingObjects;
  final Map<String, dynamic>? differential;
  final Map<String, String> settingOverrides;
  final bool keepFrames;
  final int keepRecent;
  final int foldWaitSeconds;
  final int settleMs;
  final bool skipDone;

  static SandboxConfig load(String path) {
    final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    Map<String, dynamic>? diff;
    final diffPath = j['differential'] as String?;
    if (diffPath != null && diffPath.isNotEmpty) {
      diff =
          jsonDecode(File(diffPath).readAsStringSync()) as Map<String, dynamic>;
    }
    return SandboxConfig(
      dbDir: j['dbDir'] as String,
      dataDir: j['dataDir'] as String,
      outDir: j['outDir'] as String,
      sessionName: j['sessionName'] as String,
      frames: (j['frames'] as List).cast<String>(),
      astapPath: j['astapPath'] as String,
      astapDbDir: j['astapDbDir'] as String,
      rigDb: (j['rigDb'] as String?)?.isEmpty ?? true
          ? null
          : j['rigDb'] as String,
      movingObjects: j['movingObjects'] as bool? ?? false,
      differential: diff,
      settingOverrides: ((j['settings'] as Map?) ?? const {}).map(
        (k, v) => MapEntry('$k', '$v'),
      ),
      keepFrames: j['keepFrames'] as bool? ?? false,
      keepRecent: j['keepRecent'] as int? ?? 6,
      foldWaitSeconds: j['foldWaitSeconds'] as int? ?? 180,
      settleMs: j['settleMs'] as int? ?? 400,
      skipDone: j['skipDone'] as bool? ?? false,
    );
  }
}

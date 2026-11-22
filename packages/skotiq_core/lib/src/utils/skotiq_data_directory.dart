import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Environment variable that relocates this process's writable data root.
///
/// Set by headless/systemd units and by any second instance that must not
/// share state with the desktop GUI. It is read here only: the desktop host
/// hands the resolved root to the native side at start-up (`api_init_host`).
const String skotiqDataDirEnv = 'SKOTIQ_DATA_DIR';

/// Subdirectory of [skotiqDataDirEnv] that stands in for the platform
/// documents folder when the operator has relocated this instance.
///
/// Kept separate from the data root itself so an operator inspecting the
/// directory can still tell app-private state (`logs/`, `catalogs/`,
/// `sky_atlas/`) from the user-facing output the app writes on request
/// (`documents/Skotiq/exports`, `.../reports`).
const String skotiqRelocatedDocumentsDirName = 'documents';

Map<String, String>? _capturedProcessEnvironment;

/// The environment the directory resolvers read: [Platform.environment],
/// unless a test replaced it with [captureSkotiqProcessEnvironment].
Map<String, String> get skotiqProcessEnvironment =>
    _capturedProcessEnvironment ?? Platform.environment;

/// Makes [environment] the one the directory resolvers read, for tests that
/// relocate the whole process. The first call wins until
/// [debugResetSkotiqProcessEnvironment].
void captureSkotiqProcessEnvironment([Map<String, String>? environment]) {
  _capturedProcessEnvironment ??= Map<String, String>.unmodifiable(
    environment ?? Platform.environment,
  );
}

/// Drops the environment set by [captureSkotiqProcessEnvironment].
void debugResetSkotiqProcessEnvironment() {
  _capturedProcessEnvironment = null;
}

String? _dataDirOverride(Map<String, String>? environment) {
  final value = (environment ?? skotiqProcessEnvironment)[skotiqDataDirEnv]
      ?.trim();
  if (value == null || value.isEmpty) return null;
  return value;
}

Future<Directory> _ensure(String path) =>
    Directory(path).create(recursive: true);

/// Directory this process keeps its writable application state under —
/// catalogs, caches, checkpoints, logs, staged updates, the remote-access
/// token and the push secret.
///
/// This is the single resolver for what `path_provider` calls the
/// application-support directory. [skotiqDataDirEnv] wins over the
/// platform folder because that folder is per-application, not per-instance:
/// a headless daemon running beside the GUI — the configuration
/// `main_headless` documents — would otherwise resolve the same log directory
/// as the GUI and the two would interleave into one rolling log file. The
/// same reasoning applies to every other store under that root, which is why
/// direct `getApplicationSupportDirectory()` calls are no longer allowed
/// outside this file (see `skotiq_core/test/utils/
/// path_provider_call_site_sweep_test.dart`).
///
/// With the variable unset the result is exactly `path_provider`'s answer, so
/// an existing install keeps its data where it already is.
Future<Directory> resolveSkotiqDataDirectory({
  Map<String, String>? environment,
  Future<Directory> Function()? applicationSupportDirectoryProvider,
}) async {
  final override = _dataDirOverride(environment);
  if (override != null) {
    // path_provider creates the platform folder before handing it back;
    // callers that only ever saw that behaviour would break on a relocated
    // root that does not exist yet.
    return _ensure(override);
  }
  return (applicationSupportDirectoryProvider ??
      getApplicationSupportDirectory)();
}

/// Directory this process writes user-facing documents into — exports,
/// reports, and the default location of `skotiq.db` when no database
/// directory is configured.
///
/// With [skotiqDataDirEnv] set the root moves under it (see
/// [skotiqRelocatedDocumentsDirName]) so a relocated instance does not
/// write into the machine-wide `~/Documents/Skotiq`. With it unset the
/// result is exactly `path_provider`'s answer.
Future<Directory> resolveSkotiqDocumentsDirectory({
  Map<String, String>? environment,
  Future<Directory> Function()? documentsDirectoryProvider,
}) async {
  final override = _dataDirOverride(environment);
  if (override != null) {
    return _ensure(p.join(override, skotiqRelocatedDocumentsDirName));
  }
  return (documentsDirectoryProvider ?? getApplicationDocumentsDirectory)();
}

/// Where exports land when no save dialog chooses a place (a phone's share
/// sheet, an automatic report): `Skotiq/exports` in the documents folder,
/// created if absent.
Future<Directory> resolveSkotiqExportsDirectory({
  Future<Directory> Function() documents = resolveSkotiqDocumentsDirectory,
}) async => _ensure(p.join((await documents()).path, 'Skotiq', 'exports'));

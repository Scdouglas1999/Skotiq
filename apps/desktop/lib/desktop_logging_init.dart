import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;

/// Pre-Riverpod boot artifacts captured during early initialisation so they
/// can be reused later by Riverpod-aware services without round-tripping
/// through `path_provider` a second time.
class DesktopBootPaths {
  final String logDirectory;
  final String profileDirectory;
  final String dataDirectory;

  const DesktopBootPaths({
    required this.logDirectory,
    required this.profileDirectory,
    required this.dataDirectory,
  });
}

/// Sets `SKOTIQ_DATA_DIR` for the current process before Rust reads it.
///
/// Respects a value already supplied by the parent shell or systemd unit.
/// The path matches [resolveSkotiqDataDirectory] — the same root used for
/// logs, catalogs and tokens — so defect maps and other native persistence
/// align with the Dart side of the same process.
void configureSkotiqDataDirectory(
  String dataDirectory, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  // Freeze the PROCESS environment as the operator supplied it, before this
  // function writes its own answer back into it. Without the snapshot the Dart
  // resolvers would later read a SKOTIQ_DATA_DIR this function invented
  // and conclude the instance had been relocated — which would move the
  // documents root off `~/Documents` on an ordinary install. The snapshot is
  // taken from `Platform.environment`, never from an injected [environment],
  // so a test's fake map cannot become the process-wide answer.
  captureSkotiqProcessEnvironment();
  final existing = env[skotiqDataDirEnv]?.trim();
  if (existing != null && existing.isNotEmpty) {
    return;
  }
  _setProcessEnvironment(skotiqDataDirEnv, dataDirectory);
}

/// Resolves the directory that owns this instance's native profile, settings
/// and plate-solver JSON.
///
/// The native store holds the observer site the sequencer, the planetarium and
/// `GET /api/settings/location` all read, so it follows the same
/// operator-configured data directory as `skotiq.db` and `pairing.db` —
/// [skotiqDatabaseDirEnv]. It did not: it resolved straight to
/// `<platform documents>/Skotiq/profiles`, so an instance
/// pinned to its own database still read and rewrote the machine-wide file.
/// One process then answered `GET /api/settings` with the scratch database's
/// 0,0 and `GET /api/settings/location` with another install's real site,
/// and every scratch or harness run mutated the operator's own settings.
///
/// With no override the path is unchanged, so an existing install keeps its
/// profiles exactly where they are.
Future<String> resolveDesktopProfileDirectory({
  Map<String, String>? environment,
  Future<Directory> Function()? documentsDirectoryProvider,
}) async {
  // [skotiqProcessEnvironment], not `Platform.environment`: by the time a
  // caller reaches here [configureSkotiqDataDirectory] has published this
  // process's data root back into the environment for Rust, and reading that
  // back would move an ordinary install's native profile store.
  final env = environment ?? skotiqProcessEnvironment;
  final overrideDir = env[skotiqDatabaseDirEnv]?.trim();
  if (overrideDir != null && overrideDir.isNotEmpty) {
    return path.join(overrideDir, 'profiles');
  }

  final appDir = await resolveSkotiqDocumentsDirectory(
    environment: env,
    documentsDirectoryProvider: documentsDirectoryProvider,
  );
  return path.join(appDir.path, 'Skotiq', 'profiles');
}

/// Resolves and creates this instance's log directory, publishing the same
/// root to `SKOTIQ_DATA_DIR` for the Rust side.
///
/// Separate from [initialiseDesktopLogging] so the path decision is reachable
/// without the native bridge: everything after this point in the bootstrap
/// requires a loadable `libskotiq_bridge`.
///
/// The log directory follows the operator's data root rather than the platform
/// support folder. It did not once: the log directory was hard-coded to the
/// support folder while only Rust's persistence honoured the env var, so every
/// instance on the machine appended to one shared `skotiq.log`, and a
/// diagnostic dump carried other instances' capture paths, target names and
/// host names to whoever received the bug report.
Future<({String dataRoot, String logDirectory})> prepareDesktopLogDirectory({
  Map<String, String>? environment,
  Future<Directory> Function()? applicationSupportDirectory,
}) async {
  final env = environment ?? Platform.environment;
  final dataRoot = (await resolveSkotiqDataDirectory(
    environment: env,
    applicationSupportDirectoryProvider: applicationSupportDirectory,
  )).path;
  configureSkotiqDataDirectory(dataRoot, environment: env);

  final logDir = path.join(dataRoot, 'logs');
  await Directory(logDir).create(recursive: true);
  return (dataRoot: dataRoot, logDirectory: logDir);
}

/// Product version from the built app's pubspec (`version` + build number).
Future<AppVersionInfo> loadDesktopAppVersion() async {
  final packageInfo = await PackageInfo.fromPlatform();
  final buildNumber = int.tryParse(packageInfo.buildNumber);
  if (buildNumber == null) {
    throw StateError(
      'Invalid build number in PackageInfo: ${packageInfo.buildNumber}',
    );
  }
  return AppVersionInfo(version: packageInfo.version, buildNumber: buildNumber);
}

/// Initialise the Rust bridge with this instance's log directory, then wire
/// native profile + settings storage onto [resolveDesktopProfileDirectory].
/// Returns the resolved paths so the rest of the bootstrap can hand them to
/// the `LoggingService` and `ProfileService` without re-querying
/// [resolveSkotiqDataDirectory].
///
/// This step must run before any provider that touches the Rust runtime
/// (every backend method goes through `bridge.NativeBridge`), so it lives
/// outside the Riverpod container.
Future<DesktopBootPaths> initialiseDesktopLogging() async {
  final (dataRoot: dataRoot, logDirectory: logDir) =
      await prepareDesktopLogDirectory();

  // Ensure libraw.dll and other deps next to skotiq_bridge.dll resolve when
  // the process working directory is not the Release folder (e.g. shortcuts).
  configureWindowsNativeDllSearchPath();

  await bridge.NativeBridge.init(logDirectory: logDir);
  if (!bridge.NativeBridge.isNativeAvailable) {
    // Name the CURRENT platform's library and layout, so the hint points at a
    // path that exists on the operator's machine.
    final (libName, bundleHint) = switch (Platform.operatingSystem) {
      'windows' => (
        'skotiq_bridge.dll (plus libraw.dll)',
        r'build\windows\x64\runner\Release\skotiq_desktop.exe with the DLLs beside it',
      ),
      'macos' => (
        'libskotiq_bridge.dylib',
        'build/macos/Build/Products/Release/skotiq_desktop.app with the dylib in Frameworks/',
      ),
      _ => (
        'libskotiq_bridge.so',
        'build/linux/x64/release/bundle/skotiq_desktop with the .so in that bundle\'s lib/ directory',
      ),
    };
    throw StateError(
      'Native bridge failed to initialize: $libName could not be loaded, or it '
      'is stale relative to this build. Run '
      '$bundleHint. '
      'After changing the Rust API run `flutter_rust_bridge_codegen generate`, '
      'rebuild the bridge, and copy the fresh library into the bundle — a '
      'bridge library older than the Dart build fails here with no other '
      'symptom. Check the console for "[Bridge] RustLib initialization failed".',
    );
  }

  final profileDir = await resolveDesktopProfileDirectory();
  await Directory(profileDir).create(recursive: true);
  await bridge.NativeBridge.apiInitProfileStorage(storagePath: profileDir);
  await bridge.NativeBridge.apiInitSettingsStorage(storagePath: profileDir);

  return DesktopBootPaths(
    logDirectory: logDir,
    profileDirectory: profileDir,
    // The root actually in use, so the headless banner names the directory
    // this process is really reading and writing.
    dataDirectory: dataRoot,
  );
}

/// Adds the executable directory to the Windows DLL search path so
/// `skotiq_bridge.dll` can resolve `libraw.dll` and MSVC runtimes staged
/// beside the desktop exe.
void configureWindowsNativeDllSearchPath() {
  if (!Platform.isWindows) return;

  final exeDir = path.dirname(Platform.resolvedExecutable);
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDirectory = kernel32
      .lookupFunction<
        Int32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('SetDllDirectoryW');
  final dirPtr = exeDir.toNativeUtf16();
  try {
    final result = setDllDirectory(dirPtr);
    if (result == 0) {
      throw StateError(
        'SetDllDirectoryW failed for native DLL search path: $exeDir',
      );
    }
  } finally {
    malloc.free(dirPtr);
  }
}

void _setProcessEnvironment(String name, String value) {
  if (Platform.isWindows) {
    _setWindowsEnvironment(name, value);
    return;
  }
  _setPosixEnvironment(name, value);
}

void _setPosixEnvironment(String name, String value) {
  final setenv = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, int)
      >('setenv');
  final namePtr = name.toNativeUtf8();
  final valuePtr = value.toNativeUtf8();
  try {
    final result = setenv(namePtr, valuePtr, 1);
    if (result != 0) {
      throw StateError('setenv($name) failed (code $result)');
    }
  } finally {
    malloc.free(namePtr);
    malloc.free(valuePtr);
  }
}

void _setWindowsEnvironment(String name, String value) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setEnvironmentVariable = kernel32
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
        int Function(Pointer<Utf16>, Pointer<Utf16>)
      >('SetEnvironmentVariableW');
  final namePtr = name.toNativeUtf16();
  final valuePtr = value.toNativeUtf16();
  try {
    final result = setEnvironmentVariable(namePtr, valuePtr);
    if (result == 0) {
      throw StateError('SetEnvironmentVariableW($name) failed');
    }
  } finally {
    malloc.free(namePtr);
    malloc.free(valuePtr);
  }
}

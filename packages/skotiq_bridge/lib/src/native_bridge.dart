/// The native library runtime: finds and loads `skotiq_bridge`, and guards
/// calls into it.
///
/// Rust is the only device path. Without the library there is nothing to fall
/// back to, so guarded operations refuse by name instead of reporting fake
/// data. Use INDI/ASCOM/Alpaca simulators for testing.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:path/path.dart' as path;

import 'api_barrel.dart' as gen_api;
import 'frb_generated.dart' as frb;

const _nativeMissingErrorMessage = '''
Native bridge not available.

Possible causes:
1. Native library failed to load - check build output
2. Running on unsupported platform (web)
3. DLL/dylib not found in expected location

For development: Use INDI/ASCOM/Alpaca simulators. There is no Dart-side device
implementation and no built-in simulator, so this operation fails closed rather
than reporting fake data.
''';

abstract final class NativeBridge {
  static bool _initialized = false;
  static bool _nativeAvailable = false;

  static bool get isNativeAvailable => _nativeAvailable;

  /// Loads the native library and initializes the Rust side. Safe to call
  /// more than once. A failed load leaves [isNativeAvailable] false.
  static Future<void> init({String? logDirectory}) async {
    if (_initialized) return;

    final libraryPath = await _findNativeLibrary();

    // FRB's default loader looks in a dev-tree relative path that does not
    // exist next to a packaged executable, so pass the path we found.
    try {
      if (libraryPath != null) {
        await frb.RustLib.init(
          externalLibrary: ExternalLibrary.open(libraryPath),
        );
      } else {
        await frb.RustLib.init();
      }

      if (logDirectory != null) {
        gen_api.apiInitWithLogging(logDirectory: logDirectory);
      } else {
        gen_api.apiInit();
      }

      final version = gen_api.apiGetVersion();
      _log('Native bridge v$version ready', level: 800);
      _nativeAvailable = true;
    } catch (e) {
      _log('RustLib initialization failed: $e', level: 1000);
      _nativeAvailable = false;
    }

    _initialized = true;

    if (!_nativeAvailable) {
      // Warning level: the app keeps running, but every hardware operation
      // will refuse, and operators must be able to spot that in logs.
      _log(
        'Native bridge unavailable; hardware operations will fail closed',
        level: 900,
      );
    }
  }

  /// Runs [call] against the native library.
  ///
  /// Refuses with an [UnsupportedError] naming [operation] when the library is
  /// not loaded. A failure inside [call] is logged and rethrown unchanged.
  static Future<T> run<T>(String operation, FutureOr<T> Function() call) async {
    requireNative(operation);
    try {
      return await call();
    } catch (e) {
      _log('Error in $operation: $e', level: 1000);
      rethrow;
    }
  }

  /// Throws the refusal [run] throws when the native library is not loaded.
  static void requireNative(String operation) {
    if (_nativeAvailable) return;
    throw UnsupportedError(
      'Operation "$operation" requires the native bridge.\n$_nativeMissingErrorMessage',
    );
  }

  static void _log(String message, {required int level}) {
    developer.log('[Bridge] $message', name: 'NativeBridge', level: level);
  }

  static Future<String?> _findNativeLibrary() async {
    try {
      final String libName;
      if (Platform.isWindows) {
        libName = 'skotiq_bridge.dll';
      } else if (Platform.isLinux) {
        libName = 'libskotiq_bridge.so';
      } else if (Platform.isMacOS) {
        libName = 'libskotiq_bridge.dylib';
      } else {
        return null;
      }

      final exeDir = path.dirname(Platform.resolvedExecutable);
      String devTree(String base, List<String> up, List<String> tail) =>
          path.joinAll([base, ...up, 'native', 'skotiq_native', ...tail]);
      const up3 = ['..', '..', '..'];

      final candidates = <String>[];
      if (Platform.isWindows) {
        candidates.addAll([
          path.join(exeDir, libName),
          path.join(exeDir, '..', libName),
          path.join(exeDir, '..', '..', libName),
          path.join(exeDir, 'data', 'flutter_assets', libName),
          devTree(exeDir, up3, ['bridge', 'target', 'release', libName]),
          devTree(exeDir, up3, ['target', 'release', libName]),
          devTree(exeDir, up3, ['bridge', 'target', 'debug', libName]),
          devTree(exeDir, up3, ['target', 'debug', libName]),
        ]);
        try {
          final cwd = Directory.current.path;
          candidates.addAll([
            devTree(cwd, const [], ['bridge', 'target', 'release', libName]),
            devTree(cwd, const [], ['target', 'release', libName]),
            devTree(
              cwd,
              const ['..'],
              ['bridge', 'target', 'release', libName],
            ),
            devTree(
              cwd,
              const ['..', '..'],
              ['bridge', 'target', 'release', libName],
            ),
          ]);
        } on FileSystemException {
          // The working directory was deleted under the process; the
          // executable-relative candidates above still apply.
        }
      } else if (Platform.isLinux) {
        candidates.addAll([
          path.join(exeDir, 'lib', libName),
          path.join(exeDir, '..', 'lib', libName),
          path.join(exeDir, libName),
          devTree(exeDir, up3, ['target', 'release', libName]),
          devTree(exeDir, up3, ['target', 'debug', libName]),
          '/usr/local/lib/$libName',
        ]);
      } else {
        candidates.addAll([
          path.join(exeDir, '..', 'Frameworks', libName),
          path.join(exeDir, 'Frameworks', libName),
          path.join(exeDir, libName),
          devTree(exeDir, up3, ['target', 'release', libName]),
          devTree(exeDir, up3, ['target', 'debug', libName]),
        ]);
      }

      for (final candidate in candidates) {
        if (!await File(candidate).exists()) continue;
        try {
          DynamicLibrary.open(candidate);
          return path.normalize(candidate);
        } catch (e) {
          _log('Failed to load native library at $candidate: $e', level: 900);
        }
      }

      _log(
        'Native library not found. Native-only operations will fail closed.',
        level: 900,
      );
      return null;
    } catch (e) {
      _log('Error loading native library: $e', level: 1000);
      return null;
    }
  }
}

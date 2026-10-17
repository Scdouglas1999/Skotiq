part of '../bridge_stub.dart';

extension _NativeBridgeRuntimeOperations on _NativeBridgeImplementation {
  // Initialization

  /// Initialize the native bridge
  Future<void> init({String? logDirectory}) async {
    if (_initialized) return;

    // Try to load native library manually (for fallback path)
    await _tryLoadNativeLibrary();

    // FRB defaults to a dev-tree relative path (see kDefaultExternalLibraryLoaderConfig)
    // which does not exist next to a packaged Release exe. When we found the DLL
    // beside the executable, pass that path explicitly.
    try {
      if (_loadedNativeLibraryPath != null) {
        await frb.RustLib.init(
          externalLibrary: ExternalLibrary.open(_loadedNativeLibraryPath!),
        );
      } else {
        await frb.RustLib.init();
      }

      // Initialize the native bridge API
      if (logDirectory != null) {
        gen_api.apiInitWithLogging(logDirectory: logDirectory);
      } else {
        gen_api.apiInit();
      }

      // Verify it's working
      final version = gen_api.apiGetVersion();
      developer.log(
        '[Bridge] Native bridge v$version ready',
        name: 'NativeBridge',
        level: 800,
      );

      // Mark as available for native discovery
      _nativeAvailable = true;
    } catch (e) {
      developer.log(
        '[Bridge] RustLib initialization failed: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      // Mark as unavailable since RustLib couldn't initialize
      _nativeAvailable = false;
    }

    _initialized = true;

    // Emit initialization event
    _eventController.add(
      _FallbackSkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.system,
        eventType: 'Initialized',
        data: {'nativeAvailable': _nativeAvailable},
      ),
    );

    if (_nativeAvailable) {
      developer.log(
        '[Bridge] Loaded native library',
        name: 'NativeBridge',
        level: 800,
      );
    } else {
      // Why: warning-level â€” running without native bridge means hardware
      // operations will fail closed, which is a degraded-but-running state
      // operators must be able to spot in logs.
      developer.log(
        '[Bridge] Native bridge unavailable; running in fail-closed fallback mode',
        name: 'NativeBridge',
        level: 900,
      );
    }
  }

  /// Try to load the native library
  Future<bool> _tryLoadNativeLibrary() async {
    try {
      // Determine library name based on platform
      String libName;
      if (Platform.isWindows) {
        libName = 'skotiq_bridge.dll';
      } else if (Platform.isLinux) {
        libName = 'libskotiq_bridge.so';
      } else if (Platform.isMacOS) {
        libName = 'libskotiq_bridge.dylib';
      } else {
        // Unsupported platform
        return false;
      }

      // Get the executable directory
      final executablePath = Platform.resolvedExecutable;
      final executableDir = path.dirname(executablePath);

      // Try to find the native library in common locations
      final possiblePaths = <String>[];

      if (Platform.isWindows) {
        // Windows: library should be next to executable or in data directory
        possiblePaths.addAll([
          // First, check next to the executable (most common location)
          path.join(executableDir, libName),
          // Check parent directories (for release builds)
          path.join(executableDir, '..', libName),
          path.join(executableDir, '..', '..', libName),
          // Check in data directory
          path.join(executableDir, 'data', 'flutter_assets', libName),
          // Check if we can find the project root by looking for common markers
          // Try to find native/skotiq_native from executable location
          path.join(
            executableDir,
            '..',
            '..',
            '..',
            'native',
            'skotiq_native',
            'bridge',
            'target',
            'release',
            libName,
          ),
          path.join(
            executableDir,
            '..',
            '..',
            '..',
            'native',
            'skotiq_native',
            'target',
            'release',
            libName,
          ),
          path.join(
            executableDir,
            '..',
            '..',
            '..',
            'native',
            'skotiq_native',
            'bridge',
            'target',
            'debug',
            libName,
          ),
          path.join(
            executableDir,
            '..',
            '..',
            '..',
            'native',
            'skotiq_native',
            'target',
            'debug',
            libName,
          ),
          // Check if executable is in a Release/Debug folder
          path.join(
            executableDir,
            '..',
            '..',
            '..',
            'native',
            'skotiq_native',
            'bridge',
            'target',
            'release',
            libName,
          ),
        ]);

        // Also try to find project root from current working directory
        try {
          final cwd = Directory.current.path;
          possiblePaths.addAll([
            path.join(
              cwd,
              'native',
              'skotiq_native',
              'bridge',
              'target',
              'release',
              libName,
            ),
            path.join(
              cwd,
              'native',
              'skotiq_native',
              'target',
              'release',
              libName,
            ),
            path.join(
              cwd,
              '..',
              'native',
              'skotiq_native',
              'bridge',
              'target',
              'release',
              libName,
            ),
            path.join(
              cwd,
              '..',
              '..',
              'native',
              'skotiq_native',
              'bridge',
              'target',
              'release',
              libName,
            ),
          ]);
        } catch (e) {
          // Ignore errors getting current directory
        }
      } else if (Platform.isLinux) {
        // Linux: library should be in lib/ directory relative to executable
        possiblePaths.addAll([
          path.join(executableDir, 'lib', libName),
          path.join(executableDir, '..', 'lib', libName),
          path.join(executableDir, libName),
          // Development build location
          path.join(
            executableDir,
            '..',
            '..',
            '..',
            'native',
            'skotiq_native',
            'target',
            'release',
            libName,
          ),
          path.join(
            executableDir,
            '..',
            '..',
            '..',
            'native',
            'skotiq_native',
            'target',
            'debug',
            libName,
          ),
          // System library path
          '/usr/local/lib/$libName',
        ]);
      } else if (Platform.isMacOS) {
        // macOS: library should be in Frameworks directory of app bundle
        possiblePaths.addAll([
          path.join(executableDir, '..', 'Frameworks', libName),
          path.join(executableDir, 'Frameworks', libName),
          path.join(executableDir, libName),
          // Development build location
          path.join(
            executableDir,
            '..',
            '..',
            '..',
            'native',
            'skotiq_native',
            'target',
            'release',
            libName,
          ),
          path.join(
            executableDir,
            '..',
            '..',
            '..',
            'native',
            'skotiq_native',
            'target',
            'debug',
            libName,
          ),
        ]);
      }

      // Try to load the library from each possible path
      for (final libPath in possiblePaths) {
        try {
          final file = File(libPath);
          if (await file.exists()) {
            try {
              _nativeLib = DynamicLibrary.open(libPath);
              _loadedNativeLibraryPath = path.normalize(libPath);
              return true;
            } catch (e) {
              developer.log(
                '[Bridge] Failed to load native library at $libPath: $e',
                name: 'NativeBridge',
                level: 900,
              );
            }
          }
        } catch (e) {
          // Continue trying other paths
        }
      }

      _loadedNativeLibraryPath = null;
      _nativeLib = null;

      // Why: warning-level â€” same fail-closed signal as the init path; this
      // is the dlopen-side failure when the library couldn't be located on
      // any search path.
      developer.log(
        '[Bridge] Native library not found. Native-only operations will fail closed.',
        name: 'NativeBridge',
        level: 900,
      );
      return false;
    } catch (e) {
      developer.log(
        '[Bridge] Error loading native library: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      return false;
    }
  }

  /// Check if native library is available
  bool get isNativeAvailable => _nativeAvailable;

  /// Invalidate the discovery cache so the next call runs full discovery.
  /// Call this when the user explicitly requests a refresh, or after
  /// connecting/disconnecting a device.
  void invalidateDiscoveryCache() {
    _discoveryCache.clear();
    _discoveryCacheTime = null;
  }

  // Event stream

  /// Stream of events from the native side
  Stream<SkotiqEvent> eventStream() {
    // If native is available, use the real event stream from Rust
    if (_nativeAvailable) {
      try {
        return gen_api.apiEventStream();
      } catch (e) {
        developer.log(
          '[Bridge] Failed to get native event stream: $e',
          name: 'NativeBridge',
          level: 1000,
        );
      }
    }

    // Fallback to local event controller for simulator mode
    // Convert internal fallback events to proper SkotiqEvent format
    var fallbackEventId = BigInt.zero;
    return _eventController.stream.map((fallbackEvent) {
      fallbackEventId += BigInt.one;
      return gen_event.SkotiqEvent(
        eventId: fallbackEventId,
        timestamp: fallbackEvent.timestamp,
        severity: fallbackEvent.severity,
        category: fallbackEvent.category,
        payload: gen_event.EventPayload.system(
          gen_event.SystemEvent.notification(
            title: fallbackEvent.eventType,
            message: fallbackEvent.data.toString(),
            level: fallbackEvent.severity.name,
          ),
        ),
      );
    });
  }
}

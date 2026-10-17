import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as path;
import 'plugin_api.dart';

/// Implementation of PluginLogger that writes to console and developer log
class ConsolePluginLogger implements PluginLogger {
  final String _pluginId;

  /// Creates a console logger for a plugin
  ConsolePluginLogger(this._pluginId);

  @override
  void info(String message) {
    developer.log(message, name: 'Plugin.$_pluginId', level: 800);
  }

  @override
  void debug(String message) {
    developer.log(message, name: 'Plugin.$_pluginId', level: 500);
  }

  @override
  void warning(String message) {
    developer.log(message, name: 'Plugin.$_pluginId', level: 900);
  }

  @override
  void error(String message, [Object? error, StackTrace? stackTrace]) {
    developer.log(
      message,
      name: 'Plugin.$_pluginId',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// In-memory implementation of PluginStorage
///
/// In a production app, this should be backed by SharedPreferences,
/// SQLite, or another persistent storage mechanism.
class InMemoryPluginStorage implements PluginStorage {
  final Map<String, dynamic> _storage = {};

  @override
  Future<String?> getString(String key) async {
    final value = _storage[key];
    return value is String ? value : null;
  }

  @override
  Future<void> setString(String key, String value) async {
    _storage[key] = value;
  }

  @override
  Future<int?> getInt(String key) async {
    final value = _storage[key];
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  @override
  Future<void> setInt(String key, int value) async {
    _storage[key] = value;
  }

  @override
  Future<bool?> getBool(String key) async {
    final value = _storage[key];
    if (value is bool) return value;
    if (value is String) {
      if (value.toLowerCase() == 'true') return true;
      if (value.toLowerCase() == 'false') return false;
    }
    return null;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    _storage[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _storage.remove(key);
  }

  @override
  Future<Map<String, dynamic>> getAll() async {
    return Map.from(_storage);
  }

  @override
  Future<void> clear() async {
    _storage.clear();
  }
}

/// Validates that [pluginId] is safe to use as a filesystem path segment.
///
/// Plugin ids are reverse-domain identifiers (e.g. `com.example.thing`) that
/// are used verbatim as storage filenames (`<id>.json`). This rejects anything
/// that could escape the plugin storage directory — path separators (`/`,
/// `\`), `..` traversal segments, an empty id, or characters outside the safe
/// `[A-Za-z0-9._-]` set — so a hostile or malformed id can never read or write
/// outside `<appSupport>/skotiq_plugins/storage/`. Throws a
/// [PluginException] describing the violation; callers must reject the plugin.
void assertSafePluginId(String pluginId) {
  final ok =
      pluginId.isNotEmpty &&
      pluginId.length <= 200 &&
      !pluginId.contains('..') &&
      _safePluginIdPattern.hasMatch(pluginId);
  if (!ok) {
    throw PluginException(
      'Unsafe plugin id "$pluginId": ids must be 1-200 chars matching '
      '[A-Za-z0-9._-], start with an alphanumeric, and contain no ".." '
      'path segment.',
    );
  }
}

final RegExp _safePluginIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

/// File-backed implementation of [PluginStorage].
///
/// Data is stored per-plugin in the application support directory and written
/// atomically so plugin settings survive app restarts and partial writes.
///
/// All mutating operations are serialized through a single write queue, so two
/// concurrent writes never race on the temp file (each write also uses a
/// unique temp name) — without this, overlapping `setString`/`clear`/etc. calls
/// could lose data or throw when the second rename found the shared temp file
/// already consumed by the first.
class FilePluginStorage implements PluginStorage {
  final String _pluginId;
  final Future<Directory> Function() _baseDirectoryProvider;

  /// One queue per canonical storage path, shared by every storage instance.
  /// Registration retries create a fresh context/storage object; a per-instance
  /// queue would still let the old and new contexts delete/rename each other's
  /// files or overwrite unrelated keys.
  static final Map<String, Future<void>> _fileTails = {};

  /// Monotonic counter feeding a per-write temp filename.
  static int _tempCounter = 0;

  /// Creates persistent storage for [pluginId].
  ///
  /// [baseDirectoryProvider] is primarily intended for tests. The [pluginId]
  /// is validated up front ([assertSafePluginId]) so an unsafe id never
  /// reaches the filesystem.
  FilePluginStorage(
    this._pluginId, {
    Future<Directory> Function()? baseDirectoryProvider,
  }) : _baseDirectoryProvider =
           baseDirectoryProvider ?? _defaultPluginStorageDirectory {
    assertSafePluginId(_pluginId);
  }

  Future<File> _getStorageFile() async {
    final baseDir = await _baseDirectoryProvider();
    final pluginsDir = Directory(
      path.join(baseDir.path, 'skotiq_plugins', 'storage'),
    );
    if (!await pluginsDir.exists()) {
      await pluginsDir.create(recursive: true);
    }
    return File(path.join(pluginsDir.path, '$_pluginId.json'));
  }

  Future<Map<String, dynamic>> _readStorage(File file) async {
    if (!await file.exists()) {
      return <String, dynamic>{};
    }

    try {
      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        return <String, dynamic>{};
      }
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      } else {
        throw const FormatException('Plugin storage root must be an object');
      }
    } catch (e, stackTrace) {
      developer.log(
        'Failed to load plugin storage for $_pluginId, resetting storage',
        name: 'Plugin.$_pluginId',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      return <String, dynamic>{};
    }
  }

  Future<T> _withFileLock<T>(Future<T> Function(File file) action) async {
    final file = await _getStorageFile();
    final key = file.absolute.path;
    final previous = _fileTails[key] ?? Future<void>.value();
    final operation = previous.then((_) => action(file));
    final tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _fileTails[key] = tail;
    try {
      return await operation;
    } finally {
      if (identical(_fileTails[key], tail)) {
        unawaited(_fileTails.remove(key));
      }
    }
  }

  Future<void> _mutate(void Function(Map<String, dynamic> values) change) {
    return _withFileLock((file) async {
      // Always merge against the latest durable snapshot. This is what keeps
      // two contexts for the same plugin from losing one another's keys.
      final values = await _readStorage(file);
      change(values);
      await _writeSnapshot(file, jsonEncode(values));
    });
  }

  Future<T> _read<T>(T Function(Map<String, dynamic> values) select) {
    return _withFileLock((file) async {
      final values = await _readStorage(file);
      return select(values);
    });
  }

  Future<void> _writeSnapshot(File file, String encoded) async {
    // Unique temp name per write so even two FilePluginStorage instances for
    // the same id (overlapping lifecycles) never share an in-progress temp
    // file.
    final tempFile = File('${file.path}.${_tempCounter++}.tmp');
    try {
      await tempFile.writeAsString(encoded, flush: true);
      try {
        // POSIX rename replaces atomically, preserving the old snapshot until
        // the complete new one is ready.
        await tempFile.rename(file.path);
      } on FileSystemException {
        // Windows does not replace an existing destination via rename.
        if (await file.exists()) await file.delete();
        await tempFile.rename(file.path);
      }
    } finally {
      // Never leave an orphan temp behind if we threw before the rename
      // consumed it. After a successful rename the temp path no longer exists,
      // so this is a no-op on the happy path.
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (e) {
          // The real write error (if any) already propagated; this only
          // reports the orphan left behind, which would otherwise accumulate
          // in the plugin storage directory with nothing explaining it.
          developer.log(
            'Could not remove plugin storage temp file ${tempFile.path}: $e',
            name: 'PluginStorage',
            level: 900,
          );
        }
      }
    }
  }

  @override
  Future<String?> getString(String key) =>
      _read((values) => values[key] is String ? values[key] as String : null);

  @override
  Future<void> setString(String key, String value) =>
      _mutate((values) => values[key] = value);

  @override
  Future<int?> getInt(String key) => _read((values) {
    final value = values[key];
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  });

  @override
  Future<void> setInt(String key, int value) =>
      _mutate((values) => values[key] = value);

  @override
  Future<bool?> getBool(String key) => _read((values) {
    final value = values[key];
    if (value is bool) return value;
    if (value is String) {
      if (value.toLowerCase() == 'true') return true;
      if (value.toLowerCase() == 'false') return false;
    }
    return null;
  });

  @override
  Future<void> setBool(String key, bool value) =>
      _mutate((values) => values[key] = value);

  @override
  Future<void> remove(String key) => _mutate((values) => values.remove(key));

  @override
  Future<Map<String, dynamic>> getAll() =>
      _read((values) => Map<String, dynamic>.from(values));

  @override
  Future<void> clear() => _mutate((values) => values.clear());
}

Future<Directory> _defaultPluginStorageDirectory() async {
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;

  if (Platform.isWindows) {
    final appData =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        path.join(home, 'AppData', 'Local');
    return Directory(path.join(appData, 'Skotiq'));
  }

  if (Platform.isMacOS) {
    return Directory(
      path.join(home, 'Library', 'Application Support', 'Skotiq'),
    );
  }

  final xdgDataHome =
      Platform.environment['XDG_DATA_HOME'] ??
      path.join(home, '.local', 'share');
  return Directory(path.join(xdgDataHome, 'skotiq'));
}

/// Stream-based implementation of PluginEventBus
class StreamPluginEventBus implements PluginEventBus {
  final _controller = StreamController<PluginEvent>.broadcast();
  final Map<String, StreamController<Map<String, dynamic>>> _namedControllers =
      {};
  bool _disposed = false;

  @override
  void emit(String eventName, [Map<String, dynamic>? data]) {
    if (_disposed || _controller.isClosed) {
      return;
    }
    final event = PluginEvent(name: eventName, data: data ?? {});

    // Emit to general stream
    _controller.add(event);

    // Emit to named stream if it exists
    final namedController = _namedControllers[eventName];
    if (namedController != null && !namedController.isClosed) {
      namedController.add(event.data);
    }
  }

  @override
  Stream<Map<String, dynamic>> on(String eventName) {
    if (_disposed) {
      return Stream.error(
        StateError('Plugin event bus has been disposed and cannot be reused'),
      );
    }
    final controller = _namedControllers.putIfAbsent(
      eventName,
      () => StreamController<Map<String, dynamic>>.broadcast(),
    );
    return controller.stream;
  }

  @override
  Stream<PluginEvent> onAny() {
    return _controller.stream;
  }

  /// Dispose of all stream controllers
  void dispose() {
    _disposed = true;
    _controller.close();
    for (final controller in _namedControllers.values) {
      controller.close();
    }
    _namedControllers.clear();
  }
}

/// Resource limits enforced for plugin-provided event access.
class PluginSandboxPolicy {
  final int maxEventPayloadBytes;
  final int maxNamedSubscriptions;
  final bool allowGlobalSubscriptions;

  const PluginSandboxPolicy({
    this.maxEventPayloadBytes = 16 * 1024,
    this.maxNamedSubscriptions = 32,
    this.allowGlobalSubscriptions = false,
  });
}

/// Event bus wrapper that applies basic sandboxing limits per plugin.
class SandboxedPluginEventBus implements PluginEventBus {
  final String _pluginId;
  final PluginEventBus _inner;
  final PluginSandboxPolicy _policy;
  int _subscriptionCount = 0;

  SandboxedPluginEventBus(
    this._pluginId,
    this._inner, {
    PluginSandboxPolicy policy = const PluginSandboxPolicy(),
  }) : _policy = policy;

  @override
  void emit(String eventName, [Map<String, dynamic>? data]) {
    _validateEventName(eventName);
    final payload = data ?? const <String, dynamic>{};
    final encoded = jsonEncode(payload);
    if (encoded.length > _policy.maxEventPayloadBytes) {
      throw PluginException(
        'Plugin $_pluginId emitted an event payload larger than '
        '${_policy.maxEventPayloadBytes} bytes',
      );
    }
    _inner.emit(eventName, payload);
  }

  @override
  Stream<Map<String, dynamic>> on(String eventName) {
    _validateEventName(eventName);
    _subscriptionCount++;
    if (_subscriptionCount > _policy.maxNamedSubscriptions) {
      throw PluginException(
        'Plugin $_pluginId exceeded the event subscription limit '
        '(${_policy.maxNamedSubscriptions})',
      );
    }
    return _inner.on(eventName);
  }

  @override
  Stream<PluginEvent> onAny() {
    if (!_policy.allowGlobalSubscriptions) {
      throw PluginException(
        'Plugin $_pluginId is not permitted to subscribe to the global event bus',
      );
    }
    return _inner.onAny();
  }

  void _validateEventName(String eventName) {
    if (eventName.trim().isEmpty) {
      throw PluginException(
        'Plugin $_pluginId emitted or subscribed to an empty event name',
      );
    }
    if (eventName.length > 128) {
      throw PluginException(
        'Plugin $_pluginId used an event name longer than 128 characters',
      );
    }
  }
}

/// Factory for creating plugin contexts
class PluginContextFactory {
  final StreamPluginEventBus _eventBus = StreamPluginEventBus();
  final PluginSandboxPolicy _policy;
  final PluginStorage Function(String pluginId) _storageFactory;

  /// Creates a factory.
  ///
  /// [storageFactory] builds the [PluginStorage] for each plugin context.
  /// Defaults to [FilePluginStorage] (the production store, persisted under the
  /// app-support directory). Tests inject [InMemoryPluginStorage] here so the
  /// plugin lifecycle (`onLoad`/`onEnable`, which read persisted config) does
  /// not block on `path_provider` — a platform channel that never answers under
  /// the widget-test binding, which would otherwise hang the test indefinitely.
  PluginContextFactory({
    PluginSandboxPolicy policy = const PluginSandboxPolicy(),
    PluginStorage Function(String pluginId)? storageFactory,
  }) : _policy = policy,
       _storageFactory =
           storageFactory ?? ((pluginId) => FilePluginStorage(pluginId));

  /// Create a context for a specific plugin
  PluginContext createContext(String pluginId) {
    return PluginContext(
      logger: ConsolePluginLogger(pluginId),
      storage: _storageFactory(pluginId),
      eventBus: SandboxedPluginEventBus(pluginId, _eventBus, policy: _policy),
    );
  }

  /// Dispose of shared resources
  void dispose() {
    _eventBus.dispose();
  }
}

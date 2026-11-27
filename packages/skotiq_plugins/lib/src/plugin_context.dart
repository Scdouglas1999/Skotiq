import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'plugin_api.dart';

final _pluginStorageLog = Logger('skotiq.PluginStorage');

/// The [PluginLogger] a plugin gets unless the app supplies its own: records
/// go to `package:logging` as `skotiq.Plugin.<id>`, which the app log
/// receives.
class ConsolePluginLogger implements PluginLogger {
  final Logger _log;

  ConsolePluginLogger(String pluginId) : _log = _pluginLogger(pluginId);

  @override
  void info(String message) => _log.info(message);

  @override
  void debug(String message) => _log.fine(message);

  @override
  void warning(String message) => _log.warning(message);

  @override
  void error(String message, [Object? error, StackTrace? stackTrace]) =>
      _log.severe(message, error, stackTrace);
}

/// `package:logging` names are dot-separated paths and refuse an empty part,
/// so an id such as `''` or `a..b` is reduced to its non-empty parts.
Logger _pluginLogger(String pluginId) {
  final parts = pluginId.split('.').where((part) => part.isNotEmpty);
  return Logger('skotiq.${['Plugin', ...parts].join('.')}');
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
  final Future<Directory> Function()? _legacyBaseDirectoryProvider;
  bool _legacyChecked = false;

  /// One queue per canonical storage path, shared by every storage instance.
  /// Registration retries create a fresh context/storage object; a per-instance
  /// queue would still let the old and new contexts delete/rename each other's
  /// files or overwrite unrelated keys.
  static final Map<String, Future<void>> _fileTails = {};

  /// Monotonic counter feeding a per-write temp filename.
  static int _tempCounter = 0;

  /// Creates persistent storage for [pluginId] under
  /// `<base>/skotiq_plugins/storage/<pluginId>.json`.
  ///
  /// [baseDirectoryProvider] gives the data root; the app passes its own
  /// (see `resolveSkotiqDataDirectory` in skotiq_core). Without one the file
  /// lives under [legacyPluginStorageDirectory].
  ///
  /// When [legacyBaseDirectoryProvider] is given and this plugin has no file
  /// under the data root yet, the file found under the legacy root is copied
  /// in once. The copy leaves the legacy file in place, so every instance
  /// that shared it still finds its settings whichever starts first.
  ///
  /// The [pluginId] is validated up front ([assertSafePluginId]) so an unsafe
  /// id never reaches the filesystem.
  FilePluginStorage(
    this._pluginId, {
    Future<Directory> Function()? baseDirectoryProvider,
    Future<Directory> Function()? legacyBaseDirectoryProvider,
  }) : _baseDirectoryProvider =
           baseDirectoryProvider ?? legacyPluginStorageDirectory,
       _legacyBaseDirectoryProvider = legacyBaseDirectoryProvider {
    assertSafePluginId(_pluginId);
  }

  Future<File> _getStorageFile() async {
    final baseDir = await _baseDirectoryProvider();
    final pluginsDir = Directory(_storageDirIn(baseDir));
    if (!await pluginsDir.exists()) {
      await pluginsDir.create(recursive: true);
    }
    return File(path.join(pluginsDir.path, '$_pluginId.json'));
  }

  static String _storageDirIn(Directory base) =>
      path.join(base.path, 'skotiq_plugins', 'storage');

  /// Copies the legacy file in when [file] does not exist yet. A legacy root
  /// that is the data root itself finds [file] present and copies nothing.
  Future<void> _adoptLegacyFile(File file) async {
    final legacyProvider = _legacyBaseDirectoryProvider;
    if (_legacyChecked || legacyProvider == null) return;
    _legacyChecked = true;
    if (await file.exists()) return;
    final legacy = File(
      path.join(_storageDirIn(await legacyProvider()), '$_pluginId.json'),
    );
    try {
      if (!await legacy.exists()) return;
      await _writeSnapshot(file, await legacy.readAsString());
      _pluginStorageLog.info(
        'Copied plugin storage for $_pluginId from ${legacy.path}',
      );
    } on FileSystemException catch (e) {
      _pluginStorageLog.warning(
        'Could not copy plugin storage for $_pluginId from ${legacy.path}: $e',
      );
    }
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
      _pluginLogger(_pluginId).severe(
        'Failed to load plugin storage for $_pluginId, resetting storage',
        e,
        stackTrace,
      );
      return <String, dynamic>{};
    }
  }

  Future<T> _withFileLock<T>(Future<T> Function(File file) action) async {
    final file = await _getStorageFile();
    final key = file.absolute.path;
    final previous = _fileTails[key] ?? Future<void>.value();
    final operation = previous.then((_) async {
      await _adoptLegacyFile(file);
      return action(file);
    });
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
          _pluginStorageLog.warning(
            'Could not remove plugin storage temp file ${tempFile.path}: $e',
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

/// The data root plugin storage used before the app supplied its own:
/// `%LOCALAPPDATA%\Skotiq`, `~/Library/Application Support/Skotiq` or
/// `$XDG_DATA_HOME/skotiq`. The app reads it only to carry existing plugin
/// files over to its data root.
Future<Directory> legacyPluginStorageDirectory() async {
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

    _controller.add(event);

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
    if (_subscriptionCount >= _policy.maxNamedSubscriptions) {
      throw PluginException(
        'Plugin $_pluginId exceeded the event subscription limit '
        '(${_policy.maxNamedSubscriptions})',
      );
    }
    _subscriptionCount++;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      if (_subscriptionCount > 0) _subscriptionCount--;
    }

    StreamSubscription<Map<String, dynamic>>? sub;
    late final StreamController<Map<String, dynamic>> controller;
    // Broadcast, matching [StreamPluginEventBus.on]: plugins listen to one
    // returned stream from more than one place. A single-subscription
    // controller throws on the second listen.
    controller = StreamController<Map<String, dynamic>>.broadcast(
      onListen: () {
        sub = _inner
            .on(eventName)
            .listen(
              controller.add,
              onError: controller.addError,
              onDone: () {
                release();
                if (!controller.isClosed) {
                  unawaited(controller.close());
                }
              },
            );
      },
      onCancel: () async {
        release();
        await sub?.cancel();
      },
    );
    return controller.stream;
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

class PluginContextFactory {
  final StreamPluginEventBus _eventBus = StreamPluginEventBus();
  final PluginSandboxPolicy _policy;
  final PluginStorage Function(String pluginId) _storageFactory;
  final PluginLogger Function(String pluginId) _loggerFactory;

  /// Creates a factory.
  ///
  /// [storageFactory] builds the [PluginStorage] for each plugin context.
  /// The app passes a [FilePluginStorage] under its data root; the default is
  /// a [FilePluginStorage] under [legacyPluginStorageDirectory]. Tests inject
  /// [InMemoryPluginStorage] so nothing touches the disk.
  ///
  /// [loggerFactory] builds each plugin's [PluginLogger]; it defaults to
  /// [ConsolePluginLogger], whose records reach the app log.
  PluginContextFactory({
    PluginSandboxPolicy policy = const PluginSandboxPolicy(),
    PluginStorage Function(String pluginId)? storageFactory,
    PluginLogger Function(String pluginId)? loggerFactory,
  }) : _policy = policy,
       _storageFactory =
           storageFactory ?? ((pluginId) => FilePluginStorage(pluginId)),
       _loggerFactory = loggerFactory ?? ConsolePluginLogger.new;

  /// Publishes [eventName] from the app to every plugin listening on the
  /// shared bus ("weather.updated", "focuser.moved").
  void publish(String eventName, Map<String, dynamic> data) =>
      _eventBus.emit(eventName, data);

  PluginContext createContext(String pluginId) {
    return PluginContext(
      logger: _loggerFactory(pluginId),
      storage: _storageFactory(pluginId),
      eventBus: SandboxedPluginEventBus(pluginId, _eventBus, policy: _policy),
    );
  }

  void dispose() {
    _eventBus.dispose();
  }
}

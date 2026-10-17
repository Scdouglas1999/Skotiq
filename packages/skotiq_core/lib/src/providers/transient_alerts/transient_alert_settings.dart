part of '../transient_alert_provider.dart';

/// Storage key prefix for transient alert settings in the database
const String _settingsKeyPrefix = 'transient_alert_';

/// Notifier for managing transient alert settings with persistence.
///
/// Settings are persisted to the app settings database and loaded on startup.
/// Changes are immediately saved to ensure settings survive app restarts.
class TransientAlertSettingsNotifier
    extends StateNotifier<TransientAlertSettings> {
  final SettingsDao _settingsDao;
  final LoggingService _logger;
  final NetworkBackend? _remote;
  bool _initialized = false;
  Completer<void>? _loadCompleter;
  TransientAlertSettings _confirmedSettings =
      TransientAlertSettings.defaultSettings;
  TransientAlertSettings _requestedSettings =
      TransientAlertSettings.defaultSettings;
  int _requestRevision = 0;
  Future<void> _writeTail = Future<void>.value();
  Future<void> _requestedWrite = Future<void>.value();

  TransientAlertSettingsNotifier({
    required SettingsDao settingsDao,
    required LoggingService logger,
    NetworkBackend? remote,
  }) : _settingsDao = settingsDao,
       _logger = logger,
       _remote = remote,
       super(TransientAlertSettings.defaultSettings) {
    unawaited(_loadSettings());
  }

  /// Resolves after the local database or remote host has supplied the
  /// authoritative initial snapshot. Headless handlers await this so a request
  /// arriving during startup never observes and writes over temporary defaults.
  Future<void> get loaded {
    if (_initialized) return Future<void>.value();
    _loadCompleter ??= Completer<void>();
    return _loadCompleter!.future;
  }

  Set<TransientSource>? _parseSources(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = json.decode(raw);
      if (decoded is! List) return null;
      final parsed = <TransientSource>{};
      for (final item in decoded) {
        if (item is! String) continue;
        for (final source in TransientSource.values) {
          if (source.name == item) {
            parsed.add(source);
            break;
          }
        }
      }
      return parsed;
    } catch (_) {
      return null;
    }
  }

  Set<TransientType>? _parseTypes(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = json.decode(raw);
      if (decoded is! List) return null;
      final parsed = <TransientType>{};
      for (final item in decoded) {
        if (item is! String) continue;
        for (final type in TransientType.values) {
          if (type.name == item) {
            parsed.add(type);
            break;
          }
        }
      }
      return parsed;
    } catch (_) {
      return null;
    }
  }

  double _parseFiniteDouble(String? raw, double fallback) {
    final value = raw == null ? null : double.tryParse(raw);
    return value != null && value.isFinite ? value : fallback;
  }

  bool _parseBool(String? raw, bool fallback) {
    return switch (raw?.trim().toLowerCase()) {
      'true' => true,
      'false' => false,
      _ => fallback,
    };
  }

  /// Load settings from persistent storage
  Future<void> _loadSettings() async {
    if (_initialized) return;
    final revisionAtStart = _requestRevision;

    try {
      final remote = _remote;
      final allSettings = remote == null
          ? await _settingsDao.getAllSettings()
          : _remoteSettingsAsStored(await remote.getTransientSettings());

      // Parse enabled sources
      final sourcesJson = allSettings['${_settingsKeyPrefix}enabled_sources'];
      final enabledSources =
          _parseSources(sourcesJson) ??
          TransientAlertSettings.defaultSettings.enabledSources;

      // Parse types to monitor
      final typesJson = allSettings['${_settingsKeyPrefix}types_to_monitor'];
      final typesToMonitor =
          _parseTypes(typesJson) ??
          TransientAlertSettings.defaultSettings.typesToMonitor;

      // Parse numeric and boolean settings
      final magnitudeThreshold = _parseFiniteDouble(
        allSettings['${_settingsKeyPrefix}magnitude_threshold'],
        TransientAlertSettings.defaultSettings.magnitudeThreshold,
      );

      final notifyOnNew = _parseBool(
        allSettings['${_settingsKeyPrefix}notify_on_new'],
        TransientAlertSettings.defaultSettings.notifyOnNew,
      );

      final autoQueueBright = _parseBool(
        allSettings['${_settingsKeyPrefix}auto_queue_bright'],
        TransientAlertSettings.defaultSettings.autoQueueBright,
      );

      final autoQueueMagnitude = _parseFiniteDouble(
        allSettings['${_settingsKeyPrefix}auto_queue_magnitude'],
        TransientAlertSettings.defaultSettings.autoQueueMagnitude,
      );

      final loaded = TransientAlertSettings(
        enabledSources: enabledSources,
        magnitudeThreshold: magnitudeThreshold,
        typesToMonitor: typesToMonitor,
        notifyOnNew: notifyOnNew,
        autoQueueBright: autoQueueBright,
        autoQueueMagnitude: autoQueueMagnitude,
      );
      if (mounted && revisionAtStart == _requestRevision) {
        _confirmedSettings = loaded;
        _requestedSettings = loaded;
        state = loaded;
      }

      _logger.debug(
        'Transient alert settings loaded: ${enabledSources.length} sources, '
        '${typesToMonitor.length} types, magnitude <= $magnitudeThreshold',
        source: 'TransientAlertSettingsNotifier',
      );
    } catch (e) {
      _logger.error(
        'Failed to load transient alert settings: $e',
        source: 'TransientAlertSettingsNotifier',
      );
      // Keep default settings on error
    } finally {
      _initialized = true;
      final completer = _loadCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      _loadCompleter = null;
    }
  }

  /// Save all current settings to persistent storage
  Future<void> _saveSettings(TransientAlertSettings settings) async {
    try {
      final remote = _remote;
      if (remote != null) {
        await remote.updateTransientSettings({
          'enabledSources': settings.enabledSources
              .map((source) => source.name)
              .toList(),
          'typesToMonitor': settings.typesToMonitor
              .map((type) => type.name)
              .toList(),
          'magnitudeThreshold': settings.magnitudeThreshold,
          'notifyOnNew': settings.notifyOnNew,
          'autoQueueBright': settings.autoQueueBright,
          'autoQueueMagnitude': settings.autoQueueMagnitude,
        });
      } else {
        await _settingsDao.setSettings({
          '${_settingsKeyPrefix}enabled_sources': json.encode(
            settings.enabledSources.map((s) => s.name).toList(),
          ),
          '${_settingsKeyPrefix}types_to_monitor': json.encode(
            settings.typesToMonitor.map((t) => t.name).toList(),
          ),
          '${_settingsKeyPrefix}magnitude_threshold': settings
              .magnitudeThreshold
              .toString(),
          '${_settingsKeyPrefix}notify_on_new': settings.notifyOnNew.toString(),
          '${_settingsKeyPrefix}auto_queue_bright': settings.autoQueueBright
              .toString(),
          '${_settingsKeyPrefix}auto_queue_magnitude': settings
              .autoQueueMagnitude
              .toString(),
        });
      }
      _logger.debug(
        'Transient alert settings saved',
        source: 'TransientAlertSettingsNotifier',
      );
    } catch (e) {
      _logger.error(
        'Failed to save transient alert settings: $e',
        source: 'TransientAlertSettingsNotifier',
      );
      rethrow;
    }
  }

  Map<String, String> _remoteSettingsAsStored(Map<String, dynamic> settings) {
    final enabledSources = settings['enabledSources'];
    final typesToMonitor = settings['typesToMonitor'];
    return {
      if (enabledSources is List)
        '${_settingsKeyPrefix}enabled_sources': json.encode(enabledSources),
      if (typesToMonitor is List)
        '${_settingsKeyPrefix}types_to_monitor': json.encode(typesToMonitor),
      if (settings['magnitudeThreshold'] != null)
        '${_settingsKeyPrefix}magnitude_threshold':
            settings['magnitudeThreshold'].toString(),
      if (settings['notifyOnNew'] != null)
        '${_settingsKeyPrefix}notify_on_new': settings['notifyOnNew']
            .toString(),
      if (settings['autoQueueBright'] != null)
        '${_settingsKeyPrefix}auto_queue_bright': settings['autoQueueBright']
            .toString(),
      if (settings['autoQueueMagnitude'] != null)
        '${_settingsKeyPrefix}auto_queue_magnitude':
            settings['autoQueueMagnitude'].toString(),
    };
  }

  Future<void> _queueSettingsUpdate(TransientAlertSettings settings) {
    if (_requestedSettings == settings) return _requestedWrite;

    _requestedSettings = settings;
    final revision = ++_requestRevision;
    state = settings;
    final operation = _writeTail.then((_) async {
      if (revision != _requestRevision) return;
      try {
        await _saveSettings(settings);
        _confirmedSettings = settings;
      } catch (_) {
        if (mounted && revision == _requestRevision) {
          _requestedSettings = _confirmedSettings;
          state = _confirmedSettings;
        }
        rethrow;
      }
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, __) {});
    _requestedWrite = operation;
    return operation;
  }

  /// Update all settings at once
  Future<void> updateSettings(TransientAlertSettings settings) async {
    await loaded;
    await _queueSettingsUpdate(settings);
  }

  /// Toggle a specific source on or off
  Future<void> toggleSource(TransientSource source) async {
    await loaded;
    final newSources = Set<TransientSource>.from(
      _requestedSettings.enabledSources,
    );
    if (newSources.contains(source)) {
      newSources.remove(source);
    } else {
      newSources.add(source);
    }
    await _queueSettingsUpdate(
      _requestedSettings.copyWith(enabledSources: newSources),
    );
  }

  /// Toggle a specific transient type on or off
  Future<void> toggleType(TransientType type) async {
    await loaded;
    final newTypes = Set<TransientType>.from(_requestedSettings.typesToMonitor);
    if (newTypes.contains(type)) {
      newTypes.remove(type);
    } else {
      newTypes.add(type);
    }
    await _queueSettingsUpdate(
      _requestedSettings.copyWith(typesToMonitor: newTypes),
    );
  }

  /// Set the magnitude threshold for alerts
  Future<void> setMagnitudeThreshold(double threshold) async {
    if (!threshold.isFinite) {
      throw ArgumentError.value(threshold, 'threshold', 'must be finite');
    }
    await loaded;
    await _queueSettingsUpdate(
      _requestedSettings.copyWith(magnitudeThreshold: threshold),
    );
  }

  /// Set whether to notify on new alerts
  Future<void> setNotifyOnNew(bool notify) async {
    await loaded;
    await _queueSettingsUpdate(
      _requestedSettings.copyWith(notifyOnNew: notify),
    );
  }

  /// Set whether to auto-queue bright transients
  Future<void> setAutoQueueBright(bool autoQueue) async {
    await loaded;
    await _queueSettingsUpdate(
      _requestedSettings.copyWith(autoQueueBright: autoQueue),
    );
  }

  /// Set the magnitude threshold for auto-queuing
  Future<void> setAutoQueueMagnitude(double magnitude) async {
    if (!magnitude.isFinite) {
      throw ArgumentError.value(magnitude, 'magnitude', 'must be finite');
    }
    await loaded;
    await _queueSettingsUpdate(
      _requestedSettings.copyWith(autoQueueMagnitude: magnitude),
    );
  }
}

/// Provider for transient alert settings with persistence.
final transientAlertSettingsProvider =
    StateNotifierProvider<
      TransientAlertSettingsNotifier,
      TransientAlertSettings
    >((ref) {
      final settingsDao = ref.watch(settingsDaoProvider);
      final logger = ref.watch(loggingServiceProvider);
      final backend = ref.watch(backendProvider);
      return TransientAlertSettingsNotifier(
        settingsDao: settingsDao,
        logger: logger,
        remote: backend is NetworkBackend ? backend : null,
      );
    });

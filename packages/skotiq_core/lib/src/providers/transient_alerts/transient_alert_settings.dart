part of '../transient_alert_provider.dart';

/// Notifier for managing transient alert settings with persistence.
///
/// Settings are persisted to the app settings database and loaded on startup.
/// Changes are immediately saved to ensure settings survive app restarts.
class TransientAlertSettingsNotifier
    extends StateNotifier<TransientAlertSettings> {
  final SettingsDao _settingsDao;
  final LoggingService _logger;
  final HostTransients? _remote;
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
    HostTransients? remote,
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

  Future<void> _loadSettings() async {
    if (_initialized) return;
    final revisionAtStart = _requestRevision;

    try {
      final remote = _remote;
      final allSettings = remote == null
          ? await _settingsDao.getAllSettings()
          : _remoteSettingsAsStored(await remote.getTransientSettings());

      final defaults = TransientAlertSettings.defaultSettings;
      final enabledSources =
          _parseSources(
            StoreSettings.transientAlertSources.valueIn(allSettings),
          ) ??
          defaults.enabledSources;
      final typesToMonitor =
          _parseTypes(StoreSettings.transientAlertTypes.valueIn(allSettings)) ??
          defaults.typesToMonitor;
      final magnitudeThreshold = StoreSettings.transientAlertMagnitudeThreshold
          .valueIn(allSettings);

      final loaded = TransientAlertSettings(
        enabledSources: enabledSources,
        magnitudeThreshold: magnitudeThreshold,
        typesToMonitor: typesToMonitor,
        notifyOnNew: StoreSettings.transientAlertNotifyOnNew.valueIn(
          allSettings,
        ),
        autoQueueBright: StoreSettings.transientAlertAutoQueueBright.valueIn(
          allSettings,
        ),
        autoQueueMagnitude: StoreSettings.transientAlertAutoQueueMagnitude
            .valueIn(allSettings),
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
        await _settingsDao.writeAll([
          StoreSettings.transientAlertSources.to(
            json.encode(settings.enabledSources.map((s) => s.name).toList()),
          ),
          StoreSettings.transientAlertTypes.to(
            json.encode(settings.typesToMonitor.map((t) => t.name).toList()),
          ),
          StoreSettings.transientAlertMagnitudeThreshold.to(
            settings.magnitudeThreshold,
          ),
          StoreSettings.transientAlertNotifyOnNew.to(settings.notifyOnNew),
          StoreSettings.transientAlertAutoQueueBright.to(
            settings.autoQueueBright,
          ),
          StoreSettings.transientAlertAutoQueueMagnitude.to(
            settings.autoQueueMagnitude,
          ),
        ]);
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

  /// The host's settings as the rows that would store them, so one reader
  /// serves the host's snapshot and this computer's database.
  Map<String, String> _remoteSettingsAsStored(Map<String, dynamic> settings) {
    final enabledSources = settings['enabledSources'];
    final typesToMonitor = settings['typesToMonitor'];
    return {
      if (enabledSources is List)
        StoreSettings.transientAlertSources.key: json.encode(enabledSources),
      if (typesToMonitor is List)
        StoreSettings.transientAlertTypes.key: json.encode(typesToMonitor),
      for (final MapEntry(key: wire, value: setting)
          in <String, Setting<Object?>>{
            'magnitudeThreshold':
                StoreSettings.transientAlertMagnitudeThreshold,
            'notifyOnNew': StoreSettings.transientAlertNotifyOnNew,
            'autoQueueBright': StoreSettings.transientAlertAutoQueueBright,
            'autoQueueMagnitude':
                StoreSettings.transientAlertAutoQueueMagnitude,
          }.entries)
        if (settings[wire] != null) setting.key: settings[wire].toString(),
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

  Future<void> updateSettings(TransientAlertSettings settings) async {
    await loaded;
    await _queueSettingsUpdate(settings);
  }

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

  Future<void> setMagnitudeThreshold(double threshold) async {
    if (!threshold.isFinite) {
      throw ArgumentError.value(threshold, 'threshold', 'must be finite');
    }
    await loaded;
    await _queueSettingsUpdate(
      _requestedSettings.copyWith(magnitudeThreshold: threshold),
    );
  }

  Future<void> setNotifyOnNew(bool notify) async {
    await loaded;
    await _queueSettingsUpdate(
      _requestedSettings.copyWith(notifyOnNew: notify),
    );
  }

  Future<void> setAutoQueueBright(bool autoQueue) async {
    await loaded;
    await _queueSettingsUpdate(
      _requestedSettings.copyWith(autoQueueBright: autoQueue),
    );
  }

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
      final remote = backend.remoteHost?.transients;
      return TransientAlertSettingsNotifier(
        settingsDao: settingsDao,
        logger: logger,
        remote: remote,
      );
    });

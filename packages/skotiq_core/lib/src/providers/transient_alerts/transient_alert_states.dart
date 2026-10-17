part of '../transient_alert_provider.dart';

/// Storage key prefix for alert states in the database
const String _alertStateKeyPrefix = 'transient_alert_state_';

/// Notifier for tracking user actions on transient alerts.
///
/// Persists alert states (acknowledged, queued, observed, dismissed) to the database
/// so they survive app restarts.
class TransientAlertStatesNotifier
    extends StateNotifier<Map<String, TransientAlertState>> {
  final SettingsDao _settingsDao;
  final LoggingService _logger;
  final NetworkBackend? _remote;
  bool _initialized = false;
  Completer<void>? _loadCompleter;
  int _requestRevision = 0;
  Future<void> _writeTail = Future<void>.value();

  TransientAlertStatesNotifier({
    required SettingsDao settingsDao,
    required LoggingService logger,
    NetworkBackend? remote,
  }) : _settingsDao = settingsDao,
       _logger = logger,
       _remote = remote,
       super({}) {
    unawaited(_loadStates());
  }

  /// Resolves once persisted states have been applied. Mutations wait for this
  /// snapshot so a first click cannot discard unrelated existing alert states.
  Future<void> get loaded {
    if (_initialized) return Future<void>.value();
    _loadCompleter ??= Completer<void>();
    return _loadCompleter!.future;
  }

  /// Load alert states from persistent storage
  Future<void> _loadStates() async {
    if (_initialized) return;
    final revisionAtStart = _requestRevision;

    try {
      final states = <String, TransientAlertState>{};
      final remote = _remote;
      if (remote != null) {
        final remoteStates = await remote.getTransientStates();
        for (final entry in remoteStates.entries) {
          final alertId = entry.key.trim();
          final value = entry.value;
          if (alertId.isEmpty || value is! String) continue;
          for (final candidate in TransientAlertState.values) {
            if (candidate.name == value) {
              states[alertId] = candidate;
              break;
            }
          }
        }
      } else {
        final allSettings = await _settingsDao.getAllSettings();
        // Find all alert state entries
        for (final entry in allSettings.entries) {
          if (entry.key.startsWith(_alertStateKeyPrefix)) {
            final alertId = entry.key.substring(_alertStateKeyPrefix.length);
            final stateValue = TransientAlertState.values.firstWhere(
              (s) => s.name == entry.value,
              orElse: () => TransientAlertState.newAlert,
            );
            states[alertId] = stateValue;
          }
        }
      }

      if (mounted && revisionAtStart == _requestRevision) {
        state = states;
      }
      _logger.debug(
        'Loaded ${states.length} transient alert states',
        source: 'TransientAlertStatesNotifier',
      );
    } catch (e) {
      _logger.error(
        'Failed to load transient alert states: $e',
        source: 'TransientAlertStatesNotifier',
      );
    } finally {
      _initialized = true;
      final completer = _loadCompleter;
      if (completer != null && !completer.isCompleted) completer.complete();
      _loadCompleter = null;
    }
  }

  Future<void> _setAlertState(String id, TransientAlertState alertState) async {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    await loaded;
    if (state[id] == alertState) {
      await _writeTail;
      return;
    }

    _requestRevision++;
    final operation = _writeTail.then((_) async {
      await _saveState(id, alertState);
      if (mounted) state = {...state, id: alertState};
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, __) {});
    await operation;
  }

  /// Save a single alert state to persistent storage
  Future<void> _saveState(
    String alertId,
    TransientAlertState alertState,
  ) async {
    try {
      final remote = _remote;
      if (remote != null) {
        await remote.updateTransientState(alertId, alertState.name);
      } else {
        await _settingsDao.setSetting(
          '$_alertStateKeyPrefix$alertId',
          alertState.name,
        );
      }
    } catch (e) {
      _logger.error(
        'Failed to save alert state for $alertId: $e',
        source: 'TransientAlertStatesNotifier',
      );
      rethrow;
    }
  }

  /// Mark an alert as acknowledged
  Future<void> acknowledge(String id) async {
    await _setAlertState(id, TransientAlertState.acknowledged);
    _logger.debug(
      'Alert $id acknowledged',
      source: 'TransientAlertStatesNotifier',
    );
  }

  /// Mark an alert as queued for observation
  Future<void> queue(String id) async {
    await _setAlertState(id, TransientAlertState.queued);
    _logger.debug('Alert $id queued', source: 'TransientAlertStatesNotifier');
  }

  /// Dismiss an alert
  Future<void> dismiss(String id) async {
    await _setAlertState(id, TransientAlertState.dismissed);
    _logger.debug(
      'Alert $id dismissed',
      source: 'TransientAlertStatesNotifier',
    );
  }

  /// Set a state supplied by a remote API after it has been validated.
  Future<void> setState(String id, TransientAlertState alertState) =>
      _setAlertState(id, alertState);

  /// Get the state of a specific alert
  TransientAlertState? getState(String id) => state[id];

  /// Clear all alert states (useful for testing or reset)
  Future<void> clearAll() async {
    await loaded;
    _requestRevision++;
    final operation = _writeTail.then((_) async {
      try {
        final remote = _remote;
        if (remote != null) {
          await remote.clearTransientStates();
        } else {
          // Remove all alert state entries from the database
          final allSettings = await _settingsDao.getAllSettings();
          for (final key in allSettings.keys) {
            if (key.startsWith(_alertStateKeyPrefix)) {
              await _settingsDao.deleteSetting(key);
            }
          }
        }
        if (mounted) state = {};
        _logger.info(
          'All alert states cleared',
          source: 'TransientAlertStatesNotifier',
        );
      } catch (e) {
        _logger.error(
          'Failed to clear alert states: $e',
          source: 'TransientAlertStatesNotifier',
        );
        rethrow;
      }
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, __) {});
    await operation;
  }
}

/// Provider for tracking user actions on transient alerts.
final transientAlertStatesProvider =
    StateNotifierProvider<
      TransientAlertStatesNotifier,
      Map<String, TransientAlertState>
    >((ref) {
      final settingsDao = ref.watch(settingsDaoProvider);
      final logger = ref.watch(loggingServiceProvider);
      final backend = ref.watch(backendProvider);
      return TransientAlertStatesNotifier(
        settingsDao: settingsDao,
        logger: logger,
        remote: backend is NetworkBackend ? backend : null,
      );
    });

/// The state an alert should be rendered and filtered by.
///
/// [overrides] — the [transientAlertStatesProvider] map — is populated ONLY
/// from the `transient_alert_state_<id>` settings rows the user's own
/// queue/observe/dismiss actions write. Nothing ever seeds it from the alert's
/// own [TransientAlert.state], so reading the map alone threw away what the
/// source row already knew: confirming a First Light candidate sets `reviewed`
/// on the detection, [transientAlertFromDetection] maps that to
/// [TransientAlertState.acknowledged], and yet the Observing Alerts tab one
/// click across still badged the same detection "New" and filed it under the
/// "New" filter. Two views of one row must not disagree.
///
/// A user action still wins — that is what an override is — and API-sourced
/// alerts carry the default [TransientAlertState.newAlert], so their behaviour
/// is unchanged.
TransientAlertState resolveTransientAlertState(
  TransientAlert alert,
  Map<String, TransientAlertState> overrides,
) {
  return overrides[alert.id] ?? alert.state;
}

// Unacknowledged alert count provider

/// Provider that computes the count of unacknowledged alerts.
///
/// An alert is unacknowledged when its resolved state (see
/// [resolveTransientAlertState]) is still [TransientAlertState.newAlert] — a
/// detection the user has already confirmed in First Light must not keep
/// inflating the badge.
final unacknowledgedAlertCountProvider = Provider<int>((ref) {
  final alertsAsync = ref.watch(activeTransientAlertsProvider);
  final states = ref.watch(transientAlertStatesProvider);

  final alerts = alertsAsync.valueOrNull ?? [];

  return alerts
      .where(
        (alert) =>
            resolveTransientAlertState(alert, states) ==
            TransientAlertState.newAlert,
      )
      .length;
});

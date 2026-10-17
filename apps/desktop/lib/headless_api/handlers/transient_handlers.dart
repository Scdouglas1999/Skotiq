import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for transient astronomical event alerts
class TransientHandlers {
  final ProviderContainer container;

  TransientHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'TransientHandlers');

  Future<TransientAlertSettings> _readSettings() async {
    final notifier = container.read(transientAlertSettingsProvider.notifier);
    await notifier.loaded;
    return container.read(transientAlertSettingsProvider);
  }

  Future<List<TransientAlert>> _fetchAlerts(
    TransientAlertSettings settings,
  ) async {
    final service = container.read(transientAlertServiceProvider);
    final science = await container.read(scienceSettingsProvider.future);
    var apiKey = '';
    if (settings.enabledSources.contains(TransientSource.tns) &&
        science.tnsBotId > 0 &&
        science.tnsBotName.trim().isNotEmpty) {
      try {
        apiKey = await container
            .read(secretsStoreProvider)
            .read(SecretField.tnsApiKey);
      } catch (error) {
        _logger.warning(
          'Could not read the TNS API key; serving other transient sources '
          'only: $error',
          source: 'TransientHandlers',
        );
      }
    }
    return service.getAllAlerts(
      settings.copyWith(tnsApiKey: apiKey.isEmpty ? null : apiKey),
      tnsBotId: science.tnsBotId,
      tnsBotName: science.tnsBotName,
      tnsUseSandbox: science.tnsUseSandbox,
    );
  }

  // Get active transients

  Future<Response> handleGetActiveTransients(Request request) async {
    _logInfo('[API] GET /api/transients');
    final settings = await _readSettings();

    // Fetch alerts from configured sources
    final alerts = await _fetchAlerts(settings);
    final statesNotifier = container.read(
      transientAlertStatesProvider.notifier,
    );
    await statesNotifier.loaded;
    final states = container.read(transientAlertStatesProvider);

    // Resolve each alert's state the way every other surface does: the
    // overrides map holds only the queue/dismiss actions taken through this
    // API, so a First Light detection the user dismissed in the desktop app
    // (the row itself carries the state) stayed "active" for every remote
    // client. Counting the map's entries had the same blind spot.
    final resolved = <String, TransientAlertState>{
      for (final a in alerts) a.id: resolveTransientAlertState(a, states),
    };
    final activeAlerts = alerts
        .where((a) => resolved[a.id] != TransientAlertState.dismissed)
        .toList();

    return jsonOk({
      "alerts": activeAlerts.map((a) => _alertToJson(a, states)).toList(),
      "totalCount": alerts.length,
      "dismissedCount": _countResolved(resolved, TransientAlertState.dismissed),
      "queuedCount": _countResolved(resolved, TransientAlertState.queued),
    });
  }

  // Get transient settings

  Future<Response> handleGetSettings(Request request) async {
    _logInfo('[API] GET /api/transients/settings');
    final settings = await _readSettings();

    return jsonOk({
      "settings": {
        "enabledSources": settings.enabledSources.map((s) => s.name).toList(),
        "typesToMonitor": settings.typesToMonitor.map((t) => t.name).toList(),
        "magnitudeThreshold": settings.magnitudeThreshold,
        "notifyOnNew": settings.notifyOnNew,
        "autoQueueBright": settings.autoQueueBright,
        "autoQueueMagnitude": settings.autoQueueMagnitude,
      },
    });
  }

  // Update transient settings

  Future<Response> handleUpdateSettings(Request request) async {
    _logInfo('[API] POST /api/transients/settings');
    final payload = await readJsonObject(request);

    // enabledSources / typesToMonitor are accepted as either an array
    // (replacement) or omitted entirely (keep existing). Unknown enum names
    // are filtered out rather than 400-ing the whole update on a single
    // unrecognised source name.
    final current = await _readSettings();
    Set<TransientSource> enabledSources = current.enabledSources;
    final rawSources = optionalList<String>(payload, 'enabledSources');
    if (rawSources != null) {
      enabledSources = rawSources
          .map(_parseSource)
          .whereType<TransientSource>()
          .toSet();
    }

    Set<TransientType> typesToMonitor = current.typesToMonitor;
    final rawTypes = optionalList<String>(payload, 'typesToMonitor');
    if (rawTypes != null) {
      typesToMonitor = rawTypes
          .map(_parseType)
          .whereType<TransientType>()
          .toSet();
    }

    final magnitudeThreshold =
        optionalDouble(payload, 'magnitudeThreshold') ??
        current.magnitudeThreshold;
    final autoQueueMagnitude =
        optionalDouble(payload, 'autoQueueMagnitude') ??
        current.autoQueueMagnitude;
    final notifyOnNew =
        optionalBool(payload, 'notifyOnNew') ?? current.notifyOnNew;
    final autoQueueBright =
        optionalBool(payload, 'autoQueueBright') ?? current.autoQueueBright;

    final updated = TransientAlertSettings(
      enabledSources: enabledSources,
      typesToMonitor: typesToMonitor,
      magnitudeThreshold: magnitudeThreshold,
      notifyOnNew: notifyOnNew,
      autoQueueBright: autoQueueBright,
      autoQueueMagnitude: autoQueueMagnitude,
    );
    await container
        .read(transientAlertSettingsProvider.notifier)
        .updateSettings(updated);

    return jsonOk({
      "status": "ok",
      "settings": {
        "enabledSources": updated.enabledSources.map((s) => s.name).toList(),
        "typesToMonitor": updated.typesToMonitor.map((t) => t.name).toList(),
        "magnitudeThreshold": updated.magnitudeThreshold,
        "notifyOnNew": updated.notifyOnNew,
        "autoQueueBright": updated.autoQueueBright,
        "autoQueueMagnitude": updated.autoQueueMagnitude,
      },
    });
  }

  // Queue transient for observation

  Future<Response> handleQueueTransient(Request request, String id) async {
    _logInfo('[API] POST /api/transients/$id/queue');
    final notifier = container.read(transientAlertStatesProvider.notifier);
    await notifier.queue(id);
    final states = container.read(transientAlertStatesProvider);

    return jsonOk({
      "status": "queued",
      "alertId": id,
      "queuedCount": _countState(states, TransientAlertState.queued),
    });
  }

  // Dismiss transient

  Future<Response> handleDismissTransient(Request request, String id) async {
    _logInfo('[API] POST /api/transients/$id/dismiss');
    final notifier = container.read(transientAlertStatesProvider.notifier);
    await notifier.dismiss(id);
    final states = container.read(transientAlertStatesProvider);

    return jsonOk({
      "status": "dismissed",
      "alertId": id,
      "dismissedCount": _countState(states, TransientAlertState.dismissed),
    });
  }

  Future<Response> handleGetStates(Request request) async {
    _logInfo('[API] GET /api/transients/states');
    final notifier = container.read(transientAlertStatesProvider.notifier);
    await notifier.loaded;
    final states = container.read(transientAlertStatesProvider);
    return jsonOk({
      'states': states.map((id, state) => MapEntry(id, state.name)),
    });
  }

  Future<Response> handleUpdateState(Request request, String id) async {
    _logInfo('[API] POST /api/transients/$id/state');
    final payload = await readJsonObject(request);
    final rawState = requireString(payload, 'state');
    TransientAlertState? requested;
    for (final candidate in TransientAlertState.values) {
      if (candidate.name == rawState) {
        requested = candidate;
        break;
      }
    }
    if (requested == null) {
      throw BadRequestError(
        field: 'state',
        expected: 'transient_alert_state',
        message: 'Unknown transient alert state',
      );
    }
    await container
        .read(transientAlertStatesProvider.notifier)
        .setState(id, requested);
    return jsonOk({'status': requested.name, 'alertId': id});
  }

  Future<Response> handleClearStates(Request request) async {
    _logInfo('[API] DELETE /api/transients/states');
    await container.read(transientAlertStatesProvider.notifier).clearAll();
    return jsonOk({'status': 'cleared'});
  }

  // Refresh alerts (clear cache)

  Future<Response> handleRefreshAlerts(Request request) async {
    _logInfo('[API] POST /api/transients/refresh');
    final service = container.read(transientAlertServiceProvider);
    service.clearCache();

    return jsonOk({"status": "cache_cleared"});
  }

  // Get queued transients

  Future<Response> handleGetQueued(Request request) async {
    _logInfo('[API] GET /api/transients/queued');
    final settings = await _readSettings();
    final statesNotifier = container.read(
      transientAlertStatesProvider.notifier,
    );
    await statesNotifier.loaded;
    final states = container.read(transientAlertStatesProvider);

    // Fetch all alerts and filter to queued ones
    final alerts = await _fetchAlerts(settings);
    final queuedAlerts = alerts
        .where(
          (a) =>
              resolveTransientAlertState(a, states) ==
              TransientAlertState.queued,
        )
        .toList();

    return jsonOk({
      "queued": queuedAlerts.map((a) => _alertToJson(a, states)).toList(),
    });
  }

  // Helpers

  TransientSource? _parseSource(String value) {
    final normalized = value.trim().toLowerCase();
    for (final source in TransientSource.values) {
      if (source.name.toLowerCase() == normalized) return source;
    }
    return null;
  }

  TransientType? _parseType(String value) {
    final normalized = value.trim().toLowerCase();
    for (final type in TransientType.values) {
      if (type.name.toLowerCase() == normalized) return type;
    }
    return null;
  }

  /// Count over states already resolved per alert (overrides falling back to
  /// the alert's own state), never over the raw overrides map — that map has
  /// no entry for a detection whose state lives on its own row.
  int _countResolved(
    Map<String, TransientAlertState> resolved,
    TransientAlertState wanted,
  ) => resolved.values.where((state) => state == wanted).length;

  /// Entries in the override store alone. Used only by the queue/dismiss
  /// responses, which acknowledge an action without the alert population in
  /// hand (fetching it would hit the remote sources on every mutation); the
  /// listing endpoints resolve over the population via [_countResolved].
  int _countState(
    Map<String, TransientAlertState> states,
    TransientAlertState wanted,
  ) => states.values.where((state) => state == wanted).length;

  Map<String, dynamic> _alertToJson(
    TransientAlert alert,
    Map<String, TransientAlertState> states,
  ) {
    return {
      'id': alert.id,
      'name': alert.name,
      'type': alert.type.name,
      'raHours': alert.raHours,
      'decDegrees': alert.decDegrees,
      'magnitude': alert.magnitude,
      'peakMagnitude': alert.peakMagnitude,
      'discoveryTime': alert.discoveryTime.millisecondsSinceEpoch,
      'lastUpdated': alert.lastUpdated.millisecondsSinceEpoch,
      'source': alert.source.name,
      'sourceUrl': alert.sourceUrl,
      'priority': alert.priority,
      'classification': alert.classification,
      'isQueued':
          resolveTransientAlertState(alert, states) ==
          TransientAlertState.queued,
      'isDismissed':
          resolveTransientAlertState(alert, states) ==
          TransientAlertState.dismissed,
    };
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Runtime state the host shares with linked clients.
///
/// `GET /api/runtime/state` returns the latest value of every runtime channel
/// (plate solve, centering, autofocus result, the frame on screen), which a
/// client applies on connect and reconnect; live changes travel as
/// `HostRuntimeState` events. `POST /api/runtime/state` takes a value a client
/// computed itself for a channel that accepts reports, applies it to the
/// host's own providers so the host GUI shows it, and lets the host's
/// broadcast carry it to the other clients.
class RuntimeStateHandlers {
  RuntimeStateHandlers(this.container, {List<SkotiqEvent> Function()? retained})
    : _retained = retained ?? (() => const <SkotiqEvent>[]);

  final ProviderContainer container;

  /// The events the server still holds for replay, oldest first.
  final List<SkotiqEvent> Function() _retained;

  /// Event types left out of the recent-events list: per-tick telemetry that
  /// says nothing once it is old (and, for autofocus, carries star crops),
  /// and the sync envelopes a client applies rather than logs.
  static const Set<String> _telemetryTypes = {
    'ExposureProgress',
    'GuideStep',
    'GuideStats',
    'MountPositionChanged',
    'CameraTemperatureChanged',
    'FocuserPositionChanged',
    'FilterWheelPositionChanged',
    'InstructionProgress',
    'InstructionProgressStructured',
    'AutofocusProgress',
    'IntegrationProgress',
    'Progress',
    'ProgressUpdated',
  };

  /// GET /api/runtime/recent-events?limit=N — the newest N events of the
  /// night a client connecting now missed, oldest first, without per-tick
  /// telemetry. A client seeds its event log with them so it opens on the
  /// same log the host shows.
  Future<Response> handleRecentEvents(Request request) async {
    final limit =
        (int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 100).clamp(
          1,
          200,
        );
    final kept = [
      for (final event in _retained())
        if (!isHostSyncEnvelope(event) &&
            !_telemetryTypes.contains(event.eventType))
          event,
    ];
    final newest = kept.length > limit
        ? kept.sublist(kept.length - limit)
        : kept;
    return jsonOk({
      'events': [for (final event in newest) _jsonSafe(event.toJson())],
    });
  }

  /// Bridge payloads can carry BigInt, which JSON has no form for.
  static Object? _jsonSafe(Object? value) {
    if (value is BigInt) return value.isValidInt ? value.toInt() : '$value';
    if (value is Map) {
      return {
        for (final e in value.entries) e.key.toString(): _jsonSafe(e.value),
      };
    }
    if (value is Iterable) return [for (final v in value) _jsonSafe(v)];
    return value;
  }

  Future<Response> handleGetState(Request request) async {
    // Reading the publisher makes sure it is listening on a headless host,
    // where no GUI watches it.
    container.read(hostRuntimeMirrorProvider);
    final updates = container.read(hostRuntimeStateStoreProvider).snapshot();
    return jsonOk({
      'updates': [for (final update in updates) update.toJson()],
    });
  }

  Future<Response> handleReport(Request request) async {
    final payload = await readJsonObject(request);
    final channel = requireString(payload, 'channel');
    final origin = requireString(payload, 'origin');
    final rawValue = payload['value'];
    if (rawValue != null && rawValue is! Map) {
      throw HandlerFailure(
        code: 'invalid_request',
        message: 'value must be an object or null',
        statusCode: 400,
      );
    }
    final applied = applyClientRuntimeReport(
      container,
      channel: channel,
      value: rawValue == null ? null : Map<String, dynamic>.from(rawValue),
      origin: origin,
    );
    if (!applied) {
      throw HandlerFailure(
        code: 'unknown_channel',
        message: 'The host does not accept reports for "$channel".',
        statusCode: 404,
      );
    }
    return jsonOk({'status': 'applied'});
  }
}

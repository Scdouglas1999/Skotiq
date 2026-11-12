import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/night_history_sync.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_events_provider.dart';
import 'package:skotiq_app/screens/night_control/panel/solve/recent_solves_provider.dart';
import 'package:skotiq_app/services/manual_capture_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../request_context.dart';
import '../response_helpers.dart';
import '../validation.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

/// Runtime state the host shares with linked clients.
///
/// `GET /api/runtime/state` returns the latest value of every runtime channel
/// (plate solve, centering, autofocus result, the frame on screen), which a
/// client applies on connect and reconnect; live changes travel as
/// `HostRuntimeState` events. `POST /api/runtime/state` takes a value a client
/// computed itself for a channel that accepts reports, applies it to the
/// host's own providers so the host GUI shows it, and lets the host's
/// broadcast carry it to the other clients.
class RuntimeStateHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    RuntimeStateApi.getState: handleGetState,
    RuntimeStateApi.report: handleReport,
    RuntimeStateApi.recentEvents: handleRecentEvents,
    RuntimeStateApi.nightHistory: handleNightHistory,
    RuntimeStateApi.startManualLoop: handleStartManualLoop,
    RuntimeStateApi.stopManualLoop: handleStopManualLoop,
  };

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
    'Progress',
    'ProgressUpdated',
  };

  /// GET /api/runtime/recent-events?limit=N — the newest N events of the
  /// night a client connecting now missed, oldest first, without per-tick
  /// telemetry. A client seeds its event log with them so it opens on the
  /// same log the host shows. A request without admin access gets credential
  /// values hidden, as on the WebSocket.
  Future<Response> handleRecentEvents(Request request) async {
    final adminAccess = requestHasAdminAccess(request);
    final requested = request.url.queryParameters['limit'];
    final parsed = requested == null ? null : int.tryParse(requested);
    final limit = (parsed ?? 100).clamp(1, 200);
    final kept = <SkotiqEvent>[];
    for (final event in _retained()) {
      if (isHostSyncEnvelope(event) ||
          _telemetryTypes.contains(event.eventType)) {
        continue;
      }
      // Integration progress is a line per phase in the host's log
      // (registering, integrating, writing, done), but it reports each phase
      // many times; only the newest report of a phase is kept, so the ticks
      // cannot push the night's other events out of the list.
      if (event.eventType == 'IntegrationProgress' &&
          kept.isNotEmpty &&
          kept.last.eventType == 'IntegrationProgress' &&
          kept.last.data['phase'] == event.data['phase']) {
        kept.removeLast();
      }
      kept.add(event);
    }
    final newest = kept.length > limit
        ? kept.sublist(kept.length - limit)
        : kept;
    return jsonOk({
      'events': [
        for (final event in newest)
          _jsonSafe(
            (adminAccess ? event : eventWithCredentialsHidden(event)).toJson(),
          ),
      ],
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

  /// GET /api/runtime/night-history — what this host's Tonight gathered
  /// tonight from live events (guide steps, autofocus runs, dithers, flips,
  /// lost stars, recent solves, the cooler history). A client that connects mid-night adds the
  /// part from before it connected, so its charts show what this one shows.
  Future<Response> handleNightHistory(Request request) async {
    return jsonOk(
      encodeNightHistory(
        guideSamples: container.read(nightGuideSamplesProvider),
        events: container.read(nightSessionEventsProvider),
        solves: container.read(nightRecentSolvesProvider),
        cooler: container.read(temperatureLongHistoryProvider),
      ),
    );
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

  /// POST /api/runtime/manual-loop — start the manual Loop on this host with
  /// a linked client's exposure settings (see `manualLoopRequestJson`). The
  /// loop runs here, so this window and every client show it and can stop
  /// it; its progress travels on the `manualLoop` runtime channel. 409 when a
  /// snapshot or loop is already running.
  Future<Response> handleStartManualLoop(Request request) async {
    final payload = await readJsonObject(request);
    final ExposureSettings settings;
    try {
      settings = manualLoopSettingsFromJson(payload);
    } on FormatException catch (e) {
      throw HandlerFailure(
        code: 'invalid_request',
        message: e.message,
        statusCode: 400,
      );
    }
    final controller = container.read(manualCaptureControllerProvider.notifier);
    if (container.read(manualCaptureControllerProvider).isBusy) {
      throw HandlerFailure(
        code: 'capture_busy',
        message: 'A snapshot or loop is already running on the host.',
        statusCode: 409,
      );
    }
    // Make sure the publisher is listening, so the clients see the loop.
    container.read(hostRuntimeMirrorProvider);
    unawaited(
      controller.loop(
        settings: settings,
        saveFrames: payload['saveFrames'] == true,
        targetName: payload['targetName'] is String
            ? payload['targetName'] as String
            : null,
      ),
    );
    return jsonOk({'status': 'looping'});
  }

  /// POST /api/runtime/manual-loop/stop — stop this host's manual Loop (or
  /// snapshot), whichever window started it.
  Future<Response> handleStopManualLoop(Request request) async {
    container.read(manualCaptureControllerProvider.notifier).stop();
    return jsonOk({'status': 'stopping'});
  }
}

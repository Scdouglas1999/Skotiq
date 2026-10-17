// Web/mobile Run-Watch endpoints.
//
// This file backs the focused "watch a running sequence from a phone over
// LAN" web app shipped under /run-watch. The goal is the same monitoring
// surface as NINA's Touch'N'Stars, but driven by Skotiq's existing
// backend + executor data sources rather than a parallel service layer.
//
// Endpoints (all under /api/run-watch/*):
//
//   GET  /api/run-watch/snapshot         — single bundled snapshot of all
//                                          monitoring data (progress,
//                                          active target, equipment
//                                          telemetry, guiding, weather,
//                                          recovery, recent events).
//   GET  /api/run-watch/frame-thumbnail  — most-recent captured frame as
//                                          a JPEG blob (built from the
//                                          stretched RGBA displayData
//                                          already produced for the GUI
//                                          run dashboard).
//   GET  /api/run-watch/events           — Server-Sent Events stream.
//                                          The same SkotiqEvent JSON
//                                          fan-out the WebSocket
//                                          broadcaster sees, but framed
//                                          as text/event-stream so
//                                          browser EventSource works
//                                          out-of-the-box.
//
// Playback controls (pause/resume/stop/skip) reuse the existing
// /api/sequencer/* handlers — the web client just POSTs to those.
//
// Auth: the runtime uses the existing pairing flow + Bearer-token /
// HttpOnly-cookie middleware. The /run-watch static bundle is exempted in
// the same way /dashboard is, so a phone can load the SPA, complete
// pairing, then drive all of these endpoints.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_error;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../display_buffer_jpeg.dart';
import '../response_helpers.dart';
import '../validation.dart';
import 'frame_measurement_headers.dart';

/// Handlers for the Run-Watch web monitoring surface.
///
/// All endpoints are read-only — playback controls re-use the existing
/// /api/sequencer/* mutators. The handlers here exist so a phone client
/// can fetch a coherent monitoring snapshot in a single round-trip
/// instead of stitching ten endpoints together.
class RunWatchHandlers {
  /// The provider container that backs the headless server. We pull the
  /// backend, services, and providers via this container exactly like the
  /// other handler files do.
  final ProviderContainer container;

  /// Broadcast of the server's single subscription on `backend.eventStream`.
  ///
  /// SSE clients come and go independently; subscribing each one to the
  /// backend stream directly would race on the underlying tokio broadcast
  /// channel, so every /events subscriber fans out from this one instead.
  final Stream<SkotiqEvent> eventBroadcast;

  /// Maximum events to retain for the snapshot's `recentEvents` block.
  /// The phone client doesn't show more than 5; a few extra are kept
  /// to absorb the gap between a snapshot request and the SSE
  /// subscription warming up.
  static const int _maxRetainedEvents = 16;

  /// Ring buffer of recently broadcast events. Populated by a single
  /// subscription on [eventBroadcast]; trimmed to [_maxRetainedEvents].
  ///
  /// Why a local buffer rather than reading `eventHistoryProvider`:
  /// that provider stores the FRB bridge's SkotiqEvent variant
  /// (sealed payload union) which has a different toJson shape from
  /// the core SkotiqEvent we get out of `backend.eventStream`.
  final List<SkotiqEvent> _recentBuffer = <SkotiqEvent>[];
  StreamSubscription<SkotiqEvent>? _bufferSubscription;

  RunWatchHandlers({required this.container, required this.eventBroadcast}) {
    // Track recent events for the snapshot endpoint. We tolerate
    // duplicate subscriptions on the same broadcast stream — the
    // upstream is a single broadcast controller in headless_api_server.
    _bufferSubscription = eventBroadcast.listen((event) {
      _recentBuffer.insert(0, event);
      if (_recentBuffer.length > _maxRetainedEvents) {
        _recentBuffer.removeRange(_maxRetainedEvents, _recentBuffer.length);
      }
    });
  }

  /// Release the recent-events subscription. Called by the server
  /// when stop() unwinds.
  Future<void> dispose() async {
    await _bufferSubscription?.cancel();
    _bufferSubscription = null;
  }

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'RunWatchHandlers');
  void _logWarning(String message) =>
      _logger.warning(message, source: 'RunWatchHandlers');

  // Snapshot

  /// GET /api/run-watch/snapshot
  ///
  /// One-shot bundle of every panel on the phone client. The handler
  /// gathers data from independent providers in parallel via
  /// `Future.wait` so the worst-case latency is bounded by the slowest
  /// source (typically the sequencer status FFI call). On error we
  /// degrade gracefully per-section — a failing weather service must
  /// not blank out the rest of the dashboard.
  Future<Response> handleSnapshot(Request request) async {
    // A-12: legitimately multi-role — snapshot aggregates sequencer status,
    // PHD2 guiding status, device list, and recovery context for the
    // run-watch dashboard. Stays on backendProvider rather than threading
    // four role refs through one method.
    final backend = container.read(backendProvider);

    // Sequencer status (FFI call). We pull from the backend (always
    // current) rather than the cached `sequenceProgressProvider`
    // (which is updated by event subscriptions and may lag a few ms
    // behind during a state transition).
    Map<String, Object?> sequencerStatus;
    try {
      final status = await backend.sequencerGetStatus();
      sequencerStatus = {
        'state': status.state,
        'currentNodeId': status.currentNodeId,
        'currentNodeName': status.currentNodeName,
        'progress': status.progress,
        'message': status.message,
      };
    } catch (e) {
      _logWarning('snapshot: sequencer status fetch failed: $e');
      sequencerStatus = {
        'state': 'unknown',
        'currentNodeId': null,
        'currentNodeName': null,
        'progress': 0.0,
        'message': 'Status unavailable: $e',
      };
    }

    // Live SequenceProgress + currentSequence — these come from
    // providers that the executor populates via event subscriptions. A
    // provider failure degrades to state:'unknown' with the reason, never
    // to an idle-shaped block: a remote operator must not be told the rig
    // is idle because a read threw mid-run.
    Map<String, Object?> progressBlock;
    try {
      final progress = container.read(sequenceProgressProvider);
      progressBlock = _progressToJson(progress);
    } catch (e) {
      _logWarning('snapshot: progress provider read failed: $e');
      progressBlock = _unavailableProgressJson(e);
    }

    // Same rule for the target header: a derivation failure is reported as
    // unavailable-with-reason, distinct from the null block that means no
    // sequence is loaded.
    Map<String, Object?>? activeTargetBlock;
    try {
      activeTargetBlock = _activeTargetBlock();
    } catch (e) {
      _logWarning('snapshot: active-target derivation failed: $e');
      activeTargetBlock = _unavailableTargetJson(e);
    }

    // Guide stats: pulled from the backend's phd2 status (the GuideStats
    // notifier is GUI-only and not always running in headless mode).
    Map<String, Object?> guidingBlock;
    try {
      final status = await backend.phd2GetStatus();
      guidingBlock = {
        'state': status.state,
        'connected': status.connected,
        'rmsRa': status.rmsRa,
        'rmsDec': status.rmsDec,
        'rmsTotal': status.rmsTotal,
        'snr': status.snr,
        'starMass': status.starMass,
        'avgDistance': status.avgDistance,
      };
    } catch (e) {
      _logWarning('snapshot: phd2 status fetch failed: $e');
      guidingBlock = {
        'state': 'disconnected',
        'connected': false,
        'rmsRa': null,
        'rmsDec': null,
        'rmsTotal': null,
        'snr': null,
        'starMass': null,
        'avgDistance': null,
      };
    }

    // Weather: drives the safety badge. Same shape as
    // /api/weather/safe-imaging so the client can reuse rendering code.
    Map<String, Object?> weatherBlock;
    try {
      final alertService = container.read(weatherAlertServiceProvider);
      final alert = alertService.currentAlert;
      final safety = container.read(weatherSafetyProvider);
      final message =
          alert?.message ??
          safety.actions.reason ??
          safety.failModeWarning ??
          (safety.isSafe
              ? 'Conditions are safe for imaging'
              : 'Weather safety has not been evaluated');
      weatherBlock = {
        'safeToImage': safety.isSafe,
        'alertLevel': alert?.level.name ?? safety.currentAlertLevel.name,
        'message': message,
        'dataSource': safety.dataSource.name,
        'lastEvaluation': safety.lastEvaluation?.toIso8601String(),
      };
    } catch (e) {
      _logWarning('snapshot: weather service read failed: $e');
      weatherBlock = {
        'safeToImage': false,
        'alertLevel': 'unknown',
        'message': 'Weather service unavailable',
        'dataSource': 'unavailable',
        'lastEvaluation': null,
      };
    }

    // Connected equipment list — IDs the client may pass back into
    // /api/equipment/* if it wants drill-down telemetry.
    List<Map<String, Object?>> devices;
    try {
      final connected = await backend.getConnectedDevices();
      devices = connected
          .map(
            (d) => <String, Object?>{
              'id': d.id,
              'name': d.name,
              'type': d.deviceType.name,
              'driver': d.driverType.name,
            },
          )
          .toList(growable: false);
    } catch (e) {
      _logWarning('snapshot: connected devices fetch failed: $e');
      devices = const [];
    }

    // Recovery context. Null when not currently recovering.
    Object? recovery;
    try {
      final raw = await backend.getCurrentRecoveryJson();
      recovery = raw == null ? null : _safeJsonDecode(raw);
    } catch (e) {
      _logWarning('snapshot: recovery context fetch failed: $e');
      recovery = null;
    }

    // Recent events — last 5 from the bridge's history provider.
    final recentEvents = _recentEvents(limit: 5);

    // Coerce any BigInt values to JSON-safe forms before encoding. frb maps
    // Rust u64/i64 fields (notably event timestamps from `event.toJson()`) to
    // Dart BigInt, which dart:convert cannot encode. Applied once to the whole
    // bundle so every sub-block is covered, not just the one that happens to
    // carry a BigInt today.
    return jsonOk(
      _jsonSafe(<String, Object?>{
            'serverTime': DateTime.now().toUtc().toIso8601String(),
            'sequencer': {...sequencerStatus, 'progress': progressBlock},
            'activeTarget': activeTargetBlock,
            'guiding': guidingBlock,
            'weather': weatherBlock,
            'recovery': recovery,
            'devices': devices,
            'recentEvents': recentEvents,
          })
          as Map<String, Object?>,
    );
  }

  /// Recursively replace BigInt with int (or String when it exceeds the
  /// 53-bit range JSON consumers can represent losslessly), walking maps and
  /// lists. Returns other values unchanged. Keeps the snapshot encodable no
  /// matter which frb-sourced sub-object introduces a BigInt.
  static Object? _jsonSafe(Object? value) {
    if (value is BigInt) {
      return value.isValidInt ? value.toInt() : value.toString();
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _jsonSafe(v)));
    }
    if (value is List) {
      return value.map(_jsonSafe).toList(growable: false);
    }
    return value;
  }

  Map<String, Object?> _progressToJson(SequenceProgress p) {
    if (p == const SequenceProgress()) return _neverRanProgressJson();
    return {
      'state': p.state.name,
      'currentNodeId': p.currentNodeId,
      'currentNodeName': p.currentNodeName,
      'currentTarget': p.currentTarget,
      'currentFilter': p.currentFilter,
      'totalExposures': p.totalExposures,
      'completedExposures': p.completedExposures,
      'totalIntegrationSecs': _knownIntegrationDenominator(p),
      'completedIntegrationSecs': p.completedIntegrationSecs,
      'elapsedSecs': p.elapsedSecs,
      'estimatedRemainingSecs': p.estimatedRemainingSecs,
      'message': p.message,
      'progressPercent': p.progressPercent,
    };
  }

  /// Progress block for a rig where NO run has ever written progress — a fresh
  /// install, or a host restarted since its last night.
  ///
  /// [SequenceProgress] starts every counter at zero, so publishing it verbatim
  /// made a rig that has never exposed a frame assert "0% / 0 of 0 / 0s of 0s"
  /// while every neighbouring block on the same page — target, last frame,
  /// guiding, filter — correctly rendered `--`. Zero frames of zero planned is
  /// not a measurement, it is the absence of one, so this says so with the
  /// nulls [_unavailableProgressJson] already uses and the client already
  /// renders as `--`.
  ///
  /// The state stays `idle` because that part IS known: no run is going. Only
  /// the figures are withheld. A rig that HAS run keeps its last run's real
  /// figures — the record equals the constructed default only until the first
  /// write lands on it.
  Map<String, Object?> _neverRanProgressJson() => {
    'state': const SequenceProgress().state.name,
    'currentNodeId': null,
    'currentNodeName': null,
    'currentTarget': null,
    'currentFilter': null,
    'totalExposures': null,
    'completedExposures': null,
    'totalIntegrationSecs': null,
    'completedIntegrationSecs': null,
    'elapsedSecs': null,
    'estimatedRemainingSecs': null,
    'message': null,
    'progressPercent': null,
  };

  /// The planned integration total, or null when this run has none to report.
  ///
  /// `SequenceProgress.totalIntegrationSecs` defaults to 0.0 and only the
  /// editor-driven start path fills it in (`SequenceExecutor` passes
  /// `sequence.totalIntegrationSecs` to `setTotals`). A headless run loads the
  /// wire JSON straight into the native executor, so the denominator arrives
  /// here as 0.0 while `totalExposures` counts a real dozen frames — and the
  /// phone renders "24s / 0s", a total the run has already passed. A frame
  /// takes positive time, so a run with frames planned and a zero total means
  /// the total is unknown, not zero. Say so with null.
  double? _knownIntegrationDenominator(SequenceProgress p) {
    if (p.totalIntegrationSecs > 0) return p.totalIntegrationSecs;
    if (p.totalExposures > 0) return null;
    return p.totalIntegrationSecs;
  }

  /// Progress block for a failed read. Every measured field is null, not
  /// zero: the server does not know how far the run has got, and a zeroed
  /// block reads on the client as a rig that is doing nothing.
  Map<String, Object?> _unavailableProgressJson(Object error) => {
    'state': 'unknown',
    'currentNodeId': null,
    'currentNodeName': null,
    'currentTarget': null,
    'currentFilter': null,
    'totalExposures': null,
    'completedExposures': null,
    'totalIntegrationSecs': null,
    'completedIntegrationSecs': null,
    'elapsedSecs': null,
    'estimatedRemainingSecs': null,
    'message': 'Progress unavailable: $error',
    'progressPercent': null,
  };

  /// Target block for a failed derivation. `unavailable` separates "we
  /// could not work out the target" from the null block that means no
  /// sequence is loaded.
  Map<String, Object?> _unavailableTargetJson(Object error) => {
    'unavailable': true,
    'coordinatesKnown': false,
    'message': 'Target unavailable: $error',
    'id': null,
    'name': null,
    'raHours': null,
    'decDegrees': null,
    'altitudeDeg': null,
    'azimuthDeg': null,
    'horizonDeg': null,
    'timeToSetSecs': null,
    'timeToTransitSecs': null,
  };

  /// Target block for a run whose name the server knows and whose pointing it
  /// does not.
  ///
  /// `POST /api/sequencer/load` hands the wire JSON straight to the native
  /// executor and never populates `currentSequenceProvider` (see
  /// `_handleSequencerLoad` — it keeps only a `_WireSequenceSummary` for the
  /// session row). So on a headless appliance the editor-derived block below
  /// is always null, and the phone's whole Active-target card renders `--`
  /// during a live run whose target the same snapshot names in
  /// `sequencer.progress.currentTarget`. Report the name the server has and
  /// mark the sky stats as unknown rather than reporting nothing at all.
  Map<String, Object?> _nameOnlyTargetJson(String name) => {
    'coordinatesKnown': false,
    'message': 'Coordinates unavailable: the native executor holds this run',
    'id': null,
    'name': name,
    'raHours': null,
    'decDegrees': null,
    'altitudeDeg': null,
    'azimuthDeg': null,
    'horizonDeg': null,
    'timeToSetSecs': null,
    'timeToTransitSecs': null,
  };

  /// Derives the active TargetHeaderNode from the currently-loaded
  /// sequence and, if location is configured, computes live alt/az +
  /// time-to-set / time-to-transit so the phone can display the same
  /// header as the desktop run dashboard.
  ///
  /// Falls back to [_nameOnlyTargetJson] when the run is native-side and the
  /// only thing the host knows is the live target name. Returns null when
  /// nothing at all is running.
  Map<String, Object?>? _activeTargetBlock() {
    Sequence? sequence;
    try {
      sequence = container.read(currentSequenceProvider);
    } on Object catch (e) {
      // Why: the run-watch snapshot endpoint is read-only and best-effort —
      // if the sequence provider is not yet wired (cold start before a
      // sequence is loaded) we treat that as "no active sequence" and
      // surface an empty header block rather than 500ing the entire
      // snapshot. The caller already handles a null return. We still log
      // so silent provider misconfigurations surface in diagnostics.
      _logWarning('snapshot: sequence provider read failed: $e');
      sequence = null;
    }

    final SequenceProgress progress;
    try {
      progress = container.read(sequenceProgressProvider);
    } on Object catch (e) {
      // Why: same rationale as above — when progress state isn't
      // available (provider not yet initialised) we hide the target
      // block instead of failing the snapshot.
      _logWarning('snapshot: progress provider read failed: $e');
      return null;
    }

    final liveName = progress.currentTarget;
    final hasLiveName = liveName != null && liveName.isNotEmpty;

    if (sequence == null) {
      return hasLiveName ? _nameOnlyTargetJson(liveName) : null;
    }

    TargetHeaderNode? target;
    if (hasLiveName) {
      for (final t in sequence.targetHeaders) {
        if (t.targetName == liveName) {
          target = t;
          break;
        }
      }
    }
    target ??= sequence.targetHeaders.isNotEmpty
        ? sequence.targetHeaders.first
        : null;
    if (target == null) {
      return hasLiveName ? _nameOnlyTargetJson(liveName) : null;
    }

    double? altitude;
    double? azimuth;
    int? timeToSetSecs;
    int? timeToTransitSecs;
    double? horizonDeg;
    try {
      final location = container.read(appObserverLocationProvider);
      if (location != null) {
        final scheduler = container.read(schedulerServiceProvider);
        final now = DateTime.now();
        final (alt, az) = scheduler.calculateAltAz(
          raHours: target.raHours,
          decDegrees: target.decDegrees,
          time: now,
          latitudeDegrees: location.latitude,
          longitudeDegrees: location.longitude,
        );
        altitude = alt;
        azimuth = az;

        final transit = scheduler.calculateTransitTime(
          raHours: target.raHours,
          date: now.toUtc(),
          longitudeDegrees: location.longitude,
        );
        if (transit.isAfter(now)) {
          timeToTransitSecs = transit.difference(now).inSeconds;
        }

        final hDeg = container.read(effectiveHorizonDegProvider);
        horizonDeg = hDeg;
        final timeToSet = scheduler.nextSetTime(
          raHours: target.raHours,
          decDegrees: target.decDegrees,
          now: now,
          latitudeDegrees: location.latitude,
          longitudeDegrees: location.longitude,
          horizonDeg: hDeg,
        );
        if (timeToSet != null) {
          timeToSetSecs = timeToSet.inSeconds;
        }
      }
    } catch (e) {
      _logWarning('snapshot: sky stats derivation failed: $e');
    }

    return {
      'coordinatesKnown': true,
      'id': target.id,
      'name': target.targetName,
      'raHours': target.raHours,
      'decDegrees': target.decDegrees,
      'altitudeDeg': altitude,
      'azimuthDeg': azimuth,
      'horizonDeg': horizonDeg,
      'timeToSetSecs': timeToSetSecs,
      'timeToTransitSecs': timeToTransitSecs,
    };
  }

  /// Pull the last [limit] events from the local broadcast buffer and
  /// normalise into the same shape the client receives over SSE so the
  /// trigger feed can render history immediately on page load.
  ///
  /// Why a local ring buffer rather than `eventHistoryProvider`: that
  /// provider stores the FRB bridge's SkotiqEvent variant whereas
  /// we deal in the core variant on the broadcast stream. Routing
  /// through the same upstream the SSE handler uses guarantees the
  /// page-load snapshot agrees with the live SSE feed.
  List<Map<String, Object?>> _recentEvents({required int limit}) {
    final take = _recentBuffer.length < limit ? _recentBuffer.length : limit;
    return [for (var i = 0; i < take; i++) _eventToJson(_recentBuffer[i])];
  }

  Object? _safeJsonDecode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException catch (e) {
      // Why: the recovery context is produced by Rust as a JSON string.
      // Surfacing the raw string keeps the rest of the snapshot readable;
      // throwing here would lose every other field. The client renders this
      // as opaque info.
      // FormatException is the only exception jsonDecode raises on
      // malformed input — narrower catch keeps unrelated failures loud.
      _logWarning('snapshot: malformed JSON in recovery context: $e');
      return raw;
    }
  }

  // Frame thumbnail (JPEG)

  /// Where the frames already on disk are listed, named in the empty-buffer
  /// body so a client can say what the rig actually holds.
  static const String kFrameLibraryRoute = '/api/images';

  /// The typed body for "this server process has no buffered frame".
  ///
  /// Same shape and same scope word as
  /// `CameraDeviceHandlers._emptyPreviewBody`, so the phone and the dashboard
  /// answer one question with one sentence.
  static Map<String, Object?> _emptyLivePreviewBody(String deviceId) => {
    'error': 'no_live_preview',
    'scope': 'process',
    'library': kFrameLibraryRoute,
    'message':
        'No live preview for $deviceId in this server process — the preview '
        'buffer holds the last exposure taken since the server started, and '
        'no exposure has run yet. Frames already captured are listed by '
        '$kFrameLibraryRoute.',
  };

  /// GET /api/run-watch/frame-thumbnail
  ///
  /// Returns the most recent captured frame as a JPEG. Inputs are pulled
  /// from the backend's `cameraGetLastImage(deviceId)` which already
  /// returns a stretched RGBA byte buffer (the same data the desktop
  /// run-dashboard preview panel renders). We re-encode to JPEG so the
  /// phone gets ~50KB over the wire instead of MB of raw RGBA.
  ///
  /// Query params:
  ///   deviceId  — optional camera device id. When omitted we use the
  ///               first connected camera so the phone doesn't need to
  ///               know the rig's hardware ids.
  ///   maxWidth  — optional. Downscales the JPEG. Default 1024 to keep
  ///               the payload phone-friendly.
  ///   quality   — optional JPEG quality 1..100, default 75.
  ///
  /// The empty-buffer 404 is a PER-PROCESS fact, and it says so. The buffer
  /// holds the last exposure taken since this server started and is empty
  /// again after a relaunch, while the frames themselves are on disk and
  /// listed by [kFrameLibraryRoute]. This endpoint used to answer "No image
  /// has been captured yet on this camera" — an absolute, returned by a rig
  /// whose library held 26 frames — and Run-Watch printed it as "No frame
  /// captured yet". `/api/camera/last-image/jpeg` already answered the same
  /// emptiness with the process-scoped wording; both now do.
  Future<Response> handleFrameThumbnail(Request request) async {
    final query = request.url.queryParameters;
    final maxWidth =
        optionalQueryInt(query, 'maxWidth', min: 1, max: 16384) ?? 1024;
    final quality = optionalQueryInt(query, 'quality', min: 1, max: 100) ?? 75;
    final backend = container.read(deviceBackendProvider);

    final queryDeviceId = query['deviceId']?.trim();
    String? deviceId = (queryDeviceId == null || queryDeviceId.isEmpty)
        ? null
        : queryDeviceId;

    if (deviceId == null) {
      try {
        final devices = await backend.getConnectedDevices();
        for (final d in devices) {
          if (d.deviceType == DeviceType.camera) {
            deviceId = d.id;
            break;
          }
        }
      } catch (e) {
        _logWarning('frame-thumbnail: getConnectedDevices failed: $e');
      }
    }

    if (deviceId == null || deviceId.isEmpty) {
      return jsonNotFound({
        'error': 'no_camera',
        'message':
            'No connected camera; supply ?deviceId= or connect a camera first.',
      });
    }

    // A driver with nothing buffered answers either null or `noImageAvailable`;
    // both are the same fact and earn the same process-scoped sentence. Only
    // that one variant is caught — every other backend failure goes on to
    // `errorTranslationMiddleware`, which keeps its own status and its own
    // words. Repainting all of them as a 404 "Failed to fetch last image" told
    // the phone a disconnected camera and a driver timeout were the same thing
    // as an empty buffer, and shipped the freezed constructor form as the
    // reason.
    CapturedImageResult? image;
    try {
      image = await backend.cameraGetLastImage(deviceId);
    } on bridge_error.SkotiqError catch (error) {
      final isEmptyBuffer = error.maybeMap(
        noImageAvailable: (_) => true,
        orElse: () => false,
      );
      if (!isEmptyBuffer) rethrow;
      image = null;
    }

    if (image == null) {
      return jsonNotFound(_emptyLivePreviewBody(deviceId));
    }

    final encoded = await encodeCapturedImageDisplayBufferToJpeg(
      image,
      maxWidth: maxWidth,
      quality: quality,
    );
    if (encoded == null) {
      _logWarning(
        'frame-thumbnail: displayData length ${image.displayData.length} != '
        '${image.width * image.height * 4} (w=${image.width} h=${image.height})',
      );
      return jsonInternalServerError({
        'error': 'bad_image_buffer',
        'message': 'Display buffer size mismatch.',
      });
    }

    final timestamp = capturedImageTimestampUtc(image.timestamp);
    return contentResponse(
      encoded.bytes,
      contentType: 'image/jpeg',
      contentLength: encoded.bytes.length,
      headers: {
        // Strong no-cache: the frame is constantly changing; an
        // intermediary cache would freeze the phone display.
        'cache-control': 'no-store, no-cache, must-revalidate',
        'x-frame-timestamp': timestamp,
        'x-frame-exposure-secs': image.exposureTime.toString(),
        // The HFR and the name of the measurement travel together — see
        // [kFrameHfrBasisHeader] for why an unqualified number here misleads.
        if (image.stats.hfr != null) ...{
          'x-frame-hfr': image.stats.hfr!.toString(),
          kFrameHfrBasisHeader: kFrameHfrBasisLivePreview,
        },
        'x-frame-star-count': image.stats.starCount.toString(),
      },
    );
  }

  // Server-Sent Events

  /// GET /api/run-watch/events
  ///
  /// Server-Sent Events stream. Browsers expose EventSource which
  /// auto-reconnects, parses the `data:` lines, and is permitted by
  /// every CSP we ship; that makes SSE a better fit than WebSocket for
  /// one-way event push to a phone.
  ///
  /// Each SkotiqEvent is emitted as a typed event so the client can
  /// filter without parsing the entire payload — e.g. `addEventListener
  /// ('FrameAccepted', ...)`. The default `message` event also fires so
  /// clients that just want the firehose can listen there.
  Response handleEventStream(Request request) {
    final controller = StreamController<List<int>>();

    void write(String s) {
      if (controller.isClosed) return;
      controller.add(utf8.encode(s));
    }

    StreamSubscription<SkotiqEvent>? sub;
    Timer? keepAlive;
    int counter = 0;

    controller.onListen = () {
      _logInfo('SSE client connected');
      // Why retry hint: tell EventSource to reconnect after 5s if the
      // socket drops. Default browser behaviour is 3s but on a phone
      // with a flaky LAN we want to be slightly less aggressive.
      write('retry: 5000\n\n');

      sub = eventBroadcast.listen(
        (event) {
          try {
            counter += 1;
            final json = event.toJson();
            final eventName = _eventTypeName(event);
            // SSE framing: `event:` chooses the named-event listener,
            // `id:` lets EventSource resume from the last id after a
            // reconnect, `data:` is the payload, blank line terminates.
            // We include the eventName in the body too so default
            // `message` listeners can route without inspecting headers.
            final payload = jsonEncode({...json, 'eventName': eventName});
            // Use monotonic counter for the id; the core
            // SkotiqEvent has no stable id field. EventSource
            // resends `Last-Event-ID` on reconnect but we don't replay,
            // so the id is informational only.
            write('event: $eventName\nid: $counter\ndata: $payload\n\n');
          } catch (e) {
            _logWarning('SSE encode failure: $e');
          }
        },
        onError: (Object e, _) {
          _logWarning('SSE upstream error: $e');
        },
      );

      // Heartbeat comments every 20s. Why: many corporate proxies and
      // some mobile carriers idle-timeout long-lived GETs after 30-60s
      // unless there's traffic. SSE comments start with `:` and are
      // ignored by EventSource so they cost nothing client-side.
      keepAlive = Timer.periodic(const Duration(seconds: 20), (_) {
        write(': keepalive\n\n');
      });
    };

    Future<void> cleanup() async {
      keepAlive?.cancel();
      keepAlive = null;
      await sub?.cancel();
      sub = null;
      _logInfo('SSE client disconnected');
    }

    controller.onCancel = cleanup;

    return streamResponse(
      controller.stream,
      contentType: 'text/event-stream; charset=utf-8',
      headers: {
        // Disable buffering on intermediaries that honour the header.
        'cache-control': 'no-cache, no-transform',
        'connection': 'keep-alive',
        // Hint to nginx-style proxies that this is a streaming response
        // so they don't buffer it into 8K chunks.
        'x-accel-buffering': 'no',
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  // Internal helpers

  /// Encode a SkotiqEvent the way the SSE/snapshot path expects.
  Map<String, Object?> _eventToJson(SkotiqEvent event) {
    final json = event.toJson();
    return {...json, 'eventName': _eventTypeName(event)};
  }

  /// Extract a coarse event-type name for SSE `event:` framing.
  ///
  /// The core SkotiqEvent already carries a `eventType` String
  /// (e.g. "FrameAccepted", "ExposureStarted") so the browser can do
  /// `evt.addEventListener('FrameAccepted', ...)` cleanly.
  String _eventTypeName(SkotiqEvent event) {
    final raw = event.eventType;
    // SSE event names tolerate most characters but the browser-side
    // `addEventListener` is far simpler when the name is a plain
    // identifier-style token. Strip whitespace/punctuation defensively.
    final sanitized = raw
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return sanitized.isEmpty ? 'event' : sanitized;
  }
}

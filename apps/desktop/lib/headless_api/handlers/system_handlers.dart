/// System-info HTTP handlers for the headless API.
///
/// Owns the four read-only endpoints a remote client polls to discover
/// the server before doing any work:
///   * `GET /api/info` — server name, build version, API-version
///     envelope, pairing support, fingerprint, scope list, full
///     endpoint catalog, and the replay-buffer cursor.
///   * `GET /api/status` — sequencer state snapshot (the lightweight
///     poll endpoint mobile clients use to render the run badge).
///   * `GET /api/self-test` — full release-quality probe: platform
///     capabilities, application-data directory write probes, Drift
///     database initialisation check, connected-device round-trip,
///     auth/dashboard advertised state.
///   * `GET /api/openapi.json` — generated OpenAPI 3 document; the
///     route list is the same hand-maintained array advertised on
///     `/api/info`'s `endpoints` field.
///
/// None of these endpoints mutate state, so they share a single
/// constructor that captures the server snapshot getters (the auth
/// fingerprint, the event replay cursor, the static-file availability
/// flag, etc.) as a typed lookup interface.
///
/// The hand-maintained endpoint catalog ([availableHeadlessEndpoints])
/// lives in `system_endpoint_catalog.dart` and the `/pair` browser
/// pairing page in `system_pair_page_handler.dart`; both are re-exported
/// here so existing imports of this file see the same surface.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../auth/public_paths.dart';
import '../request_context.dart';
import '../response_helpers.dart';
import '../route_metadata.dart' as route_metadata;
import 'static_file_handlers.dart';
import 'system_endpoint_catalog.dart';

// Re-export the endpoint catalog and the browser pairing-page handler so
// callers that import `system_handlers.dart` keep their existing surface.
export 'system_endpoint_catalog.dart' show availableHeadlessEndpoints;
export 'system_pair_page_handler.dart';

/// Read-only snapshot the system handlers pull off the live
/// [HeadlessApiServer]. Every field is a getter so we never cache stale
/// values (the event-seq cursor in particular advances on every
/// broadcast, so a snapshot taken at construction time would be useless
/// ten seconds later).
class SystemServerView {
  /// Hex-encoded server fingerprint. TLS pins to the SubjectPublicKeyInfo
  /// digest when TLS is active; plain-HTTP falls back to
  /// `computeServerFingerprint(adminToken)`.
  final String Function() fingerprint;

  /// UUID assigned at server-construction time. Mirrored onto every
  /// outbound event and returned by /api/info so clients detect a
  /// server restart by mismatch.
  final String Function() instanceId;

  /// Monotonically increasing event sequence counter; 0 before the
  /// first broadcast.
  final int Function() currentEventSeq;

  /// Configured capacity of the event ring buffer.
  final int Function() eventReplayBufferSize;

  /// Oldest seq retained in the ring buffer, or null when no events
  /// have been emitted yet.
  final int? Function() eventReplayBufferOldestSeq;

  /// Bound TCP port (post `start()` resolution).
  final int Function() port;

  /// Whether the bind address is loopback-only (`127.0.0.1`).
  final bool Function() bindLocalOnly;

  /// Whether the server has any configured auth tokens (admin +
  /// scoped). When false, `authMode='none'` and the dashboard banner
  /// warns the operator that anonymous LAN access is enabled.
  final bool Function() authRequired;

  /// Distinct scope names across every configured token. Returned
  /// alphabetised for stable comparison.
  final List<String> Function() availableAuthScopes;

  /// Active pairing-policy wire string (`lan-open` / `code-required`) so a
  /// client knows whether to one-tap claim on the LAN or prompt for a code.
  final String Function() pairingModeWire;

  /// The rig's Tailscale endpoint (MagicDNS `*.ts.net` or `100.x` literal) when
  /// a tailnet interface is present, else null. Lets a remote client learn the
  /// host instead of the operator reading it off the appliance log.
  final String? Function() tailscaleHost;

  /// The self-hosted-relay appliance id when a relay uplink is active, else
  /// null. Same purpose as [tailscaleHost] for the relay path.
  final String? Function() relayApplianceId;

  const SystemServerView({
    required this.fingerprint,
    required this.instanceId,
    required this.currentEventSeq,
    required this.eventReplayBufferSize,
    required this.eventReplayBufferOldestSeq,
    required this.port,
    required this.bindLocalOnly,
    required this.authRequired,
    required this.availableAuthScopes,
    required this.pairingModeWire,
    required this.tailscaleHost,
    required this.relayApplianceId,
  });
}

/// HTTP handlers for the four system-info endpoints. Constructed once
/// per server with the [SystemServerView] snapshot and the
/// [StaticFileHandlers] reference (for the dashboard-available flag).
class SystemHandlers {
  final ProviderContainer container;
  final SystemServerView view;
  final StaticFileHandlers staticFileHandlers;
  final LoggingService logger;

  SystemHandlers({
    required this.container,
    required this.view,
    required this.staticFileHandlers,
    required this.logger,
  });

  void _logInfo(String message) =>
      logger.info(message, source: 'SystemHandlers');
  void _logError(String message) =>
      logger.error(message, source: 'SystemHandlers');

  /// `GET /api/system/version` — build metadata, ALWAYS available.
  ///
  /// Sourced from [appVersionProvider] (populated at startup), so it works even
  /// on a headless instance with no OTA [UpdateController] wired. The richer
  /// update-aware version handler lives in the optional update-routes group,
  /// which is skipped (→ 404) when updates aren't provisioned; this base
  /// endpoint guarantees a client can always read the running build.
  Future<Response> handleVersion(Request request) async {
    final versionInfo = container.read(appVersionProvider);
    return jsonOk({
      'currentVersion': versionInfo.version,
      'buildNumber': versionInfo.buildNumber,
      'platform': Platform.operatingSystem,
    });
  }

  /// `GET /api/system/disk-space` — free/total bytes for the host's capture
  /// directory. Paired clients render their dashboard storage/readiness lines
  /// from this; they cannot sample it themselves, because the host's capture
  /// path does not exist on the phone's filesystem.
  Future<Response> handleDiskSpace(Request request) async {
    await container.read(appSettingsProvider.future);
    final settings = container.read(appSettingsProvider).valueOrNull;
    final path = settings?.imageOutputPath ?? '';
    if (path.isEmpty) {
      // Not configured is a valid state, not an error — clients render the
      // same "choose a capture folder" nudge the host UI shows.
      return jsonOk({'configured': false});
    }
    try {
      final info = await container.read(diskSpaceServiceProvider).query(path);
      return jsonOk({
        'configured': true,
        'path': info.path,
        'totalBytes': info.totalBytes,
        'freeBytes': info.freeBytes,
        'sampledAt': info.sampledAt.toUtc().toIso8601String(),
      });
    } on DiskSpaceException catch (e) {
      return jsonError(
        code: 'disk_query_failed',
        message: e.message,
        details: {'path': path},
      );
    }
  }

  /// `GET /api/info` — server discovery envelope. Returns the build
  /// version, API-version envelope, fingerprint, paired/scoped auth
  /// metadata, the replay-buffer cursor, and the full endpoint
  /// catalog so a remote client can render its capabilities map
  /// without polling individual probes.
  Future<Response> handleInfo(Request request) async {
    final platformCapabilities = PlatformCapabilityMatrix.forPlatform(
      Platform.operatingSystem,
    );
    final versionInfo = container.read(appVersionProvider);
    final dashboardAvailable = staticFileHandlers.dashboardAvailable;

    return jsonOk({
      'name': 'Skotiq Headless',
      'version': versionInfo.version,
      'apiVersion': RemoteApiCompatibility.serverApiVersion.format(),
      'minimumSupportedApiVersion': RemoteApiCompatibility
          .minimumSupportedVersion
          .format(),
      'apiVersionHeader': RemoteApiCompatibility.apiVersionHeader,
      'mode': 'headless',
      'platform': platformCapabilities.platform,
      'platformCapabilities': platformCapabilities.toJson(),
      'authRequired': view.authRequired(),
      'authenticationMode': view.authRequired() ? 'token' : 'none',
      'authScopes': view.availableAuthScopes(),
      'pairingSupported': true,
      // Pairing policy so the client knows whether to one-tap LAN-claim or
      // prompt for a code. `lanPairing` is the convenience boolean.
      'pairingMode': view.pairingModeWire(),
      'lanPairing': view.pairingModeWire() == 'lan-open',
      // Remote-access identifiers surfaced so the client never has to read them
      // off the appliance's terminal. Null/omitted when not applicable.
      if (view.tailscaleHost() != null) 'tailscaleHost': view.tailscaleHost(),
      if (view.relayApplianceId() != null)
        'relayApplianceId': view.relayApplianceId(),
      'fingerprint': view.fingerprint(),
      // surface the sequencing + replay state so a reconnecting
      // client can decide between `?since=` replay and a full
      // `/api/run-watch/snapshot` rehydrate without guessing.
      'serverInstanceId': view.instanceId(),
      'currentEventSeq': view.currentEventSeq(),
      'eventReplayBufferSize': view.eventReplayBufferSize(),
      'eventReplayBufferOldestSeq': view.eventReplayBufferOldestSeq(),
      'apiOnlyMode': true,
      'webUIAvailable': dashboardAvailable,
      // Read straight off the declaration the auth middleware enforces, so
      // the catalog cannot drift from what the server actually serves without
      // a token. A subtree root (`/dashboard`, `/run-watch`) stands for the
      // whole SPA bundle; the `/api/run-watch/*` data endpoints behind it
      // still require a bearer token.
      'publicEndpoints': publishedPublicEndpoints(),
      'endpoints': availableHeadlessEndpoints(),
    }, headers: _apiCompatibilityHeaders());
  }

  /// `GET /api/status` — sequencer state snapshot. Mobile clients poll
  /// this every second or so to render the run badge; keep the
  /// envelope small to keep the poll loop cheap.
  Future<Response> handleStatus(Request request) async {
    final requestId = requestIdFrom(request);
    _logInfo('[API][$requestId] GET /api/status');
    try {
      final backend = container.read(sequencerBackendProvider);
      final status = await backend.sequencerGetStatus();
      return jsonOk({
        "sequencer": {
          "state": status.state,
          "currentNodeId": status.currentNodeId,
          "currentNodeName": status.currentNodeName,
          "progress": status.progress,
          "message": status.message,
        },
      });
    } catch (e, stackTrace) {
      _logError('[API][$requestId] Status error: $e\n$stackTrace');
      return jsonInternalServerError({"error": "Internal server error"});
    }
  }

  /// `GET /api/self-test` — release-quality probe. Walks the storage
  /// directories (write-then-delete a probe file), confirms the Drift
  /// database provider is initialised, fires a 2s-timeout
  /// connected-device probe at the backend, and returns the aggregate
  /// in a single envelope.
  Future<Response> handleSelfTest(Request request) async {
    final requestId = requestIdFrom(request);
    _logInfo('[API][$requestId] GET /api/self-test');
    try {
      final platformCapabilities = PlatformCapabilityMatrix.forPlatform(
        Platform.operatingSystem,
      );
      // A-12: self-test needs `backend.runtimeType` to report which backend
      // implementation is active (FfiBackend / NetworkBackend / Disconnected).
      // Role providers all return the same instance widened to a role
      // interface, so the concrete-type query stays on backendProvider.
      final backend = container.read(backendProvider);
      final storageChecks = await _runStorageSelfTests();
      final databaseCheck = _runDatabaseSelfTest();
      final connectedDeviceProbe = await _probeConnectedDevices(backend);
      final endpointCount = availableHeadlessEndpoints().length;

      final checks = [
        ...storageChecks.map((check) => check['status']),
        databaseCheck['status'],
        connectedDeviceProbe['status'],
      ];
      final hasFailures = checks.contains('error');

      return jsonOk({
        'status': hasFailures ? 'degraded' : 'ok',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'platform': {
          'operatingSystem': platformCapabilities.platform,
          'operatingSystemVersion': Platform.operatingSystemVersion,
          'executable': Platform.resolvedExecutable,
        },
        'server': {
          'port': view.port(),
          'bindMode': view.bindLocalOnly() ? 'loopback' : 'lan',
          'authMode': view.authRequired() ? 'token' : 'none',
          'authRequired': view.authRequired(),
          'authScopes': view.availableAuthScopes(),
          'dashboardAvailable': staticFileHandlers.dashboardAvailable,
        },
        'backend': {
          'type': backend.runtimeType.toString(),
          'connectedDevices': connectedDeviceProbe,
        },
        'deviceDrivers': platformCapabilities.toJson(),
        'storagePaths': storageChecks,
        'database': databaseCheck,
        'api': {
          'endpointCount': endpointCount,
          'selfTestEndpoint': 'GET /api/self-test',
        },
      });
    } catch (e, stackTrace) {
      _logError('[API][$requestId] Self-test error: $e\n$stackTrace');
      return jsonInternalServerError({'error': 'Internal server error'});
    }
  }

  /// `GET /api/openapi.json` — OpenAPI 3 spec generated from the
  /// canonical endpoint list. Consumers (the audit, the dashboard
  /// route-table validator, external client generators) all read this
  /// rather than re-deriving the list from the source.
  Future<Response> handleOpenApiSpec(Request request) async {
    final requestId = requestIdFrom(request);
    _logInfo('[API][$requestId] GET /api/openapi.json');
    try {
      return jsonOk(
        route_metadata.buildOpenApiSpec(
          routes: availableHeadlessEndpoints(),
          port: view.port(),
        ),
      );
    } catch (e, stackTrace) {
      _logError('[API][$requestId] OpenAPI generation error: $e\n$stackTrace');
      return jsonInternalServerError({'error': 'Internal server error'});
    }
  }

  Map<String, String> _apiCompatibilityHeaders() {
    return {
      RemoteApiCompatibility.apiVersionHeader: RemoteApiCompatibility
          .serverApiVersion
          .format(),
      'x-skotiq-minimum-api-version': RemoteApiCompatibility
          .minimumSupportedVersion
          .format(),
    };
  }

  Map<String, dynamic> _runDatabaseSelfTest() {
    try {
      container.read(databaseProvider);
      return {
        'name': 'driftDatabase',
        'status': 'ok',
        'message': 'Database provider is initialized.',
      };
    } catch (e) {
      return {
        'name': 'driftDatabase',
        'status': 'error',
        // Sanitized: the failing check is identified by name+status; the raw
        // exception is not surfaced on the health endpoint.
        'message': 'Database provider check failed.',
      };
    }
  }

  Future<Map<String, dynamic>> _probeConnectedDevices(
    SkotiqBackend backend,
  ) async {
    try {
      final devices = await backend.getConnectedDevices().timeout(
        const Duration(seconds: 2),
      );
      return {
        'status': 'ok',
        'count': devices.length,
        'devices': devices.map((device) => device.toJson()).toList(),
      };
    } catch (e) {
      return {
        'status': 'warning',
        'count': null,
        'devices': <Map<String, dynamic>>[],
        'message': 'Connected-device probe unavailable: $e',
      };
    }
  }

  Future<List<Map<String, dynamic>>> _runStorageSelfTests() async {
    final checks = <Map<String, dynamic>>[];

    Future<void> addDirectoryCheck(
      String name,
      Future<Directory> Function() resolver,
    ) async {
      try {
        final directory = await resolver();
        checks.add(await _checkWritableDirectory(name, directory));
      } catch (e) {
        checks.add({
          'name': name,
          'status': 'error',
          'path': null,
          'exists': false,
          'writable': false,
          // Sanitized: the check is identified by name+status; the raw
          // exception is not surfaced on the health endpoint.
          'message': 'Directory check failed.',
        });
      }
    }

    await addDirectoryCheck(
      'applicationDocuments',
      resolveSkotiqDocumentsDirectory,
    );
    await addDirectoryCheck(
      'applicationSupport',
      resolveSkotiqDataDirectory,
    );
    await addDirectoryCheck('systemTemp', () async => Directory.systemTemp);

    return checks;
  }

  Future<Map<String, dynamic>> _checkWritableDirectory(
    String name,
    Directory directory,
  ) async {
    final exists = await directory.exists();
    if (!exists) {
      return {
        'name': name,
        'status': 'error',
        'path': directory.path,
        'exists': false,
        'writable': false,
        'message': 'Directory does not exist.',
      };
    }

    final probeFile = File(
      p.join(
        directory.path,
        '.skotiq-self-test-${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      await probeFile.writeAsString('ok');
      await probeFile.delete();
      return {
        'name': name,
        'status': 'ok',
        'path': directory.path,
        'exists': true,
        'writable': true,
      };
    } catch (e) {
      // Best-effort cleanup of a half-written probe file. We capture
      // the cleanup error (rather than silently swallowing it) because
      // a probe that leaves debris is itself a defect worth surfacing
      // — the operator's storage-write self-test should not lie about
      // a clean teardown.
      String? cleanupNote;
      try {
        if (await probeFile.exists()) {
          await probeFile.delete();
        }
      } catch (cleanupErr) {
        cleanupNote =
            ' (cleanup of probe file failed: $cleanupErr — manual removal may '
            'be required at ${probeFile.path})';
      }
      return {
        'name': name,
        'status': 'error',
        'path': directory.path,
        'exists': true,
        'writable': false,
        // Sanitized: report the writability failure without leaking the raw
        // exception; the optional cleanup note (a path hint) is retained.
        'message': 'Directory is not writable.${cleanupNote ?? ''}',
      };
    }
  }
}

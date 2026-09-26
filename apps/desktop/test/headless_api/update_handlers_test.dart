// UpdateHandlers test suite.
//
// Uses a fake [UpdateController] that records calls and drives the
// `events` stream directly, so the test never touches disk, `Process.start`,
// or the network. The fake mirrors the production controller's surface
// 1:1 so a regression in the contract is caught at compile time, not at
// runtime.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_desktop/headless_api/auth_policy.dart';
import 'package:nightshade_desktop/headless_api/handlers/update_handlers.dart';
import 'package:nightshade_desktop/headless_api/job_manager.dart';
import 'package:nightshade_desktop/headless_api_server.dart';
import 'package:nightshade_updater/nightshade_updater.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// Records every call so the test can assert exactly which controller
/// methods the handler hit and with what arguments.
class _FakeUpdateController implements UpdateController {
  final StreamController<UpdateEvent> _events =
      StreamController<UpdateEvent>.broadcast();

  UpdateControllerStatus _status = const UpdateControllerStatus(
    state: UpdateLifecycleState.idle,
  );

  // Recorded calls.
  final List<String?> checkChannels = [];
  final List<String> downloadJobIds = [];
  final List<String> applyJobIds = [];
  final List<String> rollbackJobIds = [];
  int abortCalls = 0;
  int discardCalls = 0;

  // Configurable behaviour for individual tests.
  UpdateCheckOutcome checkOutcome = const UpdateCheckOutcome(available: false);
  Object? checkError;
  Object? downloadError;
  bool rollbackSupportedReturn = false;
  bool canAuthenticateUpdatesReturn = true;
  StagedUpdateInfo? stagedInfo;
  String? serverUrl = 'https://updates.example.com';

  @override
  Stream<UpdateEvent> get events => _events.stream;

  /// Drive synthetic events through the stream (used by the broadcast
  /// test).
  void emit(UpdateEvent event) => _events.add(event);

  void setStatus(UpdateControllerStatus next) => _status = next;

  @override
  UpdateControllerStatus get status => _status;

  @override
  String get currentVersion => '2.6.0';

  @override
  int get currentBuildNumber => 6;

  @override
  String get channel => 'stable';

  @override
  String? get updateServerUrl => serverUrl;

  @override
  String get updateSourceLabel =>
      serverUrl?.isNotEmpty == true ? serverUrl! : 'github-releases';

  @override
  DateTime? get lastUpdateCheck => DateTime.utc(2026, 5, 24, 12, 0);

  @override
  DateTime? get lastUpdateApplied => null;

  @override
  bool get canAuthenticateUpdates => canAuthenticateUpdatesReturn;

  @override
  bool get hasActiveOperation =>
      _status.state == UpdateLifecycleState.checking ||
      _status.state == UpdateLifecycleState.downloading ||
      _status.state == UpdateLifecycleState.verifying ||
      _status.state == UpdateLifecycleState.cancelling ||
      _status.state == UpdateLifecycleState.installing;

  @override
  Future<UpdateCheckOutcome> checkForUpdates({String? channelOverride}) async {
    checkChannels.add(channelOverride);
    if (checkError != null) throw checkError!;
    return checkOutcome;
  }

  @override
  Future<void> downloadAndStage({required String jobId}) async {
    downloadJobIds.add(jobId);
    if (downloadError != null) throw downloadError!;
  }

  @override
  Future<void> applyStagedUpdate({required String jobId}) async {
    applyJobIds.add(jobId);
    // Don't actually exit; tests assert the side-effects directly.
  }

  @override
  void abortInFlight() {
    abortCalls++;
    if (_status.state != UpdateLifecycleState.checking &&
        _status.state != UpdateLifecycleState.downloading) {
      throw StateError(
        'No update operation is currently in flight (state=${_status.state.wireName}).',
      );
    }
    _status = const UpdateControllerStatus(state: UpdateLifecycleState.idle);
  }

  @override
  Future<StagedUpdateInfo?> stagedUpdate() async => stagedInfo;

  @override
  Future<void> discardStaged() async {
    discardCalls++;
    stagedInfo = null;
    _status = const UpdateControllerStatus(state: UpdateLifecycleState.idle);
  }

  @override
  Future<bool> rollbackSupported() async => rollbackSupportedReturn;

  @override
  Future<void> rollback({required String jobId}) async {
    rollbackJobIds.add(jobId);
    if (!rollbackSupportedReturn) {
      throw UnsupportedError('rollback not supported in fake');
    }
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }

  // Handlers under test never call `bootstrap`; the real controller hydrates
  // state from disk here. The fake is configured directly via [setStatus] /
  // field assignments, so this is a no-op.
  @override
  Future<void> bootstrap() async {}
}

Future<void> _pumpUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('pumpUntil predicate did not become true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  group('UpdateHandlers (unit)', () {
    late _FakeUpdateController controller;
    late JobManager jobManager;
    late UpdateHandlers handlers;

    setUp(() {
      controller = _FakeUpdateController();
      jobManager = JobManager(emitEvent: (_) {});
      handlers = UpdateHandlers(controller: controller, jobManager: jobManager);
    });

    tearDown(() async {
      await jobManager.dispose();
      await controller.dispose();
    });

    test('GET /api/system/version returns current build info', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetVersion(
          Request('GET', Uri.parse('http://localhost/api/system/version')),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['currentVersion'], '2.6.0');
      expect(body['buildNumber'], 6);
      expect(body['channel'], 'stable');
      expect(body['platform'], isA<String>());
      expect(body['updateServerUrl'], 'https://updates.example.com');
      expect(body['updateSource'], 'https://updates.example.com');
      expect(body['lastUpdateCheck'], isA<String>());
    });

    test(
      'a host reading GitHub releases names that source, not an empty one',
      () async {
        // A null updateServerUrl used to be the client's only signal, and it
        // rendered as "No update server configured" — telling the operator
        // OTA was off on a rig that updates perfectly well.
        controller.serverUrl = null;
        final response = await translateHandlerErrors(
          handlers.handleGetVersion(
            Request('GET', Uri.parse('http://localhost/api/system/version')),
          ),
        );
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body.containsKey('updateServerUrl'), isFalse);
        expect(body['updateSource'], 'github-releases');
      },
    );

    test(
      'GET /api/system/version never exposes URL credentials or tokens',
      () async {
        controller.serverUrl =
            'https://user:password@updates.example.com/feed?token=secret#private';

        final response = await translateHandlerErrors(
          handlers.handleGetVersion(
            Request('GET', Uri.parse('http://localhost/api/system/version')),
          ),
        );
        final body = jsonDecode(await response.readAsString()) as Map;

        expect(body['updateServerUrl'], 'https://updates.example.com/feed');
        expect(jsonEncode(body), isNot(contains('password')));
        expect(jsonEncode(body), isNot(contains('secret')));
      },
    );

    test('POST /api/system/update/check returns a queued jobId', () async {
      controller.checkOutcome = const UpdateCheckOutcome(
        available: true,
        latestVersion: '2.7.0',
        latestBuildNumber: 7,
        downloadUrl: 'https://example.com/update.zip',
        downloadSize: 1024,
      );

      final response = await translateHandlerErrors(
        handlers.handleCheckForUpdate(
          Request(
            'POST',
            Uri.parse('http://localhost/api/system/update/check'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final jobId = body['jobId'] as String;
      expect(jobId, isNotEmpty);
      expect(body['status'], anyOf('queued', 'running'));

      await _pumpUntil(
        () => jobManager.get(jobId)?.state == JobState.succeeded,
      );
      final job = jobManager.get(jobId)!;
      expect(job.operation, 'system.update.check');
      expect(job.result, isNotNull);
      expect(job.result!['available'], true);
      expect(job.result!['latestVersion'], '2.7.0');
      expect(controller.checkChannels, [null]);
    });

    test(
      'a second update command is rejected while the first is queued',
      () async {
        final first = await handlers.handleCheckForUpdate(
          Request(
            'POST',
            Uri.parse('http://localhost/api/system/update/check'),
          ),
        );
        expect(first.statusCode, HttpStatus.ok);

        final second = await handlers.handleDownload(
          Request(
            'POST',
            Uri.parse('http://localhost/api/system/update/download'),
          ),
        );
        expect(second.statusCode, HttpStatus.conflict);
        final body = jsonDecode(await second.readAsString()) as Map;
        expect(body['error'], 'update_operation_in_progress');
        expect(body['jobId'], isNotEmpty);

        final firstBody = jsonDecode(await first.readAsString()) as Map;
        await _pumpUntil(
          () =>
              jobManager.get(firstBody['jobId'] as String)?.state.isTerminal ??
              false,
        );
      },
    );

    test('POST /api/system/update/check honours ?channel= override', () async {
      controller.checkOutcome = const UpdateCheckOutcome(available: false);

      final response = await translateHandlerErrors(
        handlers.handleCheckForUpdate(
          Request(
            'POST',
            Uri.parse('http://localhost/api/system/update/check?channel=beta'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final jobId = body['jobId'] as String;
      await _pumpUntil(
        () => jobManager.get(jobId)?.state == JobState.succeeded,
      );
      expect(controller.checkChannels, ['beta']);
    });

    test('GET /api/system/update/status reflects the current phase', () async {
      controller.rollbackSupportedReturn = true;
      controller.canAuthenticateUpdatesReturn = false;
      controller.setStatus(
        UpdateControllerStatus(
          state: UpdateLifecycleState.downloading,
          availableVersion: '2.7.0',
          availableBuildNumber: 7,
          progressPct: 0.42,
          message: 'Downloading 2.7.0',
          stagedVersion: null,
          stagedAt: DateTime.utc(2026, 5, 24, 12),
        ),
      );

      final response = await translateHandlerErrors(
        handlers.handleGetStatus(
          Request(
            'GET',
            Uri.parse('http://localhost/api/system/update/status'),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['state'], 'downloading');
      expect(body['progressPct'], 0.42);
      expect(body['message'], 'Downloading 2.7.0');
      expect(body['availableVersion'], '2.7.0');
      expect(body['availableBuildNumber'], 7);
      expect(body['rollbackAvailable'], isTrue);
      expect(body['canAuthenticateUpdates'], isFalse);
    });

    test(
      'GET /api/system/update/staged returns null when nothing is staged',
      () async {
        controller.stagedInfo = null;
        final response = await translateHandlerErrors(
          handlers.handleGetStaged(
            Request(
              'GET',
              Uri.parse('http://localhost/api/system/update/staged'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['staged'], isNull);
      },
    );

    test(
      'GET /api/system/update/staged returns the snapshot when staged',
      () async {
        controller.stagedInfo = StagedUpdateInfo(
          stagedVersion: '2.7.0',
          stagedBuildNumber: 7,
          stagedAt: DateTime.utc(2026, 5, 24, 12),
          fileCount: 3,
          totalBytes: 4096,
          expectedHashes: const {'app.exe': 'deadbeef'},
          manifestHash: 'cafef00d',
        );
        final response = await translateHandlerErrors(
          handlers.handleGetStaged(
            Request(
              'GET',
              Uri.parse('http://localhost/api/system/update/staged'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final staged = body['staged'] as Map;
        expect(staged['stagedVersion'], '2.7.0');
        expect(staged['fileCount'], 3);
        expect(staged['totalBytes'], 4096);
        expect(staged['expectedHashes'], {'app.exe': 'deadbeef'});
        expect(staged['manifestHash'], 'cafef00d');
      },
    );

    test(
      'DELETE /api/system/update/staged removes the staged update',
      () async {
        controller.stagedInfo = StagedUpdateInfo(
          stagedVersion: '2.7.0',
          stagedBuildNumber: 7,
          stagedAt: DateTime.utc(2026, 5, 24, 12),
          fileCount: 1,
          totalBytes: 1024,
          expectedHashes: const {},
        );

        final response = await translateHandlerErrors(
          handlers.handleDiscardStaged(
            Request(
              'DELETE',
              Uri.parse('http://localhost/api/system/update/staged'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['discarded'], true);
        expect(controller.discardCalls, 1);
        expect(controller.stagedInfo, isNull);
      },
    );

    test(
      'POST /api/system/update/rollback returns 501 when no restore point',
      () async {
        controller.rollbackSupportedReturn = false;
        final response = await translateHandlerErrors(
          handlers.handleRollback(
            Request(
              'POST',
              Uri.parse('http://localhost/api/system/update/rollback'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.notImplemented);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'rollback_unavailable');
      },
    );

    test(
      'POST /api/system/update/rollback dispatches a job when available',
      () async {
        controller.rollbackSupportedReturn = true;
        final response = await translateHandlerErrors(
          handlers.handleRollback(
            Request(
              'POST',
              Uri.parse('http://localhost/api/system/update/rollback'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final jobId = body['jobId'] as String;
        await _pumpUntil(
          () => jobManager.get(jobId)?.state == JobState.succeeded,
        );
        // The controller must receive the SAME job id the handler returned, so
        // WS progress/completion events correlate with /api/jobs/{id} polling.
        expect(controller.rollbackJobIds, [jobId]);
      },
    );

    test(
      'POST /api/system/update/abort returns 409 when nothing is in flight',
      () async {
        controller.setStatus(
          const UpdateControllerStatus(state: UpdateLifecycleState.idle),
        );
        final response = await translateHandlerErrors(
          handlers.handleAbort(
            Request(
              'POST',
              Uri.parse('http://localhost/api/system/update/abort'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.conflict);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'no_update_in_flight');
      },
    );

    test('POST /api/system/update/abort cancels matching jobs', () async {
      controller.setStatus(
        const UpdateControllerStatus(state: UpdateLifecycleState.downloading),
      );
      // Pre-seed a download job that will hang so abort actually has
      // something to cancel.
      final waitForever = Completer<Map<String, Object?>>();
      final hung = jobManager.start(
        operation: 'system.update.download',
        work: (sink, cancellation) => waitForever.future,
      );
      await _pumpUntil(
        () => jobManager.get(hung.jobId)?.state == JobState.running,
      );

      final response = await translateHandlerErrors(
        handlers.handleAbort(
          Request(
            'POST',
            Uri.parse('http://localhost/api/system/update/abort'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['aborted'], true);
      expect(body['cancelledJobs'], contains(hung.jobId));
      expect(controller.abortCalls, 1);

      // Clean up the hanging job so the test process exits cleanly.
      waitForever.complete({'cancelled': true});
    });

    test('POST /api/system/update/download dispatches a job', () async {
      final response = await translateHandlerErrors(
        handlers.handleDownload(
          Request(
            'POST',
            Uri.parse('http://localhost/api/system/update/download'),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final jobId = body['jobId'] as String;
      await _pumpUntil(
        () => jobManager.get(jobId)?.state == JobState.succeeded,
      );
      expect(controller.downloadJobIds, [jobId]);
    });

    test(
      'POST /api/system/update/apply dispatches a job and signals restart',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleApply(
            Request(
              'POST',
              Uri.parse('http://localhost/api/system/update/apply'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['restartRequired'], true);
        final jobId = body['jobId'] as String;
        await _pumpUntil(
          () => jobManager.get(jobId)?.state == JobState.succeeded,
        );
        expect(controller.applyJobIds, [jobId]);
      },
    );
  });

  group('UpdateHandlers (scope enforcement)', () {
    late ProviderContainer container;
    late _FakeUpdateController fakeController;
    late HeadlessApiServer server;
    late HttpClient client;
    late Uri baseUri;

    setUp(() async {
      container = createHeadlessTestContainer(
        overrides: [
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '2.6.0', buildNumber: 6),
          ),
        ],
      );
      fakeController = _FakeUpdateController();
      server = HeadlessApiServer(
        port: 0,
        container: container,
        bindLocalOnly: true,
        authToken: 'admin-token',
        scopedAuthTokens: const {
          'view-token': HeadlessTokenScope.view,
          'control-token': HeadlessTokenScope.control,
        },
      );
      server.setUpdateController(fakeController);
      await server.start();
      client = HttpClient();
      baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');
    });

    tearDown(() async {
      client.close(force: true);
      server.setUpdateController(null);
      await server.stop();
      await fakeController.dispose();
      container.dispose();
    });

    Future<HttpClientResponse> send(
      String method,
      String path, {
      String? token,
    }) async {
      final req = await client.openUrl(method, baseUri.replace(path: path));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      return req.close();
    }

    test('POST /api/system/update/download requires admin scope', () async {
      final viewResp = await send(
        'POST',
        '/api/system/update/download',
        token: 'view-token',
      );
      expect(viewResp.statusCode, HttpStatus.forbidden);

      final controlResp = await send(
        'POST',
        '/api/system/update/download',
        token: 'control-token',
      );
      expect(controlResp.statusCode, HttpStatus.forbidden);

      final adminResp = await send(
        'POST',
        '/api/system/update/download',
        token: 'admin-token',
      );
      expect(adminResp.statusCode, HttpStatus.ok);
    });

    test('POST /api/system/update/apply requires admin scope', () async {
      final controlResp = await send(
        'POST',
        '/api/system/update/apply',
        token: 'control-token',
      );
      expect(controlResp.statusCode, HttpStatus.forbidden);

      final adminResp = await send(
        'POST',
        '/api/system/update/apply',
        token: 'admin-token',
      );
      expect(adminResp.statusCode, HttpStatus.ok);
    });

    test('DELETE /api/system/update/staged requires admin scope', () async {
      final controlResp = await send(
        'DELETE',
        '/api/system/update/staged',
        token: 'control-token',
      );
      expect(controlResp.statusCode, HttpStatus.forbidden);

      final adminResp = await send(
        'DELETE',
        '/api/system/update/staged',
        token: 'admin-token',
      );
      expect(adminResp.statusCode, HttpStatus.ok);
    });

    test('GET /api/system/version is reachable with view scope', () async {
      final viewResp = await send(
        'GET',
        '/api/system/version',
        token: 'view-token',
      );
      expect(viewResp.statusCode, HttpStatus.ok);
    });

    test('UpdateAvailable controller event reaches WS broadcast', () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.actualPort}/events'
        '?token=admin-token&apiVersion=2.6.0',
      );
      final received = <Map<String, dynamic>>[];
      final completer = Completer<Map<String, dynamic>>();
      final subscription = socket.listen((message) {
        if (message is! String) return;
        final decoded = jsonDecode(message);
        if (decoded is! Map<String, dynamic>) return;
        received.add(decoded);
        if (decoded['type'] == 'event' &&
            decoded['eventType'] == 'UpdateAvailable' &&
            !completer.isCompleted) {
          completer.complete(decoded);
        }
      });

      // Wait briefly so the server processes the WS upgrade.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      fakeController.emit(
        const UpdateAvailableEvent(
          currentVersion: '2.6.0',
          latestVersion: '2.7.0',
          downloadUrl: 'https://example.com/update.zip',
        ),
      );

      try {
        final event = await completer.future.timeout(
          const Duration(seconds: 3),
        );
        expect(event['category'], 'system');
        expect(event['eventType'], 'UpdateAvailable');
        expect(event['seq'], isA<int>());
        expect(event['serverInstanceId'], isA<String>());
        expect((event['data'] as Map)['latestVersion'], '2.7.0');
      } finally {
        await subscription.cancel();
        await socket.close();
      }
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api/handlers/imaging_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:skotiq_desktop/headless_api/request_context.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('ImagingHandlers', () {
    late ProviderContainer container;
    late ImagingHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = ImagingHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('star crops missing device ID returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetStarCrops(
          Request('GET', Uri.parse('http://localhost/api/imaging/star-crops')),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], "Missing 'deviceId' query parameter");
    });

    test(
      'plate-solver config accepts empty paths so an ASTAP-only rig can save',
      () async {
        // Reproduced against a live appliance: setting the ASTAP catalog
        // directory from a paired remote client died with
        // 400 invalid_request on astrometryPath, which was empty because no
        // Astrometry.net is installed. GET returns astrometryPath:"" for that
        // rig, so requiring non-empty made the document the API serves one it
        // refuses to accept back, and the setting could never be saved.
        final backend = _RecordingPlateSolverBackend();
        final local = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(local.dispose);
        final localHandlers = ImagingHandlers(local);

        final response = await translateHandlerErrors(
          localHandlers.handleSetPlateSolverConfig(
            Request(
              'POST',
              Uri.parse('http://localhost/api/plate-solver/config'),
              body: jsonEncode({
                'astapPath': '/opt/astap/astap',
                'astrometryPath': '',
                'catalogPath': '/opt/astap/catalogs',
                'solverChoice': 'astap',
              }),
              context: _grant(HeadlessTokenScope.admin),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(backend.saved?.catalogPath, '/opt/astap/catalogs');
        expect(backend.saved?.astrometryPath, '');
      },
    );

    test('plate-solver config still requires a solver choice', () async {
      final backend = _RecordingPlateSolverBackend();
      final local = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(local.dispose);
      final localHandlers = ImagingHandlers(local);

      final response = await translateHandlerErrors(
        localHandlers.handleSetPlateSolverConfig(
          Request(
            'POST',
            Uri.parse('http://localhost/api/plate-solver/config'),
            body: jsonEncode({
              'astapPath': '',
              'astrometryPath': '',
              'catalogPath': '',
              'solverChoice': '',
            }),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(backend.saved, isNull);
    });

    group('the programs the host runs', () {
      late _RecordingPlateSolverBackend backend;
      late ImagingHandlers localHandlers;

      setUp(() {
        backend = _RecordingPlateSolverBackend()
          ..saved = const PlateSolverPreference(
            astapPath: '/opt/astap/astap',
            choice: PlateSolverChoice.astap,
          );
        final local = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(local.dispose);
        localHandlers = ImagingHandlers(local);
      });

      Future<Response> saveConfig(
        HeadlessTokenScope scope, {
        required String astapPath,
        String catalogPath = '',
        String solverChoice = 'astap',
      }) => translateHandlerErrors(
        localHandlers.handleSetPlateSolverConfig(
          Request(
            'POST',
            Uri.parse('http://localhost/api/plate-solver/config'),
            body: jsonEncode({
              'astapPath': astapPath,
              'astrometryPath': '',
              'catalogPath': catalogPath,
              'solverChoice': solverChoice,
            }),
            context: _grant(scope),
          ),
        ),
      );

      Future<Response> verify(HeadlessTokenScope scope, String path) =>
          translateHandlerErrors(
            localHandlers.handleVerifyPlateSolver(
              Request(
                'POST',
                Uri.parse('http://localhost/api/plate-solver/verify'),
                body: jsonEncode({'executablePath': path}),
                context: _grant(scope),
              ),
            ),
          );

      test('a link without admin access keeps the solver path but changes '
          'the rest of the solver setup', () async {
        var response = await saveConfig(
          HeadlessTokenScope.control,
          astapPath: '/tmp/not-astap',
        );
        expect(response.statusCode, HttpStatus.forbidden);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['code'], 'host_program_setting');
        expect(body['settings'], ['astapPath']);
        expect(backend.saved?.astapPath, '/opt/astap/astap');

        response = await saveConfig(
          HeadlessTokenScope.control,
          astapPath: '/opt/astap/astap',
          catalogPath: '/opt/astap/d50',
          solverChoice: 'auto',
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(backend.saved?.catalogPath, '/opt/astap/d50');
        expect(backend.saved?.choice, PlateSolverChoice.auto);

        response = await saveConfig(
          HeadlessTokenScope.admin,
          astapPath: '/usr/local/bin/astap',
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(backend.saved?.astapPath, '/usr/local/bin/astap');
      });

      test('a link without admin access verifies only the solvers the host '
          'is set to use', () async {
        var response = await verify(HeadlessTokenScope.control, '/usr/bin/id');
        expect(response.statusCode, HttpStatus.forbidden);
        expect(backend.verified, isEmpty);

        response = await verify(HeadlessTokenScope.control, '/opt/astap/astap');
        expect(response.statusCode, HttpStatus.ok);
        response = await verify(HeadlessTokenScope.control, '/detected/solve');
        expect(response.statusCode, HttpStatus.ok);
        response = await verify(HeadlessTokenScope.admin, '/usr/bin/id');
        expect(response.statusCode, HttpStatus.ok);
        expect(backend.verified, [
          '/opt/astap/astap',
          '/detected/solve',
          '/usr/bin/id',
        ]);
      });
    });

    test(
      'star crops validates maxCrops and trims deviceId before backend work',
      () async {
        final backend = _StarCropBackend();
        final local = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(local.dispose);
        final localHandlers = ImagingHandlers(local);

        for (final raw in ['abc', '0', '-1', '201', '1.5']) {
          final response = await translateHandlerErrors(
            localHandlers.handleGetStarCrops(
              Request(
                'GET',
                Uri.parse(
                  'http://localhost/api/imaging/star-crops?deviceId=cam-1'
                  '&maxCrops=${Uri.encodeQueryComponent(raw)}',
                ),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: raw);
        }
        expect(backend.calls, 0);

        final blank = await translateHandlerErrors(
          localHandlers.handleGetStarCrops(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/imaging/star-crops?deviceId=%20%20',
              ),
            ),
          ),
        );
        expect(blank.statusCode, HttpStatus.badRequest);
        expect(backend.calls, 0);

        final valid = await translateHandlerErrors(
          localHandlers.handleGetStarCrops(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/imaging/star-crops'
                '?deviceId=%20cam-1%20&maxCrops=200',
              ),
            ),
          ),
        );
        expect(valid.statusCode, HttpStatus.ok);
        expect(backend.calls, 1);
        expect(backend.deviceId, 'cam-1');
        expect(backend.maxCrops, 200);
      },
    );

    test('plate solve malformed payload returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handlePlateSolve(
          Request(
            'POST',
            Uri.parse('http://localhost/api/plate-solve'),
            body: jsonEncode({}),
          ),
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test(
      'raw image invalid backend call returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleGetLastRawImageData(
            Request(
              'GET',
              Uri.parse('http://localhost/api/imaging/raw?deviceId=camera-1'),
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test('raw image serializes every pixel as little-endian u16', () async {
      final backend = _RawImageBackend([0, 1, 255, 256, 0x1234, 0xffff]);
      final local = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(local.dispose);
      final response = await ImagingHandlers(local).handleGetLastRawImageData(
        Request(
          'GET',
          Uri.parse('http://localhost/api/imaging/raw-data?deviceId=camera-1'),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/octet-stream');
      expect(response.headers['content-length'], '12');
      expect(await response.read().expand((chunk) => chunk).toList(), [
        0x00,
        0x00,
        0x01,
        0x00,
        0xff,
        0x00,
        0x00,
        0x01,
        0x34,
        0x12,
        0xff,
        0xff,
      ]);
      expect(backend.deviceId, 'camera-1');
    });

    test('save from capture creates host parent directories first', () async {
      final backend = _SaveFitsBackend();
      final root = await Directory.systemTemp.createTemp('skotiq-save-fits-');
      addTearDown(() => root.delete(recursive: true));
      final local = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(
            () => _TestSettingsWithOutputPath(root.path),
          ),
        ],
      );
      addTearDown(local.dispose);
      await local.read(appSettingsProvider.future);
      final localHandlers = ImagingHandlers(local);
      final filePath = '${root.path}/2026-07-13/L/flat-1.fits';

      final response = await translateHandlerErrors(
        localHandlers.handleSaveFitsFromLastCapture(
          Request(
            'POST',
            Uri.parse('http://localhost/api/imaging/save-fits-from-capture'),
            body: jsonEncode({
              'deviceId': 'camera-1',
              'filePath': filePath,
              'headerData': {
                'frameType': 'FLAT',
                'filter': 'L',
                'exposureTime': 1.5,
                'captureTimestamp': '2026-07-13T01:00:00Z',
              },
            }),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(backend.filePath, filePath);
      expect(backend.parentExistedAtSave, isTrue);
    });

    test(
      'a desktop host shows a remote client capture in its own image view',
      () async {
        final backend = _SaveFitsBackend();
        final publisher = _RecordingPublisher();
        final root = await Directory.systemTemp.createTemp('skotiq-save-fits-');
        addTearDown(() => root.delete(recursive: true));
        ProviderContainer hostContainer() {
          final c = ProviderContainer(
            overrides: [
              backendProvider.overrideWith(
                (ref) => _TestBackendNotifier(ref, backend),
              ),
              appSettingsProvider.overrideWith(
                () => _TestSettingsWithOutputPath(root.path),
              ),
              capturePreviewPublisherProvider.overrideWithValue(publisher),
            ],
          );
          addTearDown(c.dispose);
          return c;
        }

        Request saveRequest() => Request(
          'POST',
          Uri.parse('http://localhost/api/imaging/save-fits-from-capture'),
          body: jsonEncode({
            'deviceId': 'camera-1',
            'filePath': '${root.path}/NGC0891_L_0001.fits',
            'headerData': {
              'objectName': 'NGC0891',
              'frameType': 'Light',
              'filter': 'L',
              'gain': 139,
              'offset': 21,
              'exposureTime': 120.0,
              'captureTimestamp': '2026-10-21T23:50:25.000Z',
            },
          }),
        );

        // A headless host has no image view to feed.
        final headless = hostContainer();
        await headless.read(appSettingsProvider.future);
        await ImagingHandlers(
          headless,
        ).handleSaveFitsFromLastCapture(saveRequest());
        await Future<void>.delayed(Duration.zero);
        expect(publisher.published, isEmpty);

        final desktop = hostContainer();
        await desktop.read(appSettingsProvider.future);
        final response = await ImagingHandlers(
          desktop,
          showApiCapturesInPreview: true,
        ).handleSaveFitsFromLastCapture(saveRequest());
        expect(response.statusCode, HttpStatus.ok);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(backend.calls, 2, reason: 'the frame is saved once per call');
        expect(publisher.published, hasLength(1));
        final (image, deviceId) = publisher.published.single;
        expect(deviceId, 'camera-1');
        expect(
          publisher.loadRawFlags.single,
          isTrue,
          reason: 'the host has the pixels on disk, so it loads them',
        );
        expect(image.filePath, backend.filePath);
        expect(image.width, 4);
        expect(image.capturedAt, DateTime.utc(2026, 10, 21, 23, 50, 25));
        expect(image.targetName, 'NGC0891');
        expect(image.settings.exposureTime, 120.0);
        expect(image.settings.filter, 'L');
        expect(image.settings.gain, 139);
        expect(image.settings.frameType, FrameType.light);
      },
    );

    test('save from capture rejects paths outside configured roots', () async {
      final backend = _SaveFitsBackend();
      final allowedRoot = await Directory.systemTemp.createTemp(
        'skotiq-save-fits-allowed-',
      );
      final outsideRoot = await Directory.systemTemp.createTemp(
        'skotiq-save-fits-outside-',
      );
      addTearDown(() => allowedRoot.delete(recursive: true));
      addTearDown(() => outsideRoot.delete(recursive: true));
      final local = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(
            () => _TestSettingsWithOutputPath(allowedRoot.path),
          ),
        ],
      );
      addTearDown(local.dispose);
      await local.read(appSettingsProvider.future);
      final localHandlers = ImagingHandlers(local);
      final outsideParent = Directory('${outsideRoot.path}/unexpected');
      final filePath = '${outsideParent.path}/flat-1.fits';

      final response = await translateHandlerErrors(
        localHandlers.handleSaveFitsFromLastCapture(
          Request(
            'POST',
            Uri.parse('http://localhost/api/imaging/save-fits-from-capture'),
            body: jsonEncode({
              'deviceId': 'camera-1',
              'filePath': filePath,
              'headerData': {
                'frameType': 'FLAT',
                'exposureTime': 1.5,
                'captureTimestamp': '2026-07-13T01:00:00Z',
              },
            }),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.forbidden);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'path_not_allowed');
      expect(backend.calls, 0);
      expect(await outsideParent.exists(), isFalse);
    });

    // A solve that found nothing ended its job `succeeded` with
    // `success: false` inside the result, so the job list, the phone's
    // plate-solve failure notice and every client that trusts a job's state
    // read a failed solve as done.
    Future<Job> runPlateSolveJob(PlateSolveResult outcome) async {
      final backend = _PendingPlateSolveBackend();
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final jobContainer = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(_TestSettings.new),
        ],
      );
      addTearDown(jobContainer.dispose);
      final jobs = JobManager(emitEvent: (_) {});
      addTearDown(jobs.dispose);
      final jobHandlers = ImagingHandlers(jobContainer, jobManager: jobs);

      final response = await jobHandlers.handlePlateSolve(
        Request(
          'POST',
          Uri.parse('http://localhost/api/plate-solve'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'imagePath': '/tmp/frame.fits'}),
        ),
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      final jobId = body['jobId'] as String;
      await _pumpUntil(() => backend.started);
      backend.pending.complete(outcome);
      await _pumpUntil(() => jobs.get(jobId)!.state.isTerminal);
      return jobs.get(jobId)!;
    }

    test('a plate solve that finds no solution ends its job failed with the '
        'solver reason', () async {
      final job = await runPlateSolveJob(
        _solve(success: false, error: 'Not enough stars detected'),
      );

      expect(job.state, JobState.failed);
      expect(job.result, isNull);
      expect(job.error!['code'], 'plate_solve_failed');
      expect(job.error!['message'], contains('Not enough stars detected'));
      final details = job.error!['details'] as Map;
      expect(details['success'], isFalse);
    });

    test('a plate solve that solves ends its job succeeded', () async {
      final job = await runPlateSolveJob(_solve(success: true));

      expect(job.state, JobState.succeeded);
      expect(job.result!['success'], isTrue);
      expect(job.result!['ra'], 83.8);
    });

    test('canceled plate solve stays running until host work exits', () async {
      final backend = _PendingPlateSolveBackend();
      final jobContainer = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(_TestSettings.new),
        ],
      );
      addTearDown(jobContainer.dispose);
      final jobs = JobManager(emitEvent: (_) {});
      addTearDown(jobs.dispose);
      final jobHandlers = ImagingHandlers(jobContainer, jobManager: jobs);

      final response = await jobHandlers.handlePlateSolve(
        Request(
          'POST',
          Uri.parse('http://localhost/api/plate-solve'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'imagePath': '/tmp/pending.fits'}),
        ),
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      final jobId = body['jobId'] as String;
      await _pumpUntil(() => jobs.get(jobId)?.state == JobState.running);

      jobs.cancel(jobId);
      await Future<void>.delayed(Duration.zero);

      expect(backend.started, isTrue);
      expect(jobs.get(jobId)?.state, JobState.running);
    });
  });
}

PlateSolveResult _solve({required bool success, String? error}) =>
    PlateSolveResult(
      success: success,
      ra: success ? 83.8 : 0,
      dec: success ? -5.4 : 0,
      rotation: 0,
      pixelScale: success ? 1.2 : 0,
      fieldWidth: 1,
      fieldHeight: 1,
      solveTimeSecs: 1,
      error: error,
      cd11: 0,
      cd12: 0,
      cd21: 0,
      cd22: 0,
      sipAOrder: 0,
      sipBOrder: 0,
      sipACoeffs: Float64List(0),
      sipBCoeffs: Float64List(0),
      sipApOrder: 0,
      sipBpOrder: 0,
      sipApCoeffs: Float64List(0),
      sipBpCoeffs: Float64List(0),
    );

Future<void> _pumpUntil(bool Function() condition) async {
  // Deadline-based, not turn-counted: under a loaded full-suite run the
  // job's real async hops (path checks, isolate spawn) need wall-clock
  // time, and 100 zero-delay turns expire before `running` is reached.
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

Map<String, Object> _grant(HeadlessTokenScope scope) => {
  authGrantContextKey: HeadlessAuthGrant.fromCoarse(scope),
};

class _RecordingPlateSolverBackend extends DisconnectedBackend {
  PlateSolverPreference? saved;
  final List<String> verified = [];

  @override
  Future<void> setPlateSolverConfig(PlateSolverPreference pref) async {
    saved = pref;
  }

  @override
  Future<PlateSolverPreference> getPlateSolverConfig() async =>
      saved ?? const PlateSolverPreference(choice: PlateSolverChoice.auto);

  @override
  Future<PlateSolverDetection> detectPlateSolvers() async =>
      const PlateSolverDetection(astrometryPath: '/detected/solve');

  @override
  Future<PlateSolverInfo> verifyPlateSolver(String executablePath) async {
    verified.add(executablePath);
    return PlateSolverInfo(
      path: executablePath,
      flavour: 'astap',
      versionLine: 'ASTAP',
    );
  }
}

class _PendingPlateSolveBackend extends DisconnectedBackend {
  final Completer<PlateSolveResult> pending = Completer<PlateSolveResult>();
  bool started = false;

  @override
  Future<PlateSolverDetection> detectPlateSolvers() async {
    return const PlateSolverDetection(
      astapPath: '/tmp/astap',
      catalogPath: '/tmp/catalog',
    );
  }

  @override
  Future<PlateSolverPreference> getPlateSolverConfig() async {
    return const PlateSolverPreference(choice: PlateSolverChoice.astap);
  }

  @override
  Future<PlateSolveResult> plateSolve({
    required String imagePath,
    double? ra,
    double? dec,
    double? fovDegrees,
    int? timeoutSeconds,
  }) {
    started = true;
    return pending.future;
  }
}

class _StarCropBackend extends DisconnectedBackend {
  int calls = 0;
  String? deviceId;
  int? maxCrops;

  @override
  Future<List<StarCrop>> getStarCropsFromLastImage(
    String deviceId, {
    int maxCrops = 5,
  }) async {
    calls++;
    this.deviceId = deviceId;
    this.maxCrops = maxCrops;
    return const [];
  }
}

class _RawImageBackend extends DisconnectedBackend {
  _RawImageBackend(this.pixels);

  final List<int> pixels;
  String? deviceId;

  @override
  Future<List<int>> getLastRawImageData(String deviceId) async {
    this.deviceId = deviceId;
    return pixels;
  }
}

class _SaveFitsBackend extends DisconnectedBackend {
  String? filePath;
  bool parentExistedAtSave = false;
  int calls = 0;

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async =>
      const CapturedImageResult(
        width: 4,
        height: 2,
        displayData: [0, 1, 2, 3, 4, 5, 6, 7],
        histogram: [8],
        stats: ImageStatsResult(
          min: 0,
          max: 7,
          mean: 3.5,
          median: 3.5,
          stdDev: 2,
          starCount: 0,
        ),
        exposureTime: 120,
        timestamp: '2026-10-21T23:50:25.000Z',
      );

  @override
  Future<String> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
  }) async {
    calls++;
    this.filePath = filePath;
    parentExistedAtSave = File(filePath).parent.existsSync();
    return filePath;
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _TestSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

class _TestSettingsWithOutputPath extends AppSettingsNotifier {
  _TestSettingsWithOutputPath(this.outputPath);

  final String outputPath;

  @override
  Future<AppSettingsState> build() async =>
      AppSettingsState(imageOutputPath: outputPath);
}

class _RecordingPublisher extends CapturePreviewPublisher {
  final List<(CapturedImageData, String)> published = [];
  final List<bool> loadRawFlags = [];

  @override
  void publish(
    dynamic ref,
    CapturedImageData preview,
    String deviceId, {
    bool loadRaw = true,
  }) {
    published.add((preview, deviceId));
    loadRawFlags.add(loadRaw);
  }
}

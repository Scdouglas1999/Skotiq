import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/session_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionHandlers', () {
    late ProviderContainer container;
    late SessionHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = SessionHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('unsupported export format returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleExportSession(
          Request(
            'GET',
            Uri.parse('http://localhost/api/sessions/1/export/pdf'),
          ),
          '1',
          'pdf',
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'Unsupported export format');
      expect(body['supportedFormats'], ['json', 'csv', 'html']);
    });

    test('recent image limit rejects malformed and unsafe values', () async {
      for (final limit in const ['many', '0', '-1', '1001']) {
        final response = await translateHandlerErrors(
          handlers.handleGetRecentImages(
            Request(
              'GET',
              Uri.parse('http://localhost/api/images/recent?limit=$limit'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: limit);
      }
    });

    test(
      'start polar alignment malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleStartPolarAlignment(
            Request(
              'POST',
              Uri.parse('http://localhost/api/polar-alignment/start'),
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
      },
    );

    test(
      'polar Start awaits native admission even when jobs are wired',
      () async {
        final backend = _GatedPolarBackend();
        final polarContainer = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
            activeEquipmentProfileProvider.overrideWithValue(null),
          ],
        );
        addTearDown(polarContainer.dispose);
        final jobs = JobManager(emitEvent: (_) {});
        addTearDown(jobs.dispose);
        final polarHandlers = SessionHandlers(polarContainer, jobManager: jobs);

        var responseReturned = false;
        final responseFuture = polarHandlers
            .handleStartPolarAlignment(
              Request(
                'POST',
                Uri.parse('http://localhost/api/polar-alignment/start'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({
                  'exposure_time': 2.0,
                  'step_size': 10.0,
                  'binning': 1,
                  'is_north': true,
                  'manual_rotation': false,
                  'rotate_east': true,
                }),
              ),
            )
            .then((response) {
              responseReturned = true;
              return response;
            });
        await Future<void>.delayed(Duration.zero);

        expect(backend.startCalls, 1);
        expect(responseReturned, isFalse);
        expect(jobs.list(), isEmpty);

        backend.startGate.complete();
        final response = await responseFuture;
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body, {'status': 'started'});
      },
    );

    test('polar Start propagates native admission failure', () async {
      final backend = _GatedPolarBackend();
      final polarContainer = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          activeEquipmentProfileProvider.overrideWithValue(null),
        ],
      );
      addTearDown(polarContainer.dispose);
      final polarHandlers = SessionHandlers(polarContainer);

      final responseFuture = polarHandlers.handleStartPolarAlignment(
        Request(
          'POST',
          Uri.parse('http://localhost/api/polar-alignment/start'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'exposure_time': 2.0,
            'step_size': 10.0,
            'binning': 1,
            'is_north': true,
            'manual_rotation': false,
            'rotate_east': true,
          }),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      backend.startGate.completeError(StateError('native rejected start'));

      await expectLater(responseFuture, throwsA(isA<StateError>()));
    });

    test(
      'headless-owned run persists history after remote disconnect',
      () async {
        final backend = _EventedPolarBackend();
        addTearDown(backend.close);
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final hostContainer = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
            databaseProvider.overrideWithValue(db),
            activeEquipmentProfileProvider.overrideWithValue(null),
          ],
        );
        addTearDown(hostContainer.dispose);
        final hostHandlers = SessionHandlers(hostContainer);

        await hostHandlers.handleStartPolarAlignment(
          Request(
            'POST',
            Uri.parse('http://localhost/api/polar-alignment/start'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              'exposure_time': 2.0,
              'step_size': 10.0,
              'binning': 1,
              'is_north': true,
              'manual_rotation': false,
              'rotate_east': true,
              'auto_complete_threshold': 12.0,
            }),
          ),
        );
        expect(backend.autoCompleteThreshold, 12.0);

        backend.emitStatus('adjusting');
        await _pumpEvents();
        backend.emitError(azimuth: 120, altitude: -60, total: 134.16);
        await _pumpEvents();
        backend.emitError(azimuth: 8, altitude: -4, total: 8.94);
        await _pumpEvents();
        backend.emitStatus('complete', status: 'Threshold reached');

        List<PolarAlignmentHistoryEntry> rows = const [];
        for (var i = 0; i < 50 && rows.isEmpty; i++) {
          await Future<void>.delayed(Duration.zero);
          rows = await db.polarAlignmentHistoryDao.getHistoryForProfile(null);
        }
        expect(rows, hasLength(1));
        expect(rows.single.autoCompleted, isTrue);
        expect(rows.single.finalTotalError, closeTo(8.94, 1e-9));
      },
    );

    test('all-sky API cadence reaches hardware and recorded config', () async {
      final backend = _EventedPolarBackend();
      addTearDown(backend.close);
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final hostContainer = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          databaseProvider.overrideWithValue(db),
          activeEquipmentProfileProvider.overrideWithValue(null),
        ],
      );
      addTearDown(hostContainer.dispose);
      final hostHandlers = SessionHandlers(hostContainer);

      await hostHandlers.handleStartAllSkyPolarAlignment(
        Request(
          'POST',
          Uri.parse('http://localhost/api/polar-alignment/all-sky/start'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'exposure_time': 2.0,
            'solve_timeout': 20.0,
            'binning': 1,
            'is_north': false,
            'acceptance_threshold_arcsec': 18.0,
            'iteration_cadence_secs': 1.25,
          }),
        ),
      );

      expect(backend.allSkyCadence, 1.25);
      expect(backend.allSkyThreshold, 18.0);
      expect(
        hostContainer
            .read(polarAlignmentStateProvider)
            .config!
            .iterationCadenceSecs,
        1.25,
      );
      await hostHandlers.handleStopPolarAlignment(
        Request('POST', Uri.parse('http://localhost/api/polar-alignment/stop')),
      );
      expect(backend.stopCalls, 1);
    });

    test('thumbnail invalid image ID returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetImageThumbnail(
          Request(
            'GET',
            Uri.parse('http://localhost/api/images/nope/thumbnail'),
          ),
          'nope',
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
  });

  group('SessionHandlers producing-node query validation', () {
    test(
      'rejects malformed limits and blank identifiers before DB work',
      () async {
        final guarded = ProviderContainer(
          overrides: [
            databaseProvider.overrideWith(
              (ref) => throw StateError('database must not be resolved'),
            ),
          ],
        );
        addTearDown(guarded.dispose);
        final guardedHandlers = SessionHandlers(guarded);
        final queries = [
          'producingNodeId=node&limit=abc',
          'producingNodeId=node&limit=0',
          'producingNodeId=node&limit=-1',
          'producingNodeId=node&limit=5001',
          'producingNodeId=node&limit=1.5',
          'producingNodeId=%20%20',
          'producingNodeId=node&producingRunId=%20%20',
        ];

        for (final query in queries) {
          final response = await translateHandlerErrors(
            guardedHandlers.handleGetAllImages(
              Request('GET', Uri.parse('http://localhost/api/images?$query')),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: query);
        }
      },
    );

    test('trims identifiers and forwards a valid result limit', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      for (var i = 0; i < 2; i++) {
        await db.imagesDao.insertSequenceFrame(
          filePath: '/tmp/frame_$i.fits',
          fileName: 'frame_$i.fits',
          fileFormat: 'fits',
          exposureDuration: 30,
          capturedAt: DateTime.utc(2026, 7, 13, 1, i),
          isAccepted: true,
          producingNodeId: 'node-1',
          producingRunId: 'run-1',
        );
      }
      final local = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(local.dispose);
      final localHandlers = SessionHandlers(local);

      final response = await translateHandlerErrors(
        localHandlers.handleGetAllImages(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/images?producingNodeId=%20node-1%20'
              '&producingRunId=%20run-1%20&limit=1',
            ),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['images'], hasLength(1));
    });
  });

  // HTTP Range support for /api/images/{id}/download.
  //
  // We spin up an in-memory Drift DB, write a real FITS-like file to a
  // tempdir, register the row, then exercise the handler with various
  // Range header shapes. The handler streams via `file.openRead(start,
  // end+1)` so the response body covers exactly the requested byte
  // slice; we drain the body to verify the bytes are correct.
  group('SessionHandlers /api/images/{id}/download (Range)', () {
    late ProviderContainer container;
    late SessionHandlers handlers;
    late SkotiqDatabase db;
    late Directory tempDir;
    late File testFile;
    late int imageId;
    late int fileLength;

    // Deterministic payload — 100 incrementing bytes 0,1,2,...,99 so we
    // can spot-check sliced ranges by index.
    final payload = List<int>.generate(100, (i) => i % 256);

    setUp(() async {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      handlers = SessionHandlers(container);

      tempDir = await Directory.systemTemp.createTemp('skotiq_range_test_');
      testFile = File('${tempDir.path}${Platform.pathSeparator}test.fits');
      await testFile.writeAsBytes(payload);
      fileLength = await testFile.length();

      imageId = await db.imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: testFile.path,
          fileName: 'test.fits',
          fileFormat: const Value('fits'),
          fileSize: Value(fileLength),
          frameType: const Value('light'),
          exposureDuration: 60.0,
          capturedAt: DateTime.utc(2026, 1, 1),
        ),
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Tempdir cleanup is best-effort; failure shouldn't fail the test.
      }
    });

    Future<Response> hitDownload({Map<String, String>? headers}) {
      final request = Request(
        'GET',
        Uri.parse('http://localhost/api/images/$imageId/download'),
        headers: headers,
      );
      return translateHandlerErrors(
        handlers.handleDownloadImage(request, imageId.toString()),
      );
    }

    test('200 full download advertises accept-ranges and etag', () async {
      final response = await hitDownload();

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['accept-ranges'], 'bytes');
      expect(response.headers['etag'], isNotNull);
      expect(response.headers['content-length'], fileLength.toString());
      final body = await response.read().expand((c) => c).toList();
      expect(body, payload);
    });

    test('206 partial with explicit range bytes=10-19', () async {
      final response = await hitDownload(headers: {'range': 'bytes=10-19'});

      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers['accept-ranges'], 'bytes');
      expect(response.headers['content-range'], 'bytes 10-19/$fileLength');
      expect(response.headers['content-length'], '10');
      final body = await response.read().expand((c) => c).toList();
      expect(body, payload.sublist(10, 20));
    });

    test('206 with open-ended range bytes=50-', () async {
      final response = await hitDownload(headers: {'range': 'bytes=50-'});

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers['content-range'],
        'bytes 50-${fileLength - 1}/$fileLength',
      );
      expect(response.headers['content-length'], (fileLength - 50).toString());
      final body = await response.read().expand((c) => c).toList();
      expect(body, payload.sublist(50));
    });

    test('206 with suffix range bytes=-25 returns last 25 bytes', () async {
      final response = await hitDownload(headers: {'range': 'bytes=-25'});

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers['content-range'],
        'bytes ${fileLength - 25}-${fileLength - 1}/$fileLength',
      );
      expect(response.headers['content-length'], '25');
      final body = await response.read().expand((c) => c).toList();
      expect(body, payload.sublist(fileLength - 25));
    });

    test('416 when range start exceeds file size', () async {
      final response = await hitDownload(
        headers: {'range': 'bytes=10000-20000'},
      );

      expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(response.headers['content-range'], 'bytes */$fileLength');
    });

    test('416 for malformed range header (non-bytes unit)', () async {
      final response = await hitDownload(headers: {'range': 'lines=0-10'});

      expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    });

    test('416 for malformed range header (no dash)', () async {
      final response = await hitDownload(headers: {'range': 'bytes=10'});

      expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    });

    test('416 for multi-range request', () async {
      final response = await hitDownload(headers: {'range': 'bytes=0-9,20-29'});

      expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    });

    test('200 (not 206) when If-Range etag mismatches', () async {
      // First grab the real etag so we can deliberately send a different
      // one and verify the server falls back to a full body.
      final probe = await hitDownload();
      final realEtag = probe.headers['etag']!;
      final fakeEtag = realEtag.replaceFirst('"', '"X');
      expect(fakeEtag, isNot(realEtag));
      await probe.read().drain();

      final response = await hitDownload(
        headers: {'range': 'bytes=10-19', 'if-range': fakeEtag},
      );

      // Mismatched If-Range → server MUST return the full 200 body.
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['accept-ranges'], 'bytes');
      final body = await response.read().expand((c) => c).toList();
      expect(body, payload);
    });

    test('206 honours If-Range when etag matches', () async {
      // Pull the real etag, then send it back with a valid Range.
      final probe = await hitDownload();
      final realEtag = probe.headers['etag']!;
      await probe.read().drain();

      final response = await hitDownload(
        headers: {'range': 'bytes=0-9', 'if-range': realEtag},
      );

      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers['content-range'], 'bytes 0-9/$fileLength');
      final body = await response.read().expand((c) => c).toList();
      expect(body, payload.sublist(0, 10));
    });

    test('404 when DB row missing', () async {
      final response = await translateHandlerErrors(
        handlers.handleDownloadImage(
          Request(
            'GET',
            Uri.parse('http://localhost/api/images/999999/download'),
          ),
          '999999',
        ),
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('404 when file on disk is missing', () async {
      // Delete the on-disk file but leave the row.
      await testFile.delete();
      final response = await hitDownload();
      expect(response.statusCode, HttpStatus.notFound);
    });
  });
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }
}

class _GatedPolarBackend extends DisconnectedBackend {
  final Completer<void> startGate = Completer<void>();
  int startCalls = 0;
  double? autoCompleteThreshold;

  @override
  Future<void> startPolarAlignment({
    required double exposureTime,
    required double stepSize,
    required int binning,
    required bool isNorth,
    required bool manualRotation,
    required bool rotateEast,
    int? gain,
    int? offset,
    double? solveTimeout,
    bool? startFromCurrent,
    double? autoCompleteThreshold,
  }) async {
    startCalls++;
    this.autoCompleteThreshold = autoCompleteThreshold;
    await startGate.future;
  }
}

Future<void> _pumpEvents([int times = 6]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _EventedPolarBackend extends DisconnectedBackend {
  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();

  double? autoCompleteThreshold;
  double? allSkyCadence;
  double? allSkyThreshold;
  int stopCalls = 0;

  @override
  Stream<SkotiqEvent> get eventStream => _events.stream;

  @override
  Future<void> startPolarAlignment({
    required double exposureTime,
    required double stepSize,
    required int binning,
    required bool isNorth,
    required bool manualRotation,
    required bool rotateEast,
    int? gain,
    int? offset,
    double? solveTimeout,
    bool? startFromCurrent,
    double? autoCompleteThreshold,
  }) async {
    this.autoCompleteThreshold = autoCompleteThreshold;
  }

  @override
  Future<void> startAllSkyPolarAlignment({
    required double exposureTime,
    required double solveTimeout,
    required int binning,
    required bool isNorth,
    required double acceptanceThresholdArcsec,
    required double iterationCadenceSecs,
    int? gain,
    int? offset,
  }) async {
    allSkyCadence = iterationCadenceSecs;
    allSkyThreshold = acceptanceThresholdArcsec;
  }

  @override
  Future<void> stopPolarAlignment() async {
    stopCalls++;
  }

  void emitStatus(String phase, {String status = ''}) {
    _events.add(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.polarAlignment,
        eventType: 'PolarAlignmentStatus',
        data: {'phase': phase, 'status': status, 'point': 0},
      ),
    );
  }

  void emitError({
    required double azimuth,
    required double altitude,
    required double total,
  }) {
    _events.add(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.polarAlignment,
        eventType: 'PolarAlignment',
        data: {
          'azimuth_error': azimuth,
          'altitude_error': altitude,
          'total_error': total,
          'current_ra': 12.0,
          'current_dec': 80.0,
          'target_ra': 0.0,
          'target_dec': 90.0,
        },
      ),
    );
  }

  Future<void> close() => _events.close();
}

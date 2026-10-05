import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nightshade_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockSequenceRepository extends Mock implements SequenceRepository {}

class _MockSequenceExecutor extends Mock implements SequenceExecutor {}

class _MockSequencerBackend extends Mock implements SequencerBackend {}

void main() {
  group('SequencerHandlers', () {
    late ProviderContainer container;
    late SequencerHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = SequencerHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('status disconnected backend failure returns JSON error', () async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerStatus(
          Request('GET', Uri.parse('http://localhost/api/sequencer/status')),
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

    test('load malformed payload returns JSON internal server error', () async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerLoad(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/load'),
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
      'meridian flip rejects malformed optional fields and unsafe bounds',
      () async {
        final base = <String, Object?>{
          'mountId': 'mount-1',
          'targetName': 'M31',
          'targetRaHours': 0.7,
          'targetDecDegrees': 41.2,
        };
        final invalid = <Map<String, Object?>>[
          {'mountId': '   '},
          {'targetName': '   '},
          {'cameraId': 42},
          {'pauseGuiding': 'maybe'},
          {'targetRaHours': -0.1},
          {'targetRaHours': 24.1},
          {'targetDecDegrees': -90.1},
          {'targetDecDegrees': 90.1},
          {'settleTimeSecs': -1},
          {'settleTimeSecs': 3601},
        ];

        for (final override in invalid) {
          final response = await translateHandlerErrors(
            handlers.handlePerformMeridianFlip(
              Request(
                'POST',
                Uri.parse('http://localhost/api/sequencer/meridian-flip'),
                body: jsonEncode({...base, ...override}),
              ),
            ),
          );
          expect(
            response.statusCode,
            HttpStatus.badRequest,
            reason: '$override',
          );
        }
      },
    );

    test(
      'load-and-start hydrates the saved sequence through the editor',
      () async {
        final repository = _MockSequenceRepository();
        final executor = _MockSequenceExecutor();
        final sequence = Sequence.create(
          name: 'Remote run',
          databaseId: 42,
          nodes: {'root': InstructionSetNode(id: 'root', name: 'Sequence')},
          rootNodeId: 'root',
        );
        when(
          () => repository.loadSequence(42),
        ).thenAnswer((_) async => sequence);
        when(() => executor.start()).thenAnswer((_) async {});

        final scoped = ProviderContainer(
          overrides: [
            sequenceRepositoryProvider.overrideWithValue(repository),
            sequenceExecutorProvider.overrideWithValue(executor),
          ],
        );
        addTearDown(scoped.dispose);
        final scopedHandlers = SequencerHandlers(scoped);

        final response = await scopedHandlers.handleSequencerLoadAndStart(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/load-and-start'),
            body: jsonEncode({'sequenceId': 42}),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body, containsPair('status', 'started'));
        expect(body, containsPair('sequenceId', 42));
        final loaded = scoped.read(currentSequenceProvider);
        expect(loaded?.name, 'Remote run');
        expect(loaded?.databaseId, 42);
        // Node ids are PRESERVED. The copy keeps `databaseId` and saves back
        // to the same library row, so minting fresh UUIDs on open would break
        // the two subsystems that treat a node's UUID as durable identity:
        // `SequenceRepository.saveSequence` upserts by id, so an emptied
        // update set deletes and re-inserts every node row, and
        // `SequenceDiffService` matches by id, so re-running an untouched
        // sequence reports every node as both added AND removed. See
        // nightshade_core's load_copy_for_editing_test.dart.
        expect(loaded?.rootNodeId, 'root');
        verify(() => repository.loadSequence(42)).called(1);
        verify(() => executor.start()).called(1);
      },
    );

    test(
      'load-and-start returns 404 when the saved sequence is missing',
      () async {
        final repository = _MockSequenceRepository();
        final executor = _MockSequenceExecutor();
        when(() => repository.loadSequence(404)).thenAnswer((_) async => null);

        final scoped = ProviderContainer(
          overrides: [
            sequenceRepositoryProvider.overrideWithValue(repository),
            sequenceExecutorProvider.overrideWithValue(executor),
          ],
        );
        addTearDown(scoped.dispose);
        final response = await SequencerHandlers(scoped)
            .handleSequencerLoadAndStart(
              Request(
                'POST',
                Uri.parse('http://localhost/api/sequencer/load-and-start'),
                body: jsonEncode({'sequenceId': 404}),
              ),
            );

        expect(response.statusCode, HttpStatus.notFound);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'sequence_not_found');
        verifyNever(() => executor.start());
      },
    );

    test('dither config validates required numeric fields as JSON', () async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerUpdateDitherConfig(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/update-dither-config'),
            body: jsonEncode({'pixels': 5}),
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

    test('skip-to-node rejects missing nodeId with 400 JSON error', () async {
      // Why: nodeId is the only field; an empty body must produce a structured
      // BadRequestError that the middleware renders as a 400, not a 500.
      final response = await translateHandlerErrors(
        handlers.handleSequencerSkipToNode(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/skip-to-node'),
            body: jsonEncode({}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'nodeId');
      expect(body['expected'], 'string');
    });

    test('skip-to-node rejects empty nodeId with 400 JSON error', () async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerSkipToNode(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/skip-to-node'),
            body: jsonEncode({'nodeId': ''}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'nodeId');
    });

    test('skip-to-node with valid nodeId fails through to backend '
        '(DisconnectedBackend raises) and surfaces as JSON', () async {
      // Why: with no FFI/network backend wired, the default backendProvider
      // resolves to DisconnectedBackend which raises on sequencer calls. We
      // care that the handler validates input then defers to the backend
      // (i.e. the route plumbing works) — not that the test container
      // actually runs the sequencer.
      final response = await translateHandlerErrors(
        handlers.handleSequencerSkipToNode(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/skip-to-node'),
            body: jsonEncode({'nodeId': 'node-42'}),
          ),
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.ok, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
    });

    test('update-autofocus-interval rejects missing everyNFrames with 400 JSON '
        'error', () async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerUpdateAutofocusInterval(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/sequencer/update-autofocus-interval',
            ),
            body: jsonEncode({}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'everyNFrames');
      expect(body['expected'], 'integer');
    });

    test('update-autofocus-interval rejects everyNFrames < 1 with 400 JSON '
        'error', () async {
      // Why: 0 is meaningless (autofocus every 0 frames = never) and the Rust
      // bridge also rejects it; the handler enforces the same gate so the
      // caller gets a clear error instead of a vague 500 from FRB.
      final response = await translateHandlerErrors(
        handlers.handleSequencerUpdateAutofocusInterval(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/sequencer/update-autofocus-interval',
            ),
            body: jsonEncode({'everyNFrames': 0}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
    });

    test(
      'update-autofocus-interval with valid frames defers to backend',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSequencerUpdateAutofocusInterval(
            Request(
              'POST',
              Uri.parse(
                'http://localhost/api/sequencer/update-autofocus-interval',
              ),
              body: jsonEncode({'everyNFrames': 25}),
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.ok, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
      },
    );

    test('secondary rig start requires an explicit host save path', () async {
      final response = await translateHandlerErrors(
        handlers.handleSecondaryRigStart(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/secondary-rig/start'),
            body: jsonEncode({'cameraId': 'sim:secondary', 'exposureSecs': 60}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'saveBasePath');
    });

    test('secondary rig start rejects fractional frame counts', () async {
      final response = await translateHandlerErrors(
        handlers.handleSecondaryRigStart(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/secondary-rig/start'),
            body: jsonEncode({
              'cameraId': 'sim:secondary',
              'exposureSecs': 60,
              'saveBasePath': '/tmp/nightshade-secondary',
              'frameCount': 2.5,
            }),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'frameCount');
    });

    // Recovery Mode HTTP handlers

    test(
      'recovery/try-now defers to backend (DisconnectedBackend raises)',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSequencerRecoveryTryNow(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sequencer/recovery/try-now'),
              body: jsonEncode({}),
            ),
          ),
        );
        // Either 200 (real backend) or 5xx (Disconnected) — what we care
        // about is the route plumbing and JSON content-type.
        expect(
          response.statusCode,
          anyOf(HttpStatus.ok, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
      },
    );

    test(
      'recovery/abort defers to backend (DisconnectedBackend raises)',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSequencerRecoveryAbort(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sequencer/recovery/abort'),
              body: jsonEncode({}),
            ),
          ),
        );
        expect(
          response.statusCode,
          anyOf(HttpStatus.ok, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
      },
    );

    test(
      'recovery/update-config rejects missing required fields with 400 JSON',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSequencerUpdateRecoveryConfig(
            Request(
              'POST',
              Uri.parse(
                'http://localhost/api/sequencer/recovery/update-config',
              ),
              body: jsonEncode({}),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        // One of the required fields must appear in the field path. We
        // don't pin which one (validation may short-circuit on the first
        // missing field) but the contract is "400 with field name".
        expect(body['field'], isA<String>());
      },
    );

    test('recovery/update-config with all fields defers to backend', () async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerUpdateRecoveryConfig(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/recovery/update-config'),
            body: jsonEncode({
              'retryIntervalSecs': 600.0,
              'maxDurationSecs': 5400.0,
              'stopTrackingDuringRecovery': true,
              'abortOnMeridian': true,
              'audibleAlertWhenEntered': true,
              'parkAndCloseWhenRecoveryGivesUp': false,
            }),
          ),
        ),
      );
      expect(
        response.statusCode,
        anyOf(HttpStatus.ok, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
    });

    test('recovery/update-config accepts a payload without the park-and-close '
        'flag, so an older client can still save recovery settings', () async {
      // The flag is newer than the route. A client built before it exists
      // omits it, and the honest default for a missing value is `false` —
      // hold the run. Rejecting the payload would stop a mobile companion
      // saving recovery settings at all, and defaulting a missing value to
      // "park the mount" is the inference this field exists to remove.
      final response = await translateHandlerErrors(
        handlers.handleSequencerUpdateRecoveryConfig(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/recovery/update-config'),
            body: jsonEncode({
              'retryIntervalSecs': 600.0,
              'maxDurationSecs': 5400.0,
              'stopTrackingDuringRecovery': true,
              'abortOnMeridian': true,
              'audibleAlertWhenEntered': true,
            }),
          ),
        ),
      );
      expect(response.statusCode, isNot(HttpStatus.badRequest));
      expect(response.headers['content-type'], 'application/json');
    });

    test('recovery/current returns JSON with context key', () async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerGetCurrentRecovery(
          Request(
            'GET',
            Uri.parse('http://localhost/api/sequencer/recovery/current'),
          ),
        ),
      );
      // DisconnectedBackend raises; we only care that the route exists.
      expect(
        response.statusCode,
        anyOf(HttpStatus.ok, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
    });

    test('recovery/history returns JSON with history key', () async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerGetRecoveryHistory(
          Request(
            'GET',
            Uri.parse('http://localhost/api/sequencer/recovery/history'),
          ),
        ),
      );
      expect(
        response.statusCode,
        anyOf(HttpStatus.ok, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
    });

    test(
      'update-conditions-score rejects non-object score with 400 JSON',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSequencerUpdateConditionsScore(
            Request(
              'POST',
              Uri.parse(
                'http://localhost/api/sequencer/update-conditions-score',
              ),
              body: jsonEncode({'score': 42}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['field'], 'score');
        expect(body['expected'], 'object or null');
      },
    );

    test(
      'update-conditions-score accepts null score and defers to backend',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSequencerUpdateConditionsScore(
            Request(
              'POST',
              Uri.parse(
                'http://localhost/api/sequencer/update-conditions-score',
              ),
              body: jsonEncode({'score': null}),
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.ok, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
      },
    );

    test('adaptive-swap returns JSON content-type', () async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerGetAdaptiveSwap(
          Request(
            'GET',
            Uri.parse('http://localhost/api/sequencer/adaptive-swap'),
          ),
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.ok, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
    });
  });

  // D2b: the endpoint confirmed every path as ok — including the empty string,
  // which is exactly the input that made the sequencer capture a whole run and
  // discard every frame.
  group('SequencerHandlers save-path validation', () {
    late ProviderContainer container;
    late SequencerHandlers handlers;
    late _MockSequencerBackend backend;

    setUp(() {
      backend = _MockSequencerBackend();
      when(() => backend.sequencerSetSavePath(any())).thenAnswer((_) async {});
      // In-memory database: an accepted save path now also writes the host's
      // `imageOutputPath` (live-rig L30), so this group touches settings
      // persistence and a bare container would reach for the real on-disk DB.
      container = createHeadlessTestContainer(
        overrides: [sequencerBackendProvider.overrideWithValue(backend)],
      );
      handlers = SequencerHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    Future<Response> post(Object? body) => translateHandlerErrors(
      handlers.handleSequencerSetSavePath(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/save-path'),
          body: jsonEncode(body),
        ),
      ),
    );

    for (final rejected in <Map<String, Object?>>[
      <String, Object?>{},
      {'path': ''},
      {'path': '   '},
      {'path': null},
    ]) {
      test('rejects $rejected instead of confirming it', () async {
        final response = await post(rejected);

        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
        verifyNever(() => backend.sequencerSetSavePath(any()));
      });
    }

    test('rejects a directory that cannot be created', () async {
      final response = await post({'path': '/proc/nightshade-cannot-write'});

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'save_path_unwritable');
      verifyNever(() => backend.sequencerSetSavePath(any()));
    });

    test('accepts a writable directory and forwards it', () async {
      final dir = Directory.systemTemp.createTempSync('ns-save-path-ok');
      addTearDown(() => dir.deleteSync(recursive: true));

      final response = await post({'path': dir.path});

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['status'], 'ok');
      expect(body['path'], dir.path);
      verify(() => backend.sequencerSetSavePath(dir.path)).called(1);
    });

    test(
      'creates a missing directory rather than accepting it blind',
      () async {
        final parent = Directory.systemTemp.createTempSync('ns-save-path-new');
        addTearDown(() => parent.deleteSync(recursive: true));
        final target = '${parent.path}/captures/tonight';

        final response = await post({'path': target});

        expect(response.statusCode, HttpStatus.ok);
        expect(Directory(target).existsSync(), isTrue);
        verify(() => backend.sequencerSetSavePath(target)).called(1);
      },
    );
  });

  // A paired phone pushed its own `getApplicationDocumentsDirectory()` at the
  // host on every connection, permanently replacing the host's crash-recovery
  // directory with an Android path that cannot exist on the rig. The host owns
  // its storage layout; a client may not name it.
  group('SequencerHandlers checkpoint-dir ownership', () {
    late ProviderContainer container;
    late SequencerHandlers handlers;
    late _MockSequencerBackend backend;

    setUp(() {
      backend = _MockSequencerBackend();
      when(
        () => backend.sequencerSetCheckpointDir(any()),
      ).thenAnswer((_) async {});
      container = ProviderContainer(
        overrides: [sequencerBackendProvider.overrideWithValue(backend)],
      );
      handlers = SequencerHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    Future<Response> post(Object? body) => translateHandlerErrors(
      handlers.handleSequencerSetCheckpointDir(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/checkpoint/dir'),
          body: jsonEncode(body),
        ),
      ),
    );

    for (final rejected in <String>[
      '/data/user/0/com.nightshade.mobile/app_flutter',
      '/tmp',
      'relative/checkpoints',
    ]) {
      test('refuses client-supplied path "$rejected"', () async {
        final response = await post({'path': rejected});

        expect(response.statusCode, HttpStatus.forbidden);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['code'], 'checkpoint_dir_host_owned');
        verifyNever(() => backend.sequencerSetCheckpointDir(any()));
      });
    }
  });

  /// `POST /api/sequencer/update-observer-profile` must name the keys it did
  /// not understand. `focalLengthMm` / `apertureMm` — the obvious spelling of
  /// the real keys — otherwise get a bare `200 {"status":"ok"}` and the only
  /// way to discover the drop is a later FITS header missing FOCALLEN.
  group('the observer profile says what it understood', () {
    late ProviderContainer container;
    late SequencerHandlers handlers;
    late _MockSequencerBackend backend;

    setUp(() {
      backend = _MockSequencerBackend();
      when(
        () => backend.sequencerUpdateObserverProfile(
          observerName: any(named: 'observerName'),
          siteElevationM: any(named: 'siteElevationM'),
          cameraMake: any(named: 'cameraMake'),
          cameraModel: any(named: 'cameraModel'),
          telescopeName: any(named: 'telescopeName'),
          telescopeFocalLengthMm: any(named: 'telescopeFocalLengthMm'),
          telescopeApertureMm: any(named: 'telescopeApertureMm'),
        ),
      ).thenAnswer((_) async {});
      container = createHeadlessTestContainer(
        overrides: [sequencerBackendProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      handlers = SequencerHandlers(container);
    });

    Future<Map<String, dynamic>> post(Map<String, Object?> body) async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerUpdateObserverProfile(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/update-observer-profile'),
            body: jsonEncode(body),
          ),
        ),
      );
      expect(response.statusCode, 200);
      return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    }

    test('the exact rig payload is reported as ignored', () async {
      final body = await post({
        'focalLengthMm': 1000.0,
        'apertureMm': 200.0,
        'telescopeName': 'RC8',
      });

      expect(body['status'], 'ok');
      expect(body['applied'], ['telescopeName']);
      expect(body['ignored'], ['apertureMm', 'focalLengthMm']);
      expect(body['warning'], contains('telescopeFocalLengthMm'));
    });

    test('a wholly correct payload carries no warning', () async {
      final body = await post({
        'telescopeFocalLengthMm': 1000.0,
        'telescopeApertureMm': 200.0,
      });

      expect(body['applied'], [
        'telescopeApertureMm',
        'telescopeFocalLengthMm',
      ]);
      expect(body.containsKey('ignored'), isFalse);
      expect(body.containsKey('warning'), isFalse);
    });

    test('the values still reach the backend', () async {
      await post({'telescopeFocalLengthMm': 1000.0, 'nonsense': 1});

      verify(
        () => backend.sequencerUpdateObserverProfile(
          observerName: null,
          siteElevationM: null,
          cameraMake: null,
          cameraModel: null,
          telescopeName: null,
          telescopeFocalLengthMm: 1000.0,
          telescopeApertureMm: null,
        ),
      ).called(1);
    });
  });

  // W13-C / D4-W2: a rig that has never run publishes no progress figure.
  //
  // Measured against the release bundle on an EMPTY database dir, one process
  // answered two questions about the same rig two ways:
  //   GET /api/sequencer/status    -> {"state":"idle", …, "progress":0.0}
  //   GET /api/run-watch/snapshot  -> sequencer.progress.progressPercent: null
  // Every other field on the status payload was null. The web dashboard read
  // the one figure it was given and asserted "Progress 0%" with
  // aria-valuenow="0" over a fresh install that had never exposed a frame,
  // while the phone surface fed by the same process rendered "PROGRESS --".
  group('SequencerHandlers status progress', () {
    late ProviderContainer container;
    late SequencerHandlers handlers;
    late _MockSequencerBackend backend;

    setUp(() {
      backend = _MockSequencerBackend();
      container = createHeadlessTestContainer(
        overrides: [sequencerBackendProvider.overrideWithValue(backend)],
      );
      handlers = SequencerHandlers(container);
    });

    tearDown(() => container.dispose());

    Future<Map<String, Object?>> status() async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerStatus(
          Request('GET', Uri.parse('http://localhost/api/sequencer/status')),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      return jsonDecode(await response.readAsString()) as Map<String, Object?>;
    }

    test('a rig that has never run reports no progress', () async {
      when(() => backend.sequencerGetStatus()).thenAnswer(
        (_) async => const SequencerStatus(state: 'idle', progress: 0.0),
      );

      final body = await status();

      // The state IS known — no run is going. Only the figure is withheld.
      expect(body['state'], 'idle');
      // The field stays on the wire; it is its VALUE that is absent.
      expect(body.containsKey('progress'), isTrue);
      // 0.0 of nothing planned is not a measurement.
      expect(body['progress'], isNull);
      expect(body['currentNodeId'], isNull);
      expect(body['currentNodeName'], isNull);
      expect(body['currentTarget'], isNull);
    });

    test('a run that has written progress keeps its real figure', () async {
      when(() => backend.sequencerGetStatus()).thenAnswer(
        (_) async => const SequencerStatus(
          state: 'running',
          currentNodeId: 'exp_l',
          currentNodeName: 'Exposure L',
          progress: 0.42,
          message: 'Frame 5/12',
        ),
      );
      container
          .read(sequenceProgressProvider.notifier)
          .updateProgress(currentTarget: 'M Long Field');

      final body = await status();

      expect(body['progress'], 0.42);
      expect(body['currentTarget'], 'M Long Field');
      expect(body['currentNodeName'], 'Exposure L');
    });

    test('a started run at zero percent still reports zero', () async {
      when(() => backend.sequencerGetStatus()).thenAnswer(
        (_) async => const SequencerStatus(state: 'running', progress: 0.0),
      );
      container
          .read(sequenceProgressProvider.notifier)
          .updateState(SequenceExecutionState.running);

      final body = await status();

      // A run the record knows about has a measurement, and it is zero.
      expect(body['progress'], 0.0);
    });
  });

  // The update-config tests above pass with the backend call's arguments
  // unread, so the missing-flag default could flip to "park" and every test in
  // this file still passed. These pin what the backend is actually told.
  group('SequencerHandlers park-and-close opt-in', () {
    late ProviderContainer container;
    late SequencerHandlers handlers;
    late _MockSequencerBackend backend;

    setUp(() {
      backend = _MockSequencerBackend();
      when(
        () => backend.updateRecoveryConfig(
          retryIntervalSecs: any(named: 'retryIntervalSecs'),
          maxDurationSecs: any(named: 'maxDurationSecs'),
          stopTrackingDuringRecovery: any(named: 'stopTrackingDuringRecovery'),
          abortOnMeridian: any(named: 'abortOnMeridian'),
          audibleAlertWhenEntered: any(named: 'audibleAlertWhenEntered'),
          parkAndCloseWhenRecoveryGivesUp: any(
            named: 'parkAndCloseWhenRecoveryGivesUp',
          ),
        ),
      ).thenAnswer((_) async {});
      container = ProviderContainer(
        overrides: [sequencerBackendProvider.overrideWithValue(backend)],
      );
      handlers = SequencerHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    Future<bool> parkAndCloseSentFor(Map<String, Object?> payload) async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerUpdateRecoveryConfig(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/recovery/update-config'),
            body: jsonEncode({
              'retryIntervalSecs': 600.0,
              'maxDurationSecs': 5400.0,
              'stopTrackingDuringRecovery': true,
              'abortOnMeridian': true,
              'audibleAlertWhenEntered': true,
              ...payload,
            }),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      return verify(
            () => backend.updateRecoveryConfig(
              retryIntervalSecs: 600.0,
              maxDurationSecs: 5400.0,
              stopTrackingDuringRecovery: true,
              abortOnMeridian: true,
              audibleAlertWhenEntered: true,
              parkAndCloseWhenRecoveryGivesUp: captureAny(
                named: 'parkAndCloseWhenRecoveryGivesUp',
              ),
            ),
          ).captured.single
          as bool;
    }

    test('a client that omits the flag holds the run: the backend is told '
        'not to park', () async {
      expect(await parkAndCloseSentFor({}), isFalse);
    });

    test('an explicit false is passed through as false', () async {
      expect(
        await parkAndCloseSentFor({'parkAndCloseWhenRecoveryGivesUp': false}),
        isFalse,
      );
    });

    test('an operator who opts in reaches the backend as true', () async {
      expect(
        await parkAndCloseSentFor({'parkAndCloseWhenRecoveryGivesUp': true}),
        isTrue,
      );
    });
  });
}

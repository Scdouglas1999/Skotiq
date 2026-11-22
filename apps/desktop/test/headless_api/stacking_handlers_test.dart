// Regression tests for the host's live-stacking routes (StackingHandlers).
// The bug-prone logic is the arm -> reference -> feed sequence: a linked
// client arms the host with no reference frame, then the first frame the
// host's run accepts becomes the reference and every later one is added.
// Frames reach the stack the way a run delivers them, through
// LiveStackingFeed, and a fake LiveStackingService stands in for the native
// stacker.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/bridge_events.dart'
    show SequencerEvent_FrameAccepted;
import 'package:skotiq_core/services.dart';
import 'package:skotiq_desktop/headless_api/handlers/stacking_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';
import 'package:skotiq_desktop/headless_api/route_table.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/utils.dart';

/// Records what the coordinator asks the stacker to do, without touching FFI.
class _FakeStackingService extends LiveStackingService {
  _FakeStackingService(super.logger);

  final List<String> started = [];
  final List<String> startedFilters = [];
  final List<LiveStackingConfig> startedConfigs = [];
  final List<String> added = [];
  final List<String> resetFilters = [];
  final List<String> stoppedFilters = [];
  int resets = 0;
  int stops = 0;
  bool _active = false;
  final Set<String> _slots = {};
  Object? startError;

  /// Set to make the next add throw, standing in for the native stacker's
  /// unstructured failures (alignment rejection, unreadable file).
  Object? addError;

  @override
  bool get isActive => _active;

  @override
  int get frameCount => _active ? 1 + added.length : 0;

  /// A start of the unfiltered slot is the whole stack, as natively: a
  /// start without a filter starts that slot.
  @override
  Future<LiveStackingStats> start({
    String? referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
    String? filterKey,
  }) async {
    if (startError case final error?) throw error;
    final slot = normalizeLiveStackFilterKey(filterKey);
    if (slot == kDefaultLiveStackFilterKey) {
      started.add(referenceImagePath!);
    } else {
      startedFilters.add(slot);
    }
    startedConfigs.add(config);
    _slots.add(slot);
    _active = true;
    return LiveStackingStats(stackedFrameCount: 1, totalFramesAttempted: 1);
  }

  @override
  Future<void> reset({String? filterKey}) async {
    if (filterKey != null) {
      if (!_slots.contains(filterKey)) {
        throw StateError(
          "Live stacker not initialized for filter '$filterKey'",
        );
      }
      resetFilters.add(filterKey);
      return;
    }
    // Mirror the native engine: reset is invalid before the first frame
    // initializes the stacker.
    if (!_active) throw StateError('Live stacker not initialized');
    resets++;
  }

  @override
  Future<void> stop({String? filterKey}) async {
    if (filterKey != null) {
      if (!_slots.contains(filterKey)) {
        throw StateError(
          "Live stacker not initialized for filter '$filterKey'",
        );
      }
      stoppedFilters.add(filterKey);
      _slots.remove(filterKey);
      _active = _slots.isNotEmpty;
      return;
    }
    if (!_active) throw StateError('Live stacker not initialized');
    stops++;
    _active = false;
    _slots.clear();
  }

  @override
  Future<LiveStackingResult> addFrameFromFile(
    String imagePath, {
    String? filterKey,
  }) async {
    if (addError case final error?) throw error;
    added.add(imagePath);
    return LiveStackingResult(
      width: 2,
      height: 2,
      channels: 1,
      data: const [0, 0, 0, 0],
      stats: LiveStackingStats(
        stackedFrameCount: 1 + added.length,
        totalFramesAttempted: 1 + added.length,
      ),
    );
  }

  @override
  Future<LiveStackingStats> getStats({String? filterKey}) async {
    if (!_active) throw StateError('Live stacker not initialized');
    return LiveStackingStats(stackedFrameCount: 1 + added.length);
  }

  @override
  Future<LiveStackingResult> getCurrentResult({String? filterKey}) async =>
      LiveStackingResult(
        width: 2,
        height: 2,
        channels: 1,
        data: const [10, 20, 30, 40],
        filterKey: normalizeLiveStackFilterKey(filterKey),
        stats: LiveStackingStats(stackedFrameCount: 1 + added.length),
      );
}

SequencerEvent_FrameAccepted _accepted(String path) {
  final event = bridge.SequencerEvent.frameAccepted(
    nodeId: 'exp-1',
    frame: 1,
    total: 1,
    acceptedTotal: 1,
    rejectedTotal: 0,
    savePath: path,
    capture: const bridge.FrameCaptureMetadata(
      gainIsIso: false,
      exposureSecs: 30,
      binX: 1,
      binY: 1,
      frameType: 'Light',
    ),
  );
  if (event is! SequencerEvent_FrameAccepted) {
    throw StateError('frameAccepted did not build an accepted frame');
  }
  return event;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LoggingService logger;
  late ProviderContainer container;
  late _FakeStackingService fake;
  late StackingHandlers handlers;
  late LiveStackingFeed feed;
  String? runFilter;

  /// A light frame the host's run saved and accepted, through [runFilter].
  Future<void> saved(String path, {String? filter}) async {
    runFilter = filter;
    feed.feed(_accepted(path));
    await feed.pending;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_stacking_test_');
    logger = LoggingService(
      applicationSupportDirectoryProvider: () async => tempDir,
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    await logger.ensureInitialized();
    container = ProviderContainer(
      overrides: [
        loggingServiceProvider.overrideWithValue(logger),
        liveStackingServiceProvider.overrideWith(
          (ref) =>
              fake = _FakeStackingService(ref.read(loggingServiceProvider)),
        ),
      ],
    );
    // Force creation so `fake` is assigned before the tests use it.
    container.read(liveStackingServiceProvider);
    handlers = StackingHandlers(container);
    runFilter = null;
    feed = LiveStackingFeed(
      sequence: () => null,
      progress: () => SequenceProgress(currentFilter: runFilter),
      broadcast: () => container.read(liveStackingBroadcastServiceProvider),
      stacker: () => container.read(liveStackingProvider.notifier),
      stackState: () => container.read(liveStackingProvider),
      logger: () => container.read(loggingServiceProvider),
    );
  });

  tearDown(() async {
    container.dispose();
    await logger.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Request post(String path, [Object? body]) => Request(
    'POST',
    Uri.parse('http://localhost$path'),
    body: body == null ? null : jsonEncode(body),
  );

  test('arm → first saved frame is the reference, rest are added', () async {
    final startResp = await handlers.handleStart(post('/api/stacking/start'));
    expect(startResp.statusCode, 200);
    expect(jsonDecode(await startResp.readAsString())['status'], 'armed');
    expect(fake.started, isEmpty, reason: 'arming must not start the stacker');

    await saved('/host/frame_0001.fits');
    await saved('/host/frame_0002.fits');
    await saved('/host/frame_0003.fits');

    expect(fake.started, [
      '/host/frame_0001.fits',
    ], reason: 'first saved frame becomes the reference');
    expect(fake.added, [
      '/host/frame_0002.fits',
      '/host/frame_0003.fits',
    ], reason: 'subsequent frames are added, not re-referenced');
  });

  // The routes arm the host's live stack, the one the run feeds, not a flag of
  // their own.
  test('a stack a client armed is the one the host run feeds', () async {
    await handlers.handleStart(post('/api/stacking/start'));
    expect(container.read(liveStackingProvider).isActiveOrArmed, isTrue);

    await saved('/host/L_0001.fits', filter: 'L');
    await saved('/host/L_0002.fits', filter: 'L');

    expect(fake.startedFilters, ['L']);
    expect(fake.added, ['/host/L_0002.fits']);
    final status = await _json(
      handlers.handleStatus(
        Request('GET', Uri.parse('http://localhost/api/stacking/status')),
      ),
    );
    expect(status['started'], isTrue);
  });

  test(
    'a stack the host armed itself is the one the routes answer for',
    () async {
      await container.read(liveStackingProvider.notifier).arm();
      await saved('/host/ref.fits');

      final status = await _json(
        handlers.handleStatus(
          Request('GET', Uri.parse('http://localhost/api/stacking/status')),
        ),
      );
      expect(status['armed'], isTrue);
      expect(status['started'], isTrue);

      final stop = await _json(handlers.handleStop(post('/api/stacking/stop')));
      expect(stop['wasRunning'], isTrue);
      expect(fake.stops, 1);
      expect(
        container.read(liveStackingProvider).status,
        LiveStackingStatus.idle,
      );
    },
  );

  test('a reset keeps the settings the stack runs with', () async {
    const own = LiveStackingConfig(sigmaClipThreshold: 2.25);
    await container.read(liveStackingProvider.notifier).arm(config: own);
    await saved('/host/ref.fits');

    final reset = await handlers.handleReset(post('/api/stacking/reset'));
    expect(reset.statusCode, 200);
    await saved('/host/new-ref.fits');

    expect(fake.started, ['/host/ref.fits', '/host/new-ref.fits']);
    expect(fake.startedConfigs.last.sigmaClipThreshold, 2.25);
  });

  test('no auto-feed before arming or after stop', () async {
    // Not armed yet → ignored.
    await saved('/host/ignored.fits');
    expect(fake.started, isEmpty);
    expect(fake.added, isEmpty);

    await handlers.handleStart(post('/api/stacking/start'));
    await saved('/host/ref.fits');
    expect(fake.started, ['/host/ref.fits']);

    final stopResp = await handlers.handleStop(post('/api/stacking/stop'));
    expect(stopResp.statusCode, 200);
    expect(fake.stops, 1);

    // After stop, further saved frames are ignored.
    await saved('/host/after_stop.fits');
    expect(fake.added, isEmpty);
  });

  test('stop while armed-but-not-started does not touch the engine', () async {
    // Arming without a reference frame never initializes the native stacker,
    // so stop must not call into it — calling in answers 500. It should just
    // disarm cleanly.
    await handlers.handleStart(post('/api/stacking/start'));

    // stats while armed-but-not-started must report zeroes, not 500.
    final statsResp = await handlers.handleStats(
      Request('GET', Uri.parse('http://localhost/api/stacking/stats')),
    );
    expect(statsResp.statusCode, 200);
    final statsBody = jsonDecode(await statsResp.readAsString()) as Map;
    expect((statsBody['stats'] as Map)['stackedFrameCount'], 0);

    final resp = await handlers.handleStop(post('/api/stacking/stop'));
    expect(resp.statusCode, 200);
    expect(
      fake.stops,
      0,
      reason: 'engine.stop must not run when never started',
    );

    // Same guard on reset: armed-but-not-started must not call into the engine.
    // (handleStart itself resets internally, so measure the delta across the
    // explicit reset call rather than an absolute count.)
    await handlers.handleStart(post('/api/stacking/start'));
    final resetsBefore = fake.resets;
    final resetResp = await handlers.handleReset(post('/api/stacking/reset'));
    expect(resetResp.statusCode, 200);
    expect(
      fake.resets,
      resetsBefore,
      reason: 'engine.reset must not run when never started',
    );
    await handlers.handleStop(post('/api/stacking/stop'));

    final status =
        jsonDecode(
              await (await handlers.handleStatus(
                Request(
                  'GET',
                  Uri.parse('http://localhost/api/stacking/status'),
                ),
              )).readAsString(),
            )
            as Map<String, dynamic>;
    expect(status['armed'], false);
  });

  test('filterKey reset and stop touch that slot only', () async {
    final ha = await handlers.handleStart(
      post('/api/stacking/start', {
        'referencePath': '/host/ha.fits',
        'filterKey': 'Ha',
      }),
    );
    expect(ha.statusCode, 200);
    expect(jsonDecode(await ha.readAsString())['status'], 'started');
    final oiii = await handlers.handleStart(
      post('/api/stacking/start', {
        'referencePath': '/host/oiii.fits',
        'filterKey': 'OIII',
      }),
    );
    expect(oiii.statusCode, 200);

    expect(
      fake.started,
      isEmpty,
      reason: 'a named start is not the whole stack',
    );
    expect(fake.startedFilters, ['Ha', 'OIII']);
    expect(fake.resets, 0, reason: 'starting Ha must not reset OIII');

    final reset = await handlers.handleReset(
      post('/api/stacking/reset', {'filterKey': 'Ha'}),
    );
    expect(reset.statusCode, 200);
    expect(fake.resetFilters, ['Ha']);
    expect(fake.resets, 0);
    expect(fake.stops, 0);

    final stop = await handlers.handleStop(
      post('/api/stacking/stop', {'filterKey': 'Ha'}),
    );
    expect(stop.statusCode, 200);
    final stopBody = jsonDecode(await stop.readAsString()) as Map;
    expect(stopBody['filterKey'], 'Ha');
    expect(fake.stoppedFilters, ['Ha']);
    expect(fake.stops, 0, reason: 'stopping Ha must not stop OIII');

    // OIII is still a host stack, so its saved frame is still fed.
    await saved('/host/oiii_2.fits', filter: 'OIII');
    expect(fake.added, ['/host/oiii_2.fits']);

    final dispatch = RouteTable.only(handlers).handler;
    await dispatch(
      post('/api/stacking/filters/Ha/start', {
        'referencePath': '/host/ha.fits',
      }),
    );
    expect(fake._slots, {'Ha', 'OIII'});
    final resetAll = await dispatch(post('/api/stacking/reset'));
    expect(resetAll.statusCode, 200);
    expect(fake._slots, isEmpty);
    await saved('/host/new-run.fits');
    expect(fake.started.last, '/host/new-run.fits');
  });

  test('a missing filterKey still stops the whole stack', () async {
    await handlers.handleStart(
      post('/api/stacking/start', {'referencePath': '/host/ref.fits'}),
    );
    final stop = await handlers.handleStop(post('/api/stacking/stop', {}));
    expect(stop.statusCode, 200);
    expect(fake.stops, 1);
    expect(fake.stoppedFilters, isEmpty);
    final body = jsonDecode(await stop.readAsString()) as Map;
    expect(body.containsKey('filterKey'), isFalse);
  });

  test('explicit referencePath starts immediately', () async {
    final resp = await handlers.handleStart(
      post('/api/stacking/start', {'referencePath': '/host/ref.fits'}),
    );
    expect(resp.statusCode, 200);
    expect(jsonDecode(await resp.readAsString())['status'], 'started');
    expect(fake.started, ['/host/ref.fits']);
  });

  test('reference with too few stars returns a structured 422', () async {
    fake.startError = Exception(
      'Failed to initialize stacker: '
      'Reference frame has only 0 stars, need at least 5 for alignment',
    );

    final response = await translateHandlerErrors(
      handlers.handleStart(
        post('/api/stacking/start', {'referencePath': '/host/daylight.fits'}),
      ),
    );

    expect(response.statusCode, HttpStatus.unprocessableEntity);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['error'], 'stacking_reference_rejected');
    expect(body['detectedStars'], 0);
    expect(body['requiredStars'], 5);

    // The stack did not start: it is not armed, and a run's frames are not
    // fed to it.
    final status = await _json(
      handlers.handleStatus(
        Request('GET', Uri.parse('http://localhost/api/stacking/status')),
      ),
    );
    expect(status['armed'], isFalse);
    expect(status['started'], isFalse);
  });

  test(
    'a named start from a reference restarts a slot it already has',
    () async {
      final dispatch = RouteTable.only(handlers).handler;
      await dispatch(
        post('/api/stacking/filters/Ha/start', {
          'referencePath': '/host/ha.fits',
        }),
      );
      final again = await dispatch(
        post('/api/stacking/filters/Ha/start', {
          'referencePath': '/host/ha-2.fits',
        }),
      );

      expect(again.statusCode, 200);
      expect(fake.startedFilters, ['Ha', 'Ha']);
    },
  );

  test('bodyless start is allowed but malformed JSON is rejected', () async {
    final bodyless = await handlers.handleStart(post('/api/stacking/start'));
    expect(bodyless.statusCode, HttpStatus.ok);

    final malformed = await translateHandlerErrors(
      handlers.handleStart(
        Request(
          'POST',
          Uri.parse('http://localhost/api/stacking/start'),
          body: '{',
        ),
      ),
    );
    expect(malformed.statusCode, HttpStatus.badRequest);
  });

  test(
    'stacking config rejects wrong types, unsafe ranges, and bad enums',
    () async {
      final invalidConfigs = <Map<String, Object?>>[
        {'sigmaClipEnabled': 'sometimes'},
        {'sigmaClipThreshold': 0},
        {'maxMatchStars': 2},
        {'matchRadiusPx': -1},
        {'matchFluxTolerance': 1.1},
        {'maxMatchStars': 5, 'minMatchedPairs': 6},
        {'sensorMode': 'rgbw'},
        {'bayerPattern': 'RGBW'},
        {'demosaicQuality': 'lanczos'},
      ];

      for (final config in invalidConfigs) {
        final response = await translateHandlerErrors(
          handlers.handleUpdateConfig(
            post('/api/stacking/config', {'config': config}),
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: '$config');
      }
    },
  );

  test(
    'partial config updates preserve prior values and explicit null clears',
    () async {
      await handlers.handleUpdateConfig(
        post('/api/stacking/config', {
          'config': {
            'maxMatchStars': 250,
            'sensorMode': 'osc',
            'bayerPattern': 'BGGR',
          },
        }),
      );
      await handlers.handleUpdateConfig(
        post('/api/stacking/config', {
          'config': {'sigmaClipThreshold': 3.5, 'bayerPattern': null},
        }),
      );
      await handlers.handleStart(
        post('/api/stacking/start', {'referencePath': '/host/ref.fits'}),
      );

      final config = fake.startedConfigs.single;
      expect(config.maxMatchStars, 250);
      expect(config.sigmaClipThreshold, 3.5);
      expect(config.sensorMode, 'osc');
      expect(config.bayerPattern, isNull);
    },
  );

  test(
    'add-frame rejects a blank host path before touching the stacker',
    () async {
      final response = await translateHandlerErrors(
        handlers.handleAddFrame(
          post('/api/stacking/add-frame', {'imagePath': '   '}),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect(fake.started, isEmpty);
    },
  );

  /// A frame that will not align is an ORDINARY live-stacking outcome (cloud,
  /// wind, a satellite trail), not a host fault, so it must not answer
  /// `500 internal_error`: that tells a remote client the appliance broke,
  /// invites a retry storm, and is indistinguishable from the stacker actually
  /// being broken — the client could not tell "skip this frame" from "stop and
  /// tell the operator".
  test(
    'add-frame reports an alignment rejection as 422 frame_rejected',
    () async {
      await handlers.handleStart(post('/api/stacking/start'));
      await saved('/host/ref.fits');

      const sentence = 'Alignment residual too high: 24.34px (max 10.00px)';
      fake.addError = LiveStackingFrameRejected(
        reason: LiveStackRefusal(
          LiveStackRefusalKind.misaligned,
          sentence,
        ).legacyText,
        stats: LiveStackingStats(),
        refusal: LiveStackRefusal(LiveStackRefusalKind.misaligned, sentence),
      );
      final response = await translateHandlerErrors(
        handlers.handleAddFrame(
          post('/api/stacking/add-frame', {'imagePath': '/host/cloudy.fits'}),
        ),
      );

      expect(response.statusCode, HttpStatus.unprocessableEntity);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'frame_rejected');
      // The specific measurement has to survive: "did not align" without the
      // number is not actionable.
      expect(body['reason'], contains('24.34px'));
    },
  );

  test(
    'add-frame reports a frame of another filter as 422 frame_other_filter',
    () async {
      await handlers.handleStart(post('/api/stacking/start'));
      await saved('/host/ref.fits');

      const sentence =
          'Frame of another filter not stacked: the frame was taken through R '
          'and this live stack is of frames taken through L.';
      fake.addError = LiveStackingFrameRejected(
        reason: LiveStackRefusal(
          LiveStackRefusalKind.otherFilter,
          sentence,
        ).legacyText,
        stats: LiveStackingStats(),
        refusal: LiveStackRefusal(LiveStackRefusalKind.otherFilter, sentence),
      );
      final response = await translateHandlerErrors(
        handlers.handleAddFrame(
          post('/api/stacking/add-frame', {'imagePath': '/host/red.fits'}),
        ),
      );

      expect(response.statusCode, HttpStatus.unprocessableEntity);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'frame_other_filter');
      // The text the native refusal had before it had a kind, as a host
      // sends it: the sentence closed by the freezed form's ")".
      expect(body['message'], '$sentence)');
      expect(body['sentence'], sentence);
    },
  );

  test('add-frame reports an unreadable path as 404 frame_unreadable', () async {
    await handlers.handleStart(post('/api/stacking/start'));
    await saved('/host/ref.fits');

    const sentence =
        'Failed to read frame image: IO error: No such file or directory (os error 2)';
    fake.addError = LiveStackingFrameRejected(
      reason: LiveStackRefusal(
        LiveStackRefusalKind.unreadable,
        sentence,
      ).legacyText,
      stats: LiveStackingStats(),
      refusal: LiveStackRefusal(LiveStackRefusalKind.unreadable, sentence),
    );
    final response = await translateHandlerErrors(
      handlers.handleAddFrame(
        post('/api/stacking/add-frame', {'imagePath': '/host/missing.fits'}),
      ),
    );

    expect(response.statusCode, HttpStatus.notFound);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['error'], 'frame_unreadable');
  });

  /// Anything we have not classified must keep bubbling up as a real fault
  /// rather than being mislabelled as a routine rejection.
  test('add-frame leaves an unrecognized failure as a 500', () async {
    await handlers.handleStart(post('/api/stacking/start'));
    await saved('/host/ref.fits');

    fake.addError = Exception('stacker segfaulted somewhere unexpected');
    final response = await translateHandlerErrors(
      handlers.handleAddFrame(
        post('/api/stacking/add-frame', {'imagePath': '/host/f2.fits'}),
      ),
    );

    expect(response.statusCode, HttpStatus.internalServerError);
  });

  /// The auto-feed path already swallows per-frame failures so one bad frame
  /// cannot tear down a night's accumulation. Pin that the classification work
  /// did not change it.
  test('auto-feed survives a rejected frame without throwing', () async {
    await handlers.handleStart(post('/api/stacking/start'));
    await saved('/host/ref.fits');

    fake.addError = Exception(
      'Alignment residual too high: 30.00px (max 10.00px)',
    );
    await expectLater(saved('/host/cloudy.fits'), completes);

    fake.addError = null;
    await saved('/host/good.fits');
    expect(
      fake.added,
      contains('/host/good.fits'),
      reason: 'stacking must keep accepting frames after a rejection',
    );
  });

  test('status + preview reflect the live stack', () async {
    await handlers.handleStart(post('/api/stacking/start'));
    await saved('/host/ref.fits');
    await saved('/host/f2.fits');

    final status =
        jsonDecode(
              await (await handlers.handleStatus(
                Request(
                  'GET',
                  Uri.parse('http://localhost/api/stacking/status'),
                ),
              )).readAsString(),
            )
            as Map<String, dynamic>;
    expect(status['active'], true);
    expect(status['armed'], true);
    expect(status['started'], true);

    final preview = await handlers.handlePreview(
      Request('GET', Uri.parse('http://localhost/api/stacking/preview')),
    );
    expect(preview.statusCode, 200);
    expect(preview.headers['x-stack-width'], '2');
    expect(preview.headers['x-stack-height'], '2');
    expect(preview.headers['x-stack-endian'], 'little');
    final bytes = await preview.read().expand((c) => c).toList();
    // 4 u16 samples (10,20,30,40) little-endian = 8 bytes.
    expect(bytes.length, 8);
    expect(bytes.sublist(0, 2), [10, 0]); // 10 as LE u16
  });

  test(
    'waiting-for-first-frame errors expose a machine-readable code',
    () async {
      await handlers.handleStart(post('/api/stacking/start'));

      final response = await handlers.handleResult(
        Request('GET', Uri.parse('http://localhost/api/stacking/result')),
      );
      expect(response.statusCode, HttpStatus.notFound);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['code'], 'no_active_stack');
      expect(body['message'], 'Live stacking is not running.');
    },
  );

  test('the host reads every engine setting a client sends', () async {
    const sent = LiveStackingConfig(
      sigmaClipEnabled: false,
      sigmaClipThreshold: 3.25,
      maxMatchStars: 150,
      matchRadiusPx: 42.5,
      matchFluxTolerance: 0.55,
      minMatchedPairs: 7,
      maxAlignmentResidualPx: 1.25,
      starDetectionSigma: 3.5,
      starDetectionMinSnr: 6.5,
      sensorMode: 'osc',
      bayerPattern: 'GRBG',
      demosaicQuality: 'vng',
    );
    final response = await handlers.handleStart(
      post('/api/stacking/start', {
        'referencePath': '/host/ref.fits',
        'config': sent.toWireJson(),
      }),
    );
    expect(response.statusCode, HttpStatus.ok);
    expect(fake.startedConfigs.last.toBridge(), sent.toBridge());
  });

  test(
    '9.0.2 config tuning fields and totalIntegrationSecs round-trip over JSON',
    () async {
      final startResponse = await handlers.handleStart(
        post('/api/stacking/start', {
          'referencePath': '/host/ref.fits',
          'config': {
            'maxAlignmentResidualPx': 1.2,
            'starDetectionSigma': 3.5,
            'starDetectionMinSnr': 6.5,
          },
        }),
      );
      expect(startResponse.statusCode, HttpStatus.ok);
      expect(
        fake.startedConfigs.last.maxAlignmentResidualPx,
        closeTo(1.2, 1e-9),
      );
      expect(fake.startedConfigs.last.starDetectionSigma, closeTo(3.5, 1e-9));
      expect(fake.startedConfigs.last.starDetectionMinSnr, closeTo(6.5, 1e-9));

      final body =
          jsonDecode(await startResponse.readAsString())
              as Map<String, dynamic>;
      final stats = body['stats'] as Map<String, dynamic>;
      expect(stats.containsKey('totalIntegrationSecs'), isTrue);
    },
  );

  /// What the host answers for each frame the engine leaves out, recorded in
  /// `fixtures/live_stack_refusal_replies.json` (`SKOTIQ_RECORD_REPLIES=1`
  /// rewrites it). The service raises what the native stacker's refusal
  /// becomes: a counted [LiveStackingFrameRejected].
  group('add-frame answers each native refusal as recorded', () {
    final fixture = File(
      'test/headless_api/fixtures/live_stack_refusal_replies.json',
    );
    final record = Platform.environment['SKOTIQ_RECORD_REPLIES'] == '1';
    final recorded = <String, Object?>{};
    final expected = record
        ? const <String, Object?>{}
        : jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
    tearDownAll(() {
      if (!record) return;
      fixture.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(recorded)}\n',
      );
    });
    final rows = <String, (LiveStackRefusalKind, String)>{
      'misaligned.residual': (
        LiveStackRefusalKind.misaligned,
        'Alignment residual too high: 24.34px (max 10.00px)',
      ),
      'misaligned.stars': (
        LiveStackRefusalKind.misaligned,
        'Insufficient stars for alignment: 2 detected, 6 required',
      ),
      'misaligned.matches': (
        LiveStackRefusalKind.misaligned,
        'Insufficient star matches for alignment: 3 matched, 6 required',
      ),
      'misaligned.inconsistent': (
        LiveStackRefusalKind.misaligned,
        'Inconsistent star matches for alignment: 3 of 9 agree on one '
            'transform, 6 required',
      ),
      'other_filter': (
        LiveStackRefusalKind.otherFilter,
        'Frame of another filter not stacked: the frame was taken through R '
            'and this live stack is of frames taken through L.',
      ),
      'unreadable': (
        LiveStackRefusalKind.unreadable,
        'Failed to read frame image: IO error: No such file or directory '
            '(os error 2)',
      ),
    };
    for (final MapEntry(key: name, value: (kind, message)) in rows.entries) {
      test(name, () async {
        await handlers.handleStart(post('/api/stacking/start'));
        await saved('/host/ref.fits');
        final refusal = LiveStackRefusal(kind, message);
        fake.addError = LiveStackingFrameRejected(
          reason: refusal.legacyText,
          stats: LiveStackingStats(totalFramesAttempted: 2),
          refusal: refusal,
        );
        final response = await translateHandlerErrors(
          handlers.handleAddFrame(
            post('/api/stacking/add-frame', {'imagePath': '/host/$name.fits'}),
          ),
        );
        final reply = {
          'status': response.statusCode,
          'body': jsonDecode(await response.readAsString()),
        };
        recorded[name] = reply;
        if (!record) expect(reply, expected[name]);
      });
    }
  });
}

Future<Map<String, dynamic>> _json(Future<Response> response) async =>
    jsonDecode(await (await response).readAsString()) as Map<String, dynamic>;

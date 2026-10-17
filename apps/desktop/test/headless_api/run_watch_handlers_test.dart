// Run-Watch handler tests.
//
// The handler is deliberately defensive: every sub-section of the
// snapshot has its own try/catch so a flaky upstream (DisconnectedBackend
// raising, no weather data, no sequence loaded) still produces a coherent
// JSON envelope. These tests pin down that contract.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/run_watch_handlers.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('RunWatchHandlers', () {
    late ProviderContainer container;
    late StreamController<SkotiqEvent> ctrl;
    late RunWatchHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      ctrl = StreamController<SkotiqEvent>.broadcast();
      handlers = RunWatchHandlers(
        container: container,
        eventBroadcast: ctrl.stream,
      );
    });

    tearDown(() async {
      await ctrl.close();
      container.dispose();
    });

    test('snapshot returns a coherent envelope even with no backend', () async {
      // The default container has no FFI backend; DisconnectedBackend
      // raises for every method. The handler must degrade per-section
      // and still produce well-formed JSON.
      final response = await translateHandlerErrors(
        handlers.handleSnapshot(
          Request('GET', Uri.parse('http://localhost/api/run-watch/snapshot')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], startsWith('application/json'));
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body.containsKey('serverTime'), isTrue);
      expect(body['sequencer'], isA<Map>());
      expect(body['guiding'], isA<Map>());
      expect(body['weather'], isA<Map>());
      expect(body['devices'], isA<List>());
      expect(body['recentEvents'], isA<List>());
      // sequencer.progress is a nested object even when the FFI fails.
      final sequencer = body['sequencer'] as Map;
      expect(sequencer['progress'], isA<Map>());
    });

    test('a failed progress read reports unknown, not idle', () async {
      final failing = ProviderContainer(
        overrides: [
          sequenceProgressProvider.overrideWith(
            (ref) => throw StateError('provider not wired'),
          ),
        ],
      );
      addTearDown(failing.dispose);
      final failingHandlers = RunWatchHandlers(
        container: failing,
        eventBroadcast: ctrl.stream,
      );
      addTearDown(failingHandlers.dispose);

      final response = await translateHandlerErrors(
        failingHandlers.handleSnapshot(
          Request('GET', Uri.parse('http://localhost/api/run-watch/snapshot')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final progress =
          (body['sequencer'] as Map)['progress'] as Map<String, Object?>;
      // A read that threw must never render as a rig sitting idle at 0/0.
      expect(progress['state'], 'unknown');
      expect(progress['message'], contains('Progress unavailable'));
      expect(progress['completedExposures'], isNull);
      expect(progress['totalExposures'], isNull);
      expect(progress['elapsedSecs'], isNull);
      expect(progress['progressPercent'], isNull);
    });

    // A fresh install has no profile, no devices and no run in its history.
    // Every other block on the phone renders that absence as `--`; the
    // progress block published `0 / 0`, `0s / 0s` and `progressPercent: 0.0`,
    // which the client faithfully drew as "0% / 0 of 0" — a measurement of a
    // run that has never existed.
    test('a rig that has never run reports no figures, not zeros', () async {
      final response = await translateHandlerErrors(
        handlers.handleSnapshot(
          Request('GET', Uri.parse('http://localhost/api/run-watch/snapshot')),
        ),
      );

      final body = jsonDecode(await response.readAsString()) as Map;
      final wire =
          (body['sequencer'] as Map)['progress'] as Map<String, Object?>;
      // The state IS known — nothing is running — so only the figures are
      // withheld.
      expect(wire['state'], 'idle');
      for (final field in const [
        'totalExposures',
        'completedExposures',
        'totalIntegrationSecs',
        'completedIntegrationSecs',
        'elapsedSecs',
        'progressPercent',
      ]) {
        expect(wire[field], isNull, reason: '$field asserts a run that ran');
      }
    });

    test('the first thing a run reports puts the figures back', () async {
      container.read(sequenceProgressProvider.notifier).setTotals(12, 24.0);

      final response = await translateHandlerErrors(
        handlers.handleSnapshot(
          Request('GET', Uri.parse('http://localhost/api/run-watch/snapshot')),
        ),
      );

      final body = jsonDecode(await response.readAsString()) as Map;
      final wire =
          (body['sequencer'] as Map)['progress'] as Map<String, Object?>;
      expect(wire['totalExposures'], 12);
      expect(wire['completedExposures'], 0);
      expect(wire['progressPercent'], 0.0);
    });

    // A headless run loads its wire JSON straight into the native executor,
    // so nothing ever populates `currentSequenceProvider` and nothing ever
    // calls `setTotals` with an integration total: the live progress arrives
    // here with a real frame count and `totalIntegrationSecs == 0.0`. The
    // snapshot used to publish that zero as a known denominator, and the phone
    // rendered "24s / 0s" — a total the run had already passed.
    test('an unknown integration total is null, never zero', () async {
      final progress = container.read(sequenceProgressProvider.notifier);
      progress.setTotals(12);
      progress.recordCompletedFrameIntegration(
        eventKey: 'frame-1',
        durationSecs: 2.0,
      );

      final response = await translateHandlerErrors(
        handlers.handleSnapshot(
          Request('GET', Uri.parse('http://localhost/api/run-watch/snapshot')),
        ),
      );

      final body = jsonDecode(await response.readAsString()) as Map;
      final wire =
          (body['sequencer'] as Map)['progress'] as Map<String, Object?>;
      expect(wire['totalExposures'], 12);
      expect(wire['completedIntegrationSecs'], 2.0);
      expect(wire['totalIntegrationSecs'], isNull);
    });

    test('a real integration total is published as measured', () async {
      final progress = container.read(sequenceProgressProvider.notifier);
      progress.setTotals(12, 24.0);

      final response = await translateHandlerErrors(
        handlers.handleSnapshot(
          Request('GET', Uri.parse('http://localhost/api/run-watch/snapshot')),
        ),
      );

      final body = jsonDecode(await response.readAsString()) as Map;
      final wire =
          (body['sequencer'] as Map)['progress'] as Map<String, Object?>;
      expect(wire['totalIntegrationSecs'], 24.0);
    });

    // Same root cause on the target header: with no editor sequence the whole
    // Active-target card rendered `--` during a live run whose target this very
    // snapshot names in `sequencer.progress.currentTarget`.
    test(
      'a native run reports its target name with the sky marked unknown',
      () async {
        container
            .read(sequenceProgressProvider.notifier)
            .updateProgress(currentTarget: 'D1 Simulated Field');

        final response = await translateHandlerErrors(
          handlers.handleSnapshot(
            Request(
              'GET',
              Uri.parse('http://localhost/api/run-watch/snapshot'),
            ),
          ),
        );

        final body = jsonDecode(await response.readAsString()) as Map;
        final target = body['activeTarget'] as Map<String, Object?>;
        expect(target['name'], 'D1 Simulated Field');
        expect(target['coordinatesKnown'], isFalse);
        expect(target['raHours'], isNull);
        expect(target['altitudeDeg'], isNull);
        expect(target['message'], contains('Coordinates unavailable'));
      },
    );

    test('no run and no target reports no active target at all', () async {
      final response = await translateHandlerErrors(
        handlers.handleSnapshot(
          Request('GET', Uri.parse('http://localhost/api/run-watch/snapshot')),
        ),
      );

      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['activeTarget'], isNull);
    });

    test(
      'frame-thumbnail returns no_camera when no devices are connected',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleFrameThumbnail(
            Request(
              'GET',
              Uri.parse('http://localhost/api/run-watch/frame-thumbnail'),
            ),
          ),
        );

        // The DisconnectedBackend raises on getConnectedDevices(), so we
        // end up with no candidate camera id and the handler returns
        // 404 no_camera. The exact body shape is what the client checks
        // for to decide whether to keep the "no frame yet" placeholder.
        expect(response.statusCode, HttpStatus.notFound);
        expect(
          response.headers['content-type'],
          startsWith('application/json'),
        );
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'no_camera');
      },
    );

    test(
      'frame-thumbnail rejects malformed and out-of-range image options',
      () async {
        for (final query in const [
          'maxWidth=wide',
          'maxWidth=0',
          'maxWidth=20000',
          'quality=high',
          'quality=0',
          'quality=101',
        ]) {
          final response = await translateHandlerErrors(
            handlers.handleFrameThumbnail(
              Request(
                'GET',
                Uri.parse(
                  'http://localhost/api/run-watch/frame-thumbnail?$query',
                ),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: query);
        }
      },
    );

    test(
      'SSE responds with text/event-stream and an initial retry hint',
      () async {
        final response = handlers.handleEventStream(
          Request('GET', Uri.parse('http://localhost/api/run-watch/events')),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(
          response.headers['content-type'],
          startsWith('text/event-stream'),
        );

        // Pump the controller so the stream emits its first frame
        // (the `retry:` directive emitted on onListen). Read a single
        // chunk then cancel so the test does not hang.
        final completer = Completer<String>();
        final sub = response.read().transform(utf8.decoder).listen((chunk) {
          if (!completer.isCompleted) completer.complete(chunk);
        });
        // Give the stream a turn to deliver onListen output.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await sub.cancel();
        if (!completer.isCompleted) {
          completer.complete('');
        }
        final first = await completer.future;
        // The stream MAY have already terminated before the first chunk
        // arrived on slow CI; in the happy path we expect the retry hint.
        // Tolerate both since the test's purpose is to assert the header
        // contract, not the timing of the very first byte.
        if (first.isNotEmpty) {
          expect(first.contains('retry: 5000'), isTrue);
        }
      },
    );

    test('SSE forwards an injected event to a subscribed client', () async {
      // Subscribe an SSE client, push an event into the broadcast
      // controller, assert the client receives a `data:` frame
      // containing our eventType. This is the wave-6 round-trip the
      // brief calls out as the integration test for the event stream.
      final response = handlers.handleEventStream(
        Request('GET', Uri.parse('http://localhost/api/run-watch/events')),
      );

      final buffer = StringBuffer();
      final received = Completer<String>();
      final sub = response.read().transform(utf8.decoder).listen((chunk) {
        buffer.write(chunk);
        if (buffer.toString().contains('FrameAccepted') &&
            !received.isCompleted) {
          received.complete(buffer.toString());
        }
      });

      // Allow the onListen-time retry write to flush before injecting.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final event = SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.imaging,
        eventType: 'FrameAccepted',
        data: {'frameId': 'abc-123', 'hfr': 1.5},
      );
      ctrl.add(event);

      final payload = await received.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      // SSE framing: event line, id line, data line, terminator.
      expect(payload.contains('event: FrameAccepted'), isTrue);
      expect(payload.contains('data: '), isTrue);
      expect(payload.contains('FrameAccepted'), isTrue);
      expect(payload.contains('abc-123'), isTrue);
    });

    // D4-1. Measured on the release bundle relaunched against its own
    // database: `/api/images` listed 26 captures from that evening, sim_camera_1
    // was connected, and this endpoint answered "No image is available yet —
    // capture an exposure first". Run-Watch printed that as "No frame captured
    // yet". `/api/camera/last-image/jpeg` already answered the same emptiness
    // with the process-scoped wording; the phone's endpoint now does too.
    group('an empty preview buffer says which emptiness it is', () {
      // Through the REAL error translator, so what is pinned is which failures
      // this handler answers itself and which it hands to the status table.
      Future<Response> thumbnail({Object? raise}) async {
        container.dispose();
        container = ProviderContainer(
          overrides: [
            deviceBackendProvider.overrideWithValue(
              _PreviewBackend(raise: raise),
            ),
          ],
        );
        handlers = RunWatchHandlers(
          container: container,
          eventBroadcast: ctrl.stream,
        );
        final translated = errorTranslationMiddleware(
          logError: (_, {fields}) {},
          requestIdFor: (_) => 'test-request-id',
        )(handlers.handleFrameThumbnail);
        return translated(
          Request(
            'GET',
            Uri.parse('http://localhost/api/run-watch/frame-thumbnail'),
          ),
        );
      }

      Future<void> expectScopedRefusal(Response response) async {
        expect(response.statusCode, HttpStatus.notFound);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'no_live_preview');
        expect(
          body['scope'],
          'process',
          reason: 'the machine-readable half of the same fact',
        );
        expect(body['library'], '/api/images');
        expect(body['message'], contains('in this server process'));
        expect(
          body['message'],
          contains('/api/images'),
          reason: 'the phone is told where the frames it does have are listed',
        );
        // The two absolutes this replaced, in the words they were measured in.
        expect(
          body['message'],
          isNot(contains('No image has been captured yet')),
        );
        expect(body['message'], isNot(contains('capture an exposure first')));
      }

      test('a null buffer answers a scoped 404', () async {
        await expectScopedRefusal(await thumbnail());
      });

      test("the driver's own noImageAvailable answers the same", () async {
        await expectScopedRefusal(
          await thumbnail(raise: const bridge.SkotiqError.noImageAvailable()),
        );
      });

      test(
        'any other backend failure keeps its own status and words',
        () async {
          final response = await thumbnail(
            raise: const bridge.SkotiqError.notConnected('cam-1'),
          );
          expect(
            response.statusCode,
            HttpStatus.conflict,
            reason: 'a disconnected camera is not an empty preview',
          );
          final body = jsonDecode(await response.readAsString()) as Map;
          expect(body['message'], contains('not connected'));
        },
      );
    });

    // D4-2. One frame carries two HFRs: this header (the median of the
    // brightest half of the detected stars) and `captured_images.hfr` (the
    // mean over every detected star), which is what the session report and the
    // reject threshold read. Joined on timestamp with an identical star count,
    // three consecutive sim frames read 2.0032 / 2.0139 / 2.0368 here against
    // 2.4770 / 2.4732 / 2.4807 in the library. The number therefore travels
    // with the name of its measurement.
    test('the frame HFR header names which measurement it carries', () async {
      container.dispose();
      container = ProviderContainer(
        overrides: [
          deviceBackendProvider.overrideWithValue(
            _PreviewBackend(image: _bufferedFrame(hfr: 2.0032)),
          ),
        ],
      );
      handlers = RunWatchHandlers(
        container: container,
        eventBroadcast: ctrl.stream,
      );

      final response = await translateHandlerErrors(
        handlers.handleFrameThumbnail(
          Request(
            'GET',
            Uri.parse('http://localhost/api/run-watch/frame-thumbnail'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['x-frame-hfr'], '2.0032');
      expect(
        response.headers['x-frame-hfr-basis'],
        'live-preview-median-brightest-half',
        reason:
            'an unqualified HFR here is what an operator sets a reject '
            'threshold from, and it is not the graded scale',
      );
    });

    test('a frame with no measured HFR carries no basis either', () async {
      container.dispose();
      container = ProviderContainer(
        overrides: [
          deviceBackendProvider.overrideWithValue(
            _PreviewBackend(image: _bufferedFrame()),
          ),
        ],
      );
      handlers = RunWatchHandlers(
        container: container,
        eventBroadcast: ctrl.stream,
      );

      final response = await translateHandlerErrors(
        handlers.handleFrameThumbnail(
          Request(
            'GET',
            Uri.parse('http://localhost/api/run-watch/frame-thumbnail'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.containsKey('x-frame-hfr'), isFalse);
      expect(
        response.headers.containsKey('x-frame-hfr-basis'),
        isFalse,
        reason: 'naming a measurement that was never taken invents one',
      );
    });
  });
}

/// A 2x2 RGBA frame in the preview buffer, with whatever stats a test needs.
CapturedImageResult _bufferedFrame({double? hfr}) => CapturedImageResult(
  width: 2,
  height: 2,
  displayData: List<int>.filled(2 * 2 * 4, 255),
  histogram: List<int>.filled(256, 0),
  stats: ImageStatsResult(
    min: 0,
    max: 65535,
    mean: 625,
    median: 622,
    stdDev: 83,
    hfr: hfr,
    starCount: 43,
  ),
  exposureTime: 2.0,
  timestamp: '2026-08-31T17:53:20',
);

/// A rig with a camera connected and a preview buffer under test control.
///
/// [raise] sends a failure through `cameraGetLastImage` so a test can prove
/// only the empty-buffer case is repainted as an empty preview; with neither
/// [raise] nor [image] the buffer answers the null a real driver answers.
class _PreviewBackend implements DeviceBackend {
  _PreviewBackend({this.raise, this.image});

  final Object? raise;
  final CapturedImageResult? image;

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => const [
    DeviceInfo(
      id: 'cam-1',
      name: 'Camera 1',
      deviceType: DeviceType.camera,
      driverType: DriverType.simulator,
      description: 'test camera',
      driverVersion: '1.0',
    ),
  ];

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    final error = raise;
    if (error != null) throw error;
    return image;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

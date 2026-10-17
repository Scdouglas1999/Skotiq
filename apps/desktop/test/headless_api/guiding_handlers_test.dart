import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/guiding_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _PHD2Settings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
    phd2Host: 'localhost',
    phd2Port: 4400,
    phd2Path: '',
  );
}

void main() {
  group('GuidingHandlers', () {
    late ProviderContainer container;
    late GuidingHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = GuidingHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('algo param names validates axis with JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handlePhd2GetAlgoParamNames(
          Request(
            'GET',
            Uri.parse('http://localhost/api/phd2/algo-param-names?axis=bad'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], "Missing or invalid 'axis' query parameter");
    });

    test(
      'set algo param validates required value with JSON bad request',
      () async {
        final response = await translateHandlerErrors(
          handlers.handlePhd2SetAlgoParam(
            Request(
              'POST',
              Uri.parse('http://localhost/api/phd2/algo-param'),
              body: jsonEncode({'axis': 'ra', 'name': 'minMove'}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'value is required');
      },
    );

    test(
      'guider lock position validates missing coordinates as JSON',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleGuiderSetLockPosition(
            Request(
              'POST',
              Uri.parse('http://localhost/api/guider/set-lock-position'),
              body: jsonEncode({'deviceId': 'guider-1', 'x': 10}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'y is required');
      },
    );

    test(
      'disconnected backend returns connected false without HTTP error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handlePhd2GetStatus(
            Request('GET', Uri.parse('http://localhost/api/phd2/status')),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['connected'], isFalse);
        expect(body['state'], 'Disconnected');
      },
    );

    test('connect forwards the requested host and port to the host', () async {
      final backend = _MockBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(
        () => backend.phd2Connect(
          host: any(named: 'host'),
          port: any(named: 'port'),
        ),
      ).thenAnswer((_) async {});
      when(() => backend.phd2GetStatus()).thenAnswer(
        (_) async => const Phd2Status(
          state: 'Stopped',
          connected: true,
          rmsRa: 0,
          rmsDec: 0,
          rmsTotal: 0,
          snr: 0,
          starMass: 0,
          avgDistance: 0,
        ),
      );
      final hostContainer = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(_PHD2Settings.new),
        ],
      );
      addTearDown(hostContainer.dispose);
      final hostHandlers = GuidingHandlers(hostContainer);

      final response = await hostHandlers.handlePhd2Connect(
        Request(
          'POST',
          Uri.parse('http://localhost/api/phd2/connect'),
          body: jsonEncode({'host': '10.0.0.9', 'port': 4401}),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      verify(() => backend.phd2Connect(host: '10.0.0.9', port: 4401)).called(1);
    });

    test(
      'start rejects impossible settle bounds before backend work',
      () async {
        final response = await translateHandlerErrors(
          handlers.handlePhd2StartGuiding(
            Request(
              'POST',
              Uri.parse('http://localhost/api/phd2/start-guiding'),
              body: jsonEncode({'settlePixels': 0}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['field'], 'settlePixels');
      },
    );

    test('Stop is the final host command when Start was in flight', () async {
      final backend = _MockBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      final startGate = Completer<void>();
      when(
        () => backend.guiderStartGuiding(
          deviceId: any(named: 'deviceId'),
          settlePixels: any(named: 'settlePixels'),
          settleTime: any(named: 'settleTime'),
          settleTimeout: any(named: 'settleTimeout'),
        ),
      ).thenAnswer((_) => startGate.future);
      when(
        () => backend.guiderStopGuiding(deviceId: any(named: 'deviceId')),
      ).thenAnswer((_) async {});
      final hostContainer = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(hostContainer.dispose);
      final hostHandlers = GuidingHandlers(hostContainer);
      final start = hostHandlers.handleGuiderStartGuiding(
        Request(
          'POST',
          Uri.parse('http://localhost/api/guider/start-guiding'),
          body: jsonEncode({'deviceId': kPhd2CanonicalId}),
        ),
      );
      final stop = hostHandlers.handleGuiderStopGuiding(
        Request(
          'POST',
          Uri.parse('http://localhost/api/guider/stop-guiding'),
          body: jsonEncode({'deviceId': kPhd2CanonicalId}),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      verify(
        () => backend.guiderStopGuiding(deviceId: kPhd2CanonicalId),
      ).called(1);
      startGate.complete();
      await start;
      await stop;
      verify(
        () => backend.guiderStopGuiding(deviceId: kPhd2CanonicalId),
      ).called(1);
    });
  });

  // Fail-closed semantic validation of the GET/query endpoints: a supplied but
  // malformed value must be a 400 BEFORE any backend probe, while absence keeps
  // the documented default. A capturing backend proves both the forwarded value
  // and that no probe runs on rejection.
  group('GuidingHandlers query validation (fail-closed)', () {
    late _CapturingGuidingBackend backend;
    late ProviderContainer container;
    late GuidingHandlers handlers;

    setUp(() {
      backend = _CapturingGuidingBackend();
      container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      handlers = GuidingHandlers(container);
    });

    tearDown(() => container.dispose());

    Future<Response> isRunning(String qs) => translateHandlerErrors(
      handlers.handlePhd2IsRunning(
        Request('GET', Uri.parse('http://localhost/api/phd2/is-running$qs')),
      ),
    );

    test('is-running: absent host+port forwards localhost:4400', () async {
      final r = await isRunning('');
      expect(r.statusCode, HttpStatus.ok);
      expect(backend.isRunningHost, 'localhost');
      expect(backend.isRunningPort, 4400);
    });

    test('is-running: valid host+port forwards verbatim', () async {
      final r = await isRunning('?host=10.0.0.5&port=4402');
      expect(r.statusCode, HttpStatus.ok);
      expect(backend.isRunningHost, '10.0.0.5');
      expect(backend.isRunningPort, 4402);
    });

    test('is-running: empty port is treated as absent → 4400', () async {
      final r = await isRunning('?port=');
      expect(r.statusCode, HttpStatus.ok);
      expect(backend.isRunningPort, 4400);
    });

    test('is-running: port boundaries 1 and 65535 accepted', () async {
      expect((await isRunning('?port=1')).statusCode, HttpStatus.ok);
      expect(backend.isRunningPort, 1);
      expect((await isRunning('?port=65535')).statusCode, HttpStatus.ok);
      expect(backend.isRunningPort, 65535);
    });

    for (final badPort in ['abc', '0', '-1', '70000', '4400.5', '1e3']) {
      test('is-running: rejects port "$badPort" (400, no probe)', () async {
        final r = await isRunning('?port=$badPort');
        expect(r.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await r.readAsString()) as Map;
        expect(body['field'], 'port');
        expect(
          backend.isRunningPort,
          isNull,
          reason: 'no backend probe on an invalid port',
        );
      });
    }

    test('is-running: blank host is 400 and does no work', () async {
      final r = await isRunning('?host=%20%20');
      expect(r.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await r.readAsString()) as Map;
      expect(body['field'], 'host');
      expect(backend.isRunningHost, isNull);
    });

    Future<Response> probe(String qs) => translateHandlerErrors(
      handlers.handlePhd2Probe(
        Request('GET', Uri.parse('http://localhost/api/phd2/probe$qs')),
      ),
    );

    test(
      'probe: forwards the endpoint and returns version + profile',
      () async {
        // A remote client cannot reach the host's loopback PHD2 socket, so the
        // version/profile readout on its Settings page is only as good as this
        // endpoint.
        final r = await probe('?host=10.0.0.5&port=4402');
        expect(r.statusCode, HttpStatus.ok);
        expect(backend.probeHost, '10.0.0.5');
        expect(backend.probePort, 4402);
        final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
        expect(body['outcome'], 'identified');
        expect(body['version'], '2.6.13');
        expect(body['profile'], 'Main rig');
      },
    );

    test('probe: absent host+port forwards localhost:4400', () async {
      expect((await probe('')).statusCode, HttpStatus.ok);
      expect(backend.probeHost, 'localhost');
      expect(backend.probePort, 4400);
    });

    test('probe: rejects a bad port (400, no probe)', () async {
      final r = await probe('?port=70000');
      expect(r.statusCode, HttpStatus.badRequest);
      expect(backend.probePort, isNull);
    });

    Future<Response> phd2StarImage(String qs) => translateHandlerErrors(
      handlers.handlePhd2GetStarImage(
        Request('GET', Uri.parse('http://localhost/api/phd2/star-image$qs')),
      ),
    );

    test('phd2 star-image: absent size forwards default 50', () async {
      expect((await phd2StarImage('')).statusCode, HttpStatus.ok);
      expect(backend.phd2StarImageSize, 50);
    });

    test('phd2 star-image: valid + max-boundary sizes forward', () async {
      expect((await phd2StarImage('?size=128')).statusCode, HttpStatus.ok);
      expect(backend.phd2StarImageSize, 128);
      expect((await phd2StarImage('?size=2048')).statusCode, HttpStatus.ok);
      expect(backend.phd2StarImageSize, 2048);
    });

    for (final bad in ['abc', '0', '-5', '2049', '50.5', 'NaN']) {
      test('phd2 star-image: rejects size "$bad" (400, no probe)', () async {
        final r = await phd2StarImage('?size=$bad');
        expect(r.statusCode, HttpStatus.badRequest);
        expect(backend.phd2StarImageSize, isNull);
      });
    }

    Future<Response> guiderStarImage(String qs) => translateHandlerErrors(
      handlers.handleGuiderGetStarImage(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/api/guider/star-image?deviceId=guider-1$qs',
          ),
        ),
      ),
    );

    test('guider star-image: absent size forwards default 50', () async {
      expect((await guiderStarImage('')).statusCode, HttpStatus.ok);
      expect(backend.guiderStarImageSize, 50);
    });

    test('guider star-image: valid size forwards verbatim', () async {
      expect((await guiderStarImage('&size=200')).statusCode, HttpStatus.ok);
      expect(backend.guiderStarImageSize, 200);
    });

    for (final bad in ['abc', '0', '-1', '2049']) {
      test('guider star-image: rejects size "$bad" (400, no probe)', () async {
        final r = await guiderStarImage('&size=$bad');
        expect(r.statusCode, HttpStatus.badRequest);
        expect(backend.guiderStarImageSize, isNull);
      });
    }
  });

  group('GuidingHandlers normal empty PHD2 state', () {
    late ProviderContainer container;
    late GuidingHandlers handlers;

    setUp(() {
      final backend = _NoPHD2SelectionBackend();
      container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      handlers = GuidingHandlers(container);
    });

    tearDown(() => container.dispose());

    test('missing lock position is a structured conflict', () async {
      final response = await translateHandlerErrors(
        handlers.handlePhd2GetLockPosition(
          Request('GET', Uri.parse('http://localhost/api/phd2/lock-position')),
        ),
      );

      expect(response.statusCode, HttpStatus.conflict);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'no_lock_position');
      expect(body['error'], 'PHD2 has no guide-star lock position.');
    });

    test('missing selected star image is a structured conflict', () async {
      final response = await translateHandlerErrors(
        handlers.handlePhd2GetStarImage(
          Request('GET', Uri.parse('http://localhost/api/phd2/star-image')),
        ),
      );

      expect(response.statusCode, HttpStatus.conflict);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'no_star_selected');
      expect(body['error'], 'PHD2 has no guide star selected.');
    });
  });
}

/// [DisconnectedBackend] that records the forwarded host/port/size instead of
/// throwing, so tests can assert what reached the backend (and that nothing did
/// on a rejected request).
class _CapturingGuidingBackend extends DisconnectedBackend {
  String? isRunningHost;
  int? isRunningPort;
  String? probeHost;
  int? probePort;
  int? phd2StarImageSize;
  int? guiderStarImageSize;

  @override
  Future<bool> isPhd2Running({
    String host = 'localhost',
    int port = 4400,
  }) async {
    isRunningHost = host;
    isRunningPort = port;
    return true;
  }

  @override
  Future<Phd2ProbeResult> phd2Probe({
    String host = 'localhost',
    int port = 4400,
  }) async {
    probeHost = host;
    probePort = port;
    return const Phd2ProbeResult(
      outcome: Phd2ProbeOutcome.identified,
      version: '2.6.13',
      profile: 'Main rig',
    );
  }

  @override
  Future<Phd2StarImage> phd2GetStarImage({int size = 50}) async {
    phd2StarImageSize = size;
    return _emptyStarImage(size);
  }

  @override
  Future<Phd2StarImage> guiderGetStarImage({
    required String deviceId,
    int size = 50,
  }) async {
    guiderStarImageSize = size;
    return _emptyStarImage(size);
  }

  static Phd2StarImage _emptyStarImage(int size) => Phd2StarImage(
    frame: 1,
    width: size,
    height: size,
    starX: 0,
    starY: 0,
    pixels: Uint8List(0),
  );
}

class _NoPHD2SelectionBackend extends DisconnectedBackend {
  @override
  Future<(double, double)> phd2GetLockPosition() {
    throw const bridge.SkotiqError.operationFailed(
      'Failed to get lock position: get_lock_position: expected array, got null',
    );
  }

  @override
  Future<Phd2StarImage> phd2GetStarImage({int size = 50}) {
    throw const bridge.SkotiqError.operationFailed(
      'Failed to get star image: PHD2 error: no star selected',
    );
  }
}

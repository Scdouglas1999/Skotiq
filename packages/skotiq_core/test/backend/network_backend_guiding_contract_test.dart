import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/services/phd2_probe.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

Map<String, dynamic> _status({Object? trackedStars}) => {
  'state': 'Guiding',
  'connected': true,
  'rmsRa': 0.4,
  'rmsDec': 0.5,
  'rmsTotal': 0.64,
  'snr': 18.0,
  'starMass': 1200.0,
  'avgDistance': 0.3,
  if (trackedStars != null) 'trackedStars': trackedStars,
};

void main() {
  group('NetworkBackend guiding contracts', () {
    test(
      'PHD2 running accepts 404 compatibility but not malformed success',
      () async {
        final oldHost = FakeNetworkClient()
          ..setResponse(
            '/api/phd2/running',
            status: 404,
            body: '{"code":"not_found","message":"Unknown endpoint"}',
          );
        final oldBackend = _backend(oldHost);
        addTearDown(oldBackend.dispose);
        expect(await oldBackend.isPhd2Running(), isFalse);

        final malformedHost = FakeNetworkClient()
          ..setResponse('/api/phd2/running', body: '{}');
        final malformedBackend = _backend(malformedHost);
        addTearDown(malformedBackend.dispose);
        await expectLater(
          malformedBackend.isPhd2Running(),
          throwsFormatException,
        );
      },
    );

    test('PHD2 probe carries the version and profile off the wire', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/phd2/probe',
          body: jsonEncode({
            'outcome': 'identified',
            'version': '2.6.13',
            'subVersion': 'dev4',
            'profile': 'Main rig',
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final probe = await backend.phd2Probe(host: '10.0.0.5', port: 4402);
      expect(probe.outcome, Phd2ProbeOutcome.identified);
      expect(probe.fullVersion, '2.6.13dev4');
      expect(probe.profile, 'Main rig');
    });

    test(
      'a master without the probe endpoint does not invent a version',
      () async {
        // The 404 degrade must not become "PHD2 answered": a host without the
        // probe endpoint has reported nothing about PHD2's version.
        final oldHost = FakeNetworkClient()
          ..setResponse(
            '/api/phd2/probe',
            status: 404,
            body: '{"code":"not_found","message":"Unknown endpoint"}',
          )
          ..setResponse('/api/phd2/running', body: '{"running":true}');
        final backend = _backend(oldHost);
        addTearDown(backend.dispose);

        final probe = await backend.phd2Probe();
        expect(probe.outcome, Phd2ProbeOutcome.reachableUnverified);
        expect(probe.isPhd2, isFalse);
        expect(probe.version, isNull);
      },
    );

    test(
      'complete PHD2 status decodes and older host may omit stars',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse('/api/phd2/status', body: jsonEncode(_status()));
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        final status = await backend.phd2GetStatus();
        expect(status.connected, isTrue);
        expect(status.state, 'Guiding');
        expect(status.rmsTotal, 0.64);
        expect(status.trackedStars, isEmpty);
      },
    );

    test(
      'missing required status data does not look safely disconnected',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/phd2/status',
            body: jsonEncode({..._status()}..remove('connected')),
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        await expectLater(backend.phd2GetStatus(), throwsFormatException);
      },
    );

    test(
      'malformed tracked stars are not silently dropped or zero-filled',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/phd2/status',
            body: jsonEncode(
              _status(
                trackedStars: [
                  {'id': 3, 'x': 10.0},
                ],
              ),
            ),
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        await expectLater(backend.phd2GetStatus(), throwsFormatException);
      },
    );
  });
}

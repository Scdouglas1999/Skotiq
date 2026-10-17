// Tests for the remote switch-control request shapes on [NetworkBackend].
//
// The per-channel switch UI is dead over the network without them: the server's
// `POST /api/switch/set` REQUIRES a `deviceId`
// (apps/desktop/.../auxiliary_handlers.dart), and `getSwitchStatus` without a
// `deviceId` returns the all-devices summary instead of the single-device
// `switches` shape the UI needs. All HTTP is
// served by the MockClient-backed FakeNetworkClient — no real server needed.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

void main() {
  group('NetworkBackend switch control', () {
    test('getSwitchStatus scopes to the device via ?deviceId=', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/switch/status',
          method: 'GET',
          body:
              '{"switchCount":1,"switches":[{"id":0,"name":"Dew A",'
              '"type":"boolean","value":true}]}',
        );
      final backend = _backend(fake);

      final status = await backend.getSwitchStatus(deviceId: 'sim_switch_1');

      expect(status['switchCount'], 1);
      final req = fake.requestsFor('/api/switch/status').single;
      expect(req.method, 'GET');
      expect(req.url.queryParameters['deviceId'], 'sim_switch_1');
    });

    test('getSwitchStatus omits deviceId when none given', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/switch/status', body: '{"devicesConnected":0}');
      final backend = _backend(fake);

      await backend.getSwitchStatus();

      final req = fake.requestsFor('/api/switch/status').single;
      expect(req.url.queryParameters.containsKey('deviceId'), isFalse);
    });

    test('setSwitch sends deviceId + switchId + value (server requires '
        'deviceId)', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/switch/set',
          method: 'POST',
          body: '{"status":"ok"}',
        );
      final backend = _backend(fake);

      await backend.setSwitch(
        deviceId: 'sim_switch_1',
        switchId: 2,
        value: true,
      );

      final req = fake.requestsFor('/api/switch/set').single;
      expect(req.method, 'POST');
      final body = jsonDecode(req.body!) as Map<String, dynamic>;
      expect(body['deviceId'], 'sim_switch_1');
      expect(body['switchId'], 2);
      expect(body['value'], true);
    });
  });
}

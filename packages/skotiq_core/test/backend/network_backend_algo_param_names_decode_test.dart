// phd2GetAlgoParamNames decodes the algorithm parameter names from the SAME
// JSON key the server emits: the headless handler
// (handlePhd2GetAlgoParamNames) returns `{"axis": ..., "names": [...]}`, so
// this pins the decode to 'names'. Any other key yields null and throws on
// cast.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fakes.dart';

void main() {
  test('phd2GetAlgoParamNames decodes the server "names" envelope', () async {
    final body = jsonEncode({
      'axis': 'ra',
      'names': ['MinMove', 'Aggression', 'Hysteresis'],
    });

    final fake = FakeNetworkClient()
      ..setResponse('/api/phd2/algo-params', method: 'GET', body: body);

    final backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 9999,
      webSocketPort: 9999,
      httpClient: fake,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);

    final names = await backend.phd2GetAlgoParamNames(axis: 'ra');

    expect(names, equals(['MinMove', 'Aggression', 'Hysteresis']));
  });
}

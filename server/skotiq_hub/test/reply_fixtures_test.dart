// The app's constellation client parses these hub replies leniently (a
// missing key reads as a default), so a renamed key would decode silently.
// This test writes real replies to test_fixtures/hub_replies/<name>.json, and
// skotiq_core's constellation_hub_reply_fixture_test parses them. Without
// SKOTIQ_WRITE_FIXTURES the committed files must have the live reply's keys
// and value kinds; regenerate with
// `SKOTIQ_WRITE_FIXTURES=1 dart test test/reply_fixtures_test.dart`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

const _fixtureDir = '../../test_fixtures/hub_replies';

/// Keys, nesting and value kinds of [value], without the values.
Object? _shape(Object? value) => switch (value) {
  final Map<String, Object?> map => {
    for (final key in map.keys.toList()..sort()) key: _shape(map[key]),
  },
  final List<Object?> list => [if (list.isNotEmpty) _shape(list.first)],
  num() => 'number',
  String() => 'string',
  bool() => 'bool',
  null => 'null',
  _ => value.runtimeType.toString(),
};

void _pin(String name, Map<String, Object?> reply) {
  final file = File('$_fixtureDir/$name.json');
  if (Platform.environment['SKOTIQ_WRITE_FIXTURES'] == '1') {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(reply)}\n',
    );
    return;
  }
  expect(
    file.existsSync(),
    isTrue,
    reason: 'missing ${file.path}; run with SKOTIQ_WRITE_FIXTURES=1',
  );
  final committed = jsonDecode(file.readAsStringSync());
  expect(
    _shape(reply),
    _shape(committed),
    reason:
        'the $name reply changed; regenerate ${file.path} and update the '
        "app's parser",
  );
}

void main() {
  late Directory tmp;
  late HubServer server;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('skhub_fixtures_');
    server = HubServer(
      HubConfig(
        databasePath: ':memory:',
        atlasRoot: '${tmp.path}/atlas',
        serverSecret: 'test-secret',
        openSignup: true,
        acceptsRawSubs: true,
        tilePixels: 8,
      ),
    );
  });

  tearDown(() {
    server.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> call(
    String method,
    String path, {
    String? token,
    Object? jsonBody,
    Uint8List? binaryBody,
  }) async {
    final response = await server.handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {
          if (token != null) 'authorization': 'Bearer $token',
          if (jsonBody != null) 'content-type': 'application/json',
          if (binaryBody != null) 'content-type': 'application/octet-stream',
        },
        body: jsonBody != null ? jsonEncode(jsonBody) : binaryBody,
      ),
    );
    expect(
      response.statusCode,
      inInclusiveRange(200, 201),
      reason: '$method $path',
    );
    return jsonDecode(await response.readAsString()) as Map<String, Object?>;
  }

  Uint8List delta(double value, int frames) => TileBuilder.synthetic(
    tileId: 9,
    order: 9,
    value: value,
    frames: frames,
    width: 8,
    height: 8,
    contributor: 'imager',
  ).serialize();

  test('the hub replies the app parses keep their keys', () async {
    _pin('info', await call('GET', '/v1/info'));

    final account = await call(
      'POST',
      '/v1/accounts',
      jsonBody: {'publicKey': 'imager', 'displayName': 'Imager'},
    );
    _pin('account', account);
    final token = account['bearerToken'] as String;
    server.accounts.setTrust(server.tokens.resolve(token)!.accountId, 1.0);

    _pin(
      'contribution',
      await call(
        'POST',
        '/v1/tiles/9/contributions?order=9&framesDelta=4&'
            'integrationSecondsDelta=1200&license=cc-by',
        token: token,
        binaryBody: delta(100.0, 4),
      ),
    );
    final second = await call(
      'POST',
      '/v1/tiles/9/contributions?order=9&framesDelta=1&'
          'integrationSecondsDelta=300&license=cc-by',
      token: token,
      binaryBody: delta(120.0, 1),
    );
    _pin(
      'retraction',
      await call(
        'DELETE',
        '/v1/contributions/${second['contributionId']}',
        token: token,
      ),
    );

    final card = 'SIMPLE  =                    T'.padRight(80);
    _pin(
      'subframe',
      await call(
        'POST',
        '/v1/tiles/9/subframes?order=9&capturedImageId=7&'
            'exposureSeconds=120&license=cc-by',
        token: token,
        binaryBody: Uint8List.fromList(card.codeUnits),
      ),
    );
  });
}

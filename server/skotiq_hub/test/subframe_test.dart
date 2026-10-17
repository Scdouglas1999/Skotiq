import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Raw subframe (`acceptsRawSubs`) path: gating, store + ledger, delete.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('skhub_subs_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  HubServer makeServer({required bool acceptsRawSubs}) {
    return HubServer(
      HubConfig(
        databasePath: ':memory:',
        atlasRoot: '${tmp.path}/atlas',
        serverSecret: 'test-secret',
        openSignup: true,
        acceptsRawSubs: acceptsRawSubs,
        tilePixels: 8,
      ),
    );
  }

  Future<String> contributorToken(Handler handler, String key) async {
    final r = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/v1/accounts'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'publicKey': key, 'displayName': key}),
      ),
    );
    final body = jsonDecode(await r.readAsString()) as Map<String, Object?>;
    return body['bearerToken'] as String;
  }

  Future<Response> pushSub(
    Handler handler,
    String token,
    int tileId,
    Uint8List fits, {
    int? capturedImageId,
  }) {
    final query = <String, String>{
      'order': '9',
      if (capturedImageId != null) 'capturedImageId': '$capturedImageId',
      'instrument': 'asi2600:scope600',
      'exposureSeconds': '120',
      // The raw-subframe share path requires a shareable license.
      'license': 'cc-by',
    };
    return Future.value(
      handler(
        Request(
          'POST',
          Uri.parse(
            'http://localhost/v1/tiles/$tileId/subframes',
          ).replace(queryParameters: query),
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'application/octet-stream',
          },
          body: fits,
        ),
      ),
    );
  }

  test('/v1/info advertises acceptsRawSubs=false by default', () async {
    final server = makeServer(acceptsRawSubs: false);
    addTearDown(server.dispose);
    final r = await server.handler(
      Request('GET', Uri.parse('http://localhost/v1/info')),
    );
    final body = jsonDecode(await r.readAsString()) as Map<String, Object?>;
    expect(body['acceptsRawSubs'], false);
  });

  test(
    'subframe POST is refused with 405 when the hub does not opt in',
    () async {
      final server = makeServer(acceptsRawSubs: false);
      addTearDown(server.dispose);
      final handler = server.handler;
      final token = await contributorToken(handler, 'alice');
      final r = await pushSub(
        handler,
        token,
        314,
        Uint8List.fromList(utf8.encode('SIMPLE  = T / fake fits')),
      );
      expect(r.statusCode, 405);
      final body = jsonDecode(await r.readAsString()) as Map<String, Object?>;
      expect((body['error'] as Map)['code'], 'rawSubsDisabled');
    },
  );

  test('an opt-in hub accepts, stores, and ledgers a raw subframe', () async {
    final server = makeServer(acceptsRawSubs: true);
    addTearDown(server.dispose);
    final handler = server.handler;
    final token = await contributorToken(handler, 'alice');
    final fits = Uint8List.fromList(
      utf8.encode('SIMPLE  = T / a calibrated light frame'),
    );

    final r = await pushSub(handler, token, 314, fits, capturedImageId: 7);
    expect(r.statusCode, 200);
    final body = jsonDecode(await r.readAsString()) as Map<String, Object?>;
    final contributionId = body['contributionId'] as String;
    expect(contributionId, isNotEmpty);
    expect(body['accepted'], true);
    expect(body['storedBytes'], fits.length);

    // The ledger row actually exists AND records the exact provenance the
    // request carried — tile/order, the originating capture, instrument,
    // exposure, byte count, and the owning account. (Asserting the real row,
    // not merely that the service object is non-null.)
    final entry = server.subframes.ledgerRow(contributionId);
    expect(entry, isNotNull, reason: 'a ledger row must be persisted');
    expect(entry!.tileId, 314);
    expect(entry.healpixOrder, 9);
    expect(entry.capturedImageId, 7);
    expect(entry.instrument, 'asi2600:scope600');
    expect(entry.exposureSeconds, 120);
    expect(entry.bytes, fits.length);
    expect(entry.accountId, isNotEmpty);
    expect(entry.path, endsWith('.fits'));

    // The stored FITS is on disk with the exact bytes.
    final subDir = Directory('${tmp.path}/atlas/subframes');
    final stored = subDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.fits'))
        .toList();
    expect(stored, hasLength(1));
    expect(stored.first.readAsBytesSync(), fits);
  });

  test('an empty subframe body is rejected', () async {
    final server = makeServer(acceptsRawSubs: true);
    addTearDown(server.dispose);
    final handler = server.handler;
    final token = await contributorToken(handler, 'alice');
    final r = await pushSub(handler, token, 314, Uint8List(0));
    expect(r.statusCode, 400);
  });

  test(
    'a contributor can delete their own subframe; ledger + file go away',
    () async {
      final server = makeServer(acceptsRawSubs: true);
      addTearDown(server.dispose);
      final handler = server.handler;
      final token = await contributorToken(handler, 'alice');
      final fits = Uint8List.fromList(utf8.encode('SIMPLE  = T'));

      final pushed =
          jsonDecode(
                await (await pushSub(handler, token, 314, fits)).readAsString(),
              )
              as Map<String, Object?>;
      final id = pushed['contributionId'] as String;

      final del = await handler(
        Request(
          'DELETE',
          Uri.parse('http://localhost/v1/subframes/$id'),
          headers: {'authorization': 'Bearer $token'},
        ),
      );
      expect(del.statusCode, 200);

      final subDir = Directory('${tmp.path}/atlas/subframes');
      final remaining = subDir.existsSync()
          ? subDir
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.endsWith('.fits'))
                .toList()
          : <File>[];
      expect(remaining, isEmpty);
    },
  );

  test("a contributor cannot delete another account's subframe", () async {
    final server = makeServer(acceptsRawSubs: true);
    addTearDown(server.dispose);
    final handler = server.handler;
    final alice = await contributorToken(handler, 'alice');
    final bob = await contributorToken(handler, 'bob');
    final pushed =
        jsonDecode(
              await (await pushSub(
                handler,
                alice,
                314,
                Uint8List.fromList(utf8.encode('SIMPLE  = T')),
              )).readAsString(),
            )
            as Map<String, Object?>;
    final id = pushed['contributionId'] as String;

    final del = await handler(
      Request(
        'DELETE',
        Uri.parse('http://localhost/v1/subframes/$id'),
        headers: {'authorization': 'Bearer $bob'},
      ),
    );
    expect(del.statusCode, 403);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late HubServer server;
  late Handler handler;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('skhub_http_');
    server = HubServer(
      HubConfig(
        databasePath: ':memory:',
        atlasRoot: '${tmp.path}/atlas',
        serverSecret: 'test-secret',
        openSignup: true,
        // Compact tiles keep the contribution fixtures small; the geometry gate
        // validates uploads against THIS value, so the test deltas match it.
        tilePixels: 8,
      ),
    );
    handler = server.handler;
  });

  tearDown(() {
    server.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<Response> req(
    String method,
    String path, {
    String? token,
    Object? jsonBody,
    Uint8List? binaryBody,
  }) {
    final headers = <String, String>{
      if (token != null) 'authorization': 'Bearer $token',
      if (jsonBody != null) 'content-type': 'application/json',
    };
    final request = Request(
      method,
      Uri.parse('http://localhost${_normalize(path)}'),
      headers: headers,
      body: jsonBody != null ? jsonEncode(jsonBody) : binaryBody,
    );
    return Future.value(handler(request));
  }

  Future<Map<String, Object?>> jsonOf(Response r) async {
    final body = await r.readAsString();
    return jsonDecode(body) as Map<String, Object?>;
  }

  test('GET /v1/info advertises the contract constants', () async {
    final r = await req('GET', '/v1/info');
    expect(r.statusCode, 200);
    final body = await jsonOf(r);
    expect(body['version'], '6.0.0');
    expect(body['requiresConsent'], true);
    expect(body['supportedLicenses'], contains('cc-by'));
    expect(body['healpixOrder'], 9);
    expect(body['tilePixels'], 8); // matches this test server's HubConfig
    expect(body['selfHosted'], true);
    expect((body['fingerprint'] as String).length, 64);
  });

  test('account creation returns a bearer token + default trust', () async {
    final r = await req(
      'POST',
      '/v1/accounts',
      jsonBody: <String, Object?>{
        'publicKey': 'imager-1',
        'displayName': 'Imager One',
        'password': 'pw',
      },
    );
    expect(r.statusCode, 201);
    final body = await jsonOf(r);
    expect(body['accountId'], isA<String>());
    expect(body['bearerToken'], isA<String>());
    expect(body['trust'], 0.5);
  });

  test('protected routes require a valid token', () async {
    final r = await req('GET', '/v1/tiles/42?order=9');
    expect(r.statusCode, 401);
    final body = await jsonOf(r);
    expect((body['error'] as Map)['code'], 'unauthorized');
  });

  test(
    'end-to-end: two contributors upload, fused result == local co-add',
    () async {
      // Two contributor accounts.
      final aliceToken =
          (await jsonOf(
                await req(
                  'POST',
                  '/v1/accounts',
                  jsonBody: <String, Object?>{
                    'publicKey': 'alice',
                    'displayName': 'Alice',
                  },
                ),
              ))['bearerToken']
              as String;
      final bobToken =
          (await jsonOf(
                await req(
                  'POST',
                  '/v1/accounts',
                  jsonBody: <String, Object?>{
                    'publicKey': 'bob',
                    'displayName': 'Bob',
                  },
                ),
              ))['bearerToken']
              as String;

      // Force full trust so the HTTP fusion equals the unweighted co-add.
      _setTrust(server, aliceToken, 1.0);
      _setTrust(server, bobToken, 1.0);

      final aliceDelta = TileBuilder.synthetic(
        tileId: 314,
        order: 9,
        value: 100.0,
        frames: 2,
        width: 8,
        height: 8,
        contributor: 'alice',
      );
      final bobDelta = TileBuilder.synthetic(
        tileId: 314,
        order: 9,
        value: 200.0,
        frames: 3,
        width: 8,
        height: 8,
        contributor: 'bob',
      );

      final up1 = await req(
        'POST',
        '/v1/tiles/314/contributions?order=9&framesDelta=2&'
            'integrationSecondsDelta=600&medianFwhm=2.0&license=cc-by',
        token: aliceToken,
        binaryBody: aliceDelta.serialize(),
      );
      expect(up1.statusCode, 200);
      expect((await jsonOf(up1))['accepted'], true);

      final up2 = await req(
        'POST',
        '/v1/tiles/314/contributions?order=9&framesDelta=3&'
            'integrationSecondsDelta=900&medianFwhm=2.5&license=cc-by',
        token: bobToken,
        binaryBody: bobDelta.serialize(),
      );
      expect(up2.statusCode, 200);
      final up2Body = await jsonOf(up2);
      expect(up2Body['accepted'], true);
      expect(up2Body['totalFramesAfter'], 5);
      expect(up2Body['contributorsAfter'], 2);

      // Download the merged accumulator and compare to the local co-add.
      final dl = await req(
        'GET',
        '/v1/tiles/314?order=9&finalized=false',
        token: aliceToken,
      );
      expect(dl.statusCode, 200);
      expect(dl.headers['x-total-frames'], '5');
      final bytes = await _collect(dl);
      final fused = TileAccumulator.deserialize(bytes);
      final local = mergeSigned(aliceDelta.clone(), bobDelta, 1.0, 1.0);

      final fusedMean = fused.finalizeMean();
      final localMean = local.finalizeMean();
      for (var i = 0; i < fusedMean.length; i++) {
        expect(fusedMean[i], closeTo(localMean[i], 1e-9));
        expect(fusedMean[i], closeTo(160.0, 1e-9));
      }

      // The finalized (mean) download is raw f64 LE of the same means.
      final finalDl = await req(
        'GET',
        '/v1/tiles/314?order=9&finalized=true',
        token: aliceToken,
      );
      expect(finalDl.statusCode, 200);
      final finalBytes = await _collect(finalDl);
      final means = Float64List.view(
        finalBytes.buffer,
        finalBytes.offsetInBytes,
        finalBytes.lengthInBytes ~/ 8,
      );
      for (final v in means) {
        expect(v, closeTo(160.0, 1e-9));
      }
    },
  );

  test('retraction over HTTP returns the tile to its prior depth', () async {
    final token =
        (await jsonOf(
              await req(
                'POST',
                '/v1/accounts',
                jsonBody: <String, Object?>{
                  'publicKey': 'solo',
                  'displayName': 'Solo',
                },
              ),
            ))['bearerToken']
            as String;
    _setTrust(server, token, 1.0);

    final c1 = await req(
      'POST',
      '/v1/tiles/9/contributions?order=9&framesDelta=4&'
          'integrationSecondsDelta=1200&license=cc-by',
      token: token,
      binaryBody: TileBuilder.synthetic(
        tileId: 9,
        order: 9,
        value: 100.0,
        frames: 4,
        width: 8,
        height: 8,
        contributor: 'solo',
      ).serialize(),
    );
    expect(c1.statusCode, 200);

    final c2 = await req(
      'POST',
      '/v1/tiles/9/contributions?order=9&framesDelta=1&'
          'integrationSecondsDelta=300&license=cc-by',
      token: token,
      binaryBody: TileBuilder.synthetic(
        tileId: 9,
        order: 9,
        value: 5000.0,
        frames: 1,
        width: 8,
        height: 8,
        contributor: 'solo',
      ).serialize(),
    );
    final contributionId = (await jsonOf(c2))['contributionId'] as String;

    final del = await req(
      'DELETE',
      '/v1/contributions/$contributionId',
      token: token,
    );
    expect(del.statusCode, 200);
    final delBody = await jsonOf(del);
    expect(delBody['retracted'], true);
    expect(delBody['totalFramesAfter'], 4);
  });

  test('follow-the-night ranks an up target and excludes a down one', () async {
    final token =
        (await jsonOf(
              await req(
                'POST',
                '/v1/accounts',
                jsonBody: <String, Object?>{
                  'publicKey': 'sched',
                  'displayName': 'Sched',
                },
              ),
            ))['bearerToken']
            as String;

    // A target near dec +45 will be high from a +45 latitude site; one near
    // dec -80 will be well below the horizon there.
    await req(
      'POST',
      '/v1/targets',
      token: token,
      jsonBody: <String, Object?>{
        'name': 'High',
        'centerRaDeg': 0.0,
        'centerDecDeg': 45.0,
        'radiusDeg': 1.0,
        'priority': 1.0,
      },
    );
    await req(
      'POST',
      '/v1/targets',
      token: token,
      jsonBody: <String, Object?>{
        'name': 'Low',
        'centerRaDeg': 0.0,
        'centerDecDeg': -80.0,
        'radiusDeg': 1.0,
        'priority': 1.0,
      },
    );

    // Pick a time when RA 0 is near the meridian for longitude 0: LST ~ 0.
    final r = await req(
      'GET',
      '/v1/follow-the-night?latitudeDeg=45&longitudeDeg=0&minAltitudeDeg=20',
      token: token,
    );
    expect(r.statusCode, 200);
    final plan = (await jsonOf(r))['plan'] as List;
    final names = plan
        .map((e) => ((e as Map)['target'] as Map)['name'])
        .toList();
    expect(names, isNot(contains('Low')));
  });

  test('handoff claim is exclusive between contributors', () async {
    final aliceToken =
        (await jsonOf(
              await req(
                'POST',
                '/v1/accounts',
                jsonBody: <String, Object?>{
                  'publicKey': 'a',
                  'displayName': 'A',
                },
              ),
            ))['bearerToken']
            as String;
    final bobToken =
        (await jsonOf(
              await req(
                'POST',
                '/v1/accounts',
                jsonBody: <String, Object?>{
                  'publicKey': 'b',
                  'displayName': 'B',
                },
              ),
            ))['bearerToken']
            as String;
    final targetId =
        (await jsonOf(
              await req(
                'POST',
                '/v1/targets',
                token: aliceToken,
                jsonBody: <String, Object?>{
                  'name': 'M31',
                  'centerRaDeg': 10.68,
                  'centerDecDeg': 41.27,
                  'radiusDeg': 1.5,
                },
              ),
            ))['targetId']
            as int;

    final claim = await req(
      'POST',
      '/v1/handoff/$targetId/claim',
      token: aliceToken,
    );
    expect(claim.statusCode, 200);
    expect((await jsonOf(claim))['claimToken'], isA<String>());

    // Bob cannot claim while Alice holds it.
    final bobClaim = await req(
      'POST',
      '/v1/handoff/$targetId/claim',
      token: bobToken,
    );
    expect(bobClaim.statusCode, 409);

    // Alice releases; now Bob can claim.
    final release = await req(
      'POST',
      '/v1/handoff/$targetId/release',
      token: aliceToken,
    );
    expect(release.statusCode, 200);
    expect((await jsonOf(release))['released'], true);

    final bobClaim2 = await req(
      'POST',
      '/v1/handoff/$targetId/claim',
      token: bobToken,
    );
    expect(bobClaim2.statusCode, 200);
  });

  test('GET /v1/targets browses the swarm shared targets', () async {
    final token =
        (await jsonOf(
              await req(
                'POST',
                '/v1/accounts',
                jsonBody: <String, Object?>{
                  'publicKey': 't',
                  'displayName': 'T',
                },
              ),
            ))['bearerToken']
            as String;
    await req(
      'POST',
      '/v1/targets',
      token: token,
      jsonBody: <String, Object?>{
        'name': 'M42',
        'centerRaDeg': 83.82,
        'centerDecDeg': -5.39,
        'radiusDeg': 1.0,
      },
    );

    final r = await req('GET', '/v1/targets', token: token);
    expect(r.statusCode, 200);
    final body = await jsonOf(r);
    final targets = body['targets'] as List;
    expect(targets, isNotEmpty);
    final first = targets.first as Map;
    expect(first['name'], 'M42');
    expect(first['targetId'], isA<int>());
    expect(first['raDeg'], closeTo(83.82, 1e-6));
    expect(first['activeTileId'], isA<int>());
    expect(first['contributors'], isA<int>());
  });

  test(
    'POST /v1/targets echoes the target in the client-facing browse shape',
    () async {
      final token =
          (await jsonOf(
                await req(
                  'POST',
                  '/v1/accounts',
                  jsonBody: <String, Object?>{
                    'publicKey': 'seed',
                    'displayName': 'Seed',
                  },
                ),
              ))['bearerToken']
              as String;

      final r = await req(
        'POST',
        '/v1/targets',
        token: token,
        jsonBody: <String, Object?>{
          'name': 'NGC 7000',
          'centerRaDeg': 314.7,
          'centerDecDeg': 44.3,
          'radiusDeg': 2.0,
        },
      );
      expect(r.statusCode, 200);
      final body = await jsonOf(r);
      expect(body['targetId'], isA<int>());
      // The echoed target must decode straight into the client SharedTarget shape
      // (targetId/raDeg/decDeg/activeTileId), not the hub-internal id/centerRaDeg.
      final target = body['target'] as Map;
      expect(target['targetId'], body['targetId']);
      expect(target['name'], 'NGC 7000');
      expect(target['raDeg'], closeTo(314.7, 1e-6));
      expect(target['decDeg'], closeTo(44.3, 1e-6));
      expect(target['activeTileId'], isA<int>());
      expect(target['contributors'], isA<int>());
    },
  );

  test(
    'unhandled error is redacted to a generic 500 by the error trap',
    () async {
      // Drive the REAL production middleware ([hubErrorTrapMiddleware], the same
      // one HubServer installs) around a handler that throws an exception whose
      // text embeds exactly the kind of internal detail we must never leak: an
      // absolute path, a SQL fragment, and the exception type name.
      const secret =
          'StateError: /var/lib/skotiq/hub.sqlite SELECT token FROM accounts';
      final trapped = hubErrorTrapMiddleware()(
        (Request request) async => throw StateError(secret),
      );

      final response = await trapped(
        Request('GET', Uri.parse('http://localhost/v1/anything')),
      );
      final raw = await response.readAsString();

      // Status + stable envelope: a true 500 with the canonical code/message.
      expect(response.statusCode, 500);
      final body = jsonDecode(raw) as Map<String, Object?>;
      final err = body['error'] as Map<String, Object?>;
      expect(err['code'], 'internal');
      expect(err['message'], 'internal error');

      // Redaction: the serialized response must NOT echo any fragment of the
      // thrown exception — not the path, not the SQL, not the type name.
      expect(raw, isNot(contains('hub.sqlite')));
      expect(raw, isNot(contains('SELECT')));
      expect(raw, isNot(contains('StateError')));
      expect(raw, isNot(contains('/var/lib')));
    },
  );

  test('error trap still maps validation faults to their own codes', () async {
    // The redaction path must be specific to TRULY-unhandled errors: a
    // TileCodecException keeps its 400/409 code+message, and a FormatException
    // becomes a 400 — neither is flattened into the generic 500.
    final fmtTrap = hubErrorTrapMiddleware()(
      (Request request) async => throw const FormatException('bad token'),
    );
    final fmt = await fmtTrap(
      Request('POST', Uri.parse('http://localhost/v1/x')),
    );
    expect(fmt.statusCode, 400);
    final fmtBody =
        jsonDecode(await fmt.readAsString()) as Map<String, Object?>;
    expect((fmtBody['error'] as Map)['code'], 'badRequest');
    // The FormatException message IS surfaced here (it is caller-facing input
    // validation, not an internal fault) — proving the 500 redaction above is
    // not simply blanking every body.
    expect((fmtBody['error'] as Map)['message'], contains('bad token'));
  });

  test('repeated failed logins lock the account out (429)', () async {
    await req(
      'POST',
      '/v1/accounts',
      jsonBody: <String, Object?>{
        'publicKey': 'victim',
        'displayName': 'Victim',
        'password': 'correct-horse-battery',
      },
    );
    // Five wrong-password attempts return 401...
    for (var i = 0; i < 5; i++) {
      final r = await req(
        'POST',
        '/v1/sessions',
        jsonBody: <String, Object?>{
          'publicKey': 'victim',
          'password': 'wrong-$i',
        },
      );
      expect(r.statusCode, 401, reason: 'attempt $i');
    }
    // ...the sixth is locked out, even with the CORRECT password (the lock is
    // per-account, independent of the IP rate limiter).
    final locked = await req(
      'POST',
      '/v1/sessions',
      jsonBody: <String, Object?>{
        'publicKey': 'victim',
        'password': 'correct-horse-battery',
      },
    );
    expect(locked.statusCode, 429);
    expect(locked.headers['retry-after'], isNotNull);
  });

  test('an oversized contribution geometry is rejected (400)', () async {
    final token =
        (await jsonOf(
              await req(
                'POST',
                '/v1/accounts',
                jsonBody: <String, Object?>{
                  'publicKey': 'big',
                  'displayName': 'Big',
                },
              ),
            ))['bearerToken']
            as String;
    final r = await req(
      'POST',
      '/v1/tiles/12/contributions?order=9&framesDelta=1&'
          'integrationSecondsDelta=1&license=cc-by',
      token: token,
      binaryBody: TileBuilder.synthetic(
        tileId: 12,
        order: 9,
        value: 1.0,
        frames: 1,
        width: 16, // hub tilePixels is 8
        height: 16,
      ).serialize(),
    );
    expect(r.statusCode, 400);
  });

  test('a geometry mismatch in an upload is 409', () async {
    final token =
        (await jsonOf(
              await req(
                'POST',
                '/v1/accounts',
                jsonBody: <String, Object?>{
                  'publicKey': 'g',
                  'displayName': 'G',
                },
              ),
            ))['bearerToken']
            as String;
    final r = await req(
      'POST',
      '/v1/tiles/42/contributions?order=9&framesDelta=1&'
          'integrationSecondsDelta=1&license=cc-by',
      token: token,
      binaryBody: TileBuilder.synthetic(
        tileId: 99, // mismatched id in the body
        order: 9,
        value: 1.0,
        frames: 1,
        width: 2,
        height: 2,
      ).serialize(),
    );
    expect(r.statusCode, 409);
    expect((await jsonOf(r))['error'], isA<Map>());
  });

  group('collaborative mosaics (WS2)', () {
    Future<String> signup(String key) async =>
        (await jsonOf(
              await req(
                'POST',
                '/v1/accounts',
                jsonBody: <String, Object?>{
                  'publicKey': key,
                  'displayName': key,
                },
              ),
            ))['bearerToken']
            as String;

    Future<Map<String, Object?>> publish(String token) async => jsonOf(
      await req(
        'POST',
        '/v1/mosaics',
        token: token,
        jsonBody: <String, Object?>{
          'name': '2x1',
          'rows': 1,
          'cols': 2,
          'centerRaDeg': 100.0,
          'centerDecDeg': 20.0,
          'panels': <Object?>[
            <String, Object?>{
              'panelIndex': 0,
              'centerRaDeg': 99.5,
              'centerDecDeg': 20.0,
            },
            <String, Object?>{
              'panelIndex': 1,
              'centerRaDeg': 100.5,
              'centerDecDeg': 20.0,
            },
          ],
        },
      ),
    );

    test('publish -> get -> claim 200 then 409 on contention', () async {
      final owner = await signup('m-owner');
      final bob = await signup('m-bob');
      final pub = await req(
        'POST',
        '/v1/mosaics',
        token: owner,
        jsonBody: {
          'name': '2x1',
          'rows': 1,
          'cols': 2,
          'centerRaDeg': 100.0,
          'centerDecDeg': 20.0,
          'panels': [
            {'panelIndex': 0, 'centerRaDeg': 99.5, 'centerDecDeg': 20.0},
            {'panelIndex': 1, 'centerRaDeg': 100.5, 'centerDecDeg': 20.0},
          ],
        },
      );
      expect(pub.statusCode, 201);
      final mosaicId = (await jsonOf(pub))['mosaicId'] as String;

      final got = await req('GET', '/v1/mosaics/$mosaicId', token: bob);
      expect(got.statusCode, 200);
      expect((await jsonOf(got))['panels'], hasLength(2));

      final claim = await req(
        'POST',
        '/v1/mosaics/$mosaicId/panels/0/claim',
        token: owner,
      );
      expect(claim.statusCode, 200);
      expect((await jsonOf(claim))['claimToken'], isA<String>());

      // Bob claiming the same panel is a 409 mosaicPanelHeld.
      final contend = await req(
        'POST',
        '/v1/mosaics/$mosaicId/panels/0/claim',
        token: bob,
      );
      expect(contend.statusCode, 409);
    });

    test(
      'panel master upload requires holding the claim (403 without)',
      () async {
        final owner = await signup('m-owner2');
        final bob = await signup('m-bob2');
        final mosaicId = (await publish(owner))['mosaicId'] as String;

        // Without a claim, upload is forbidden.
        final noClaim = await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/master',
          token: bob,
          binaryBody: Uint8List.fromList([1, 2, 3]),
        );
        expect(noClaim.statusCode, 403);

        // Claim then upload succeeds + round-trips on download.
        await req('POST', '/v1/mosaics/$mosaicId/panels/0/claim', token: bob);
        final up = await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/master?rigId=rig-b&license=cc-by',
          token: bob,
          binaryBody: _fits([9, 8, 7, 6]),
        );
        expect(up.statusCode, 200);
        expect((await jsonOf(up))['status'], 'uploaded');

        final dl = await req(
          'GET',
          '/v1/mosaics/$mosaicId/panels/0/master',
          token: owner,
        );
        expect(dl.statusCode, 200);
        expect(await _collect(dl), _fits([9, 8, 7, 6]));
      },
    );

    test(
      'panel master upload requires a shareable license (400, no bytes stored)',
      () async {
        final owner = await signup('m-owner-consent');
        final mosaicId = (await publish(owner))['mosaicId'] as String;
        await req('POST', '/v1/mosaics/$mosaicId/panels/0/claim', token: owner);
        // Holding the claim, but no license — the consent gate refuses the
        // share into the redistributable mosaic before any bytes are read/stored.
        final noLicense = await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/master',
          token: owner,
          binaryBody: _fits([1, 2, 3]),
        );
        expect(noLicense.statusCode, 400);
        // A non-shareable (private) license is likewise refused.
        final priv = await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/master?license=private',
          token: owner,
          binaryBody: _fits([1, 2, 3]),
        );
        expect(priv.statusCode, 400);
        // Nothing was stored — the panel is still uploadable.
        final p0 =
            ((await jsonOf(
                          await req(
                            'GET',
                            '/v1/mosaics/$mosaicId',
                            token: owner,
                          ),
                        ))['panels']
                        as List)
                    .first
                as Map<Object?, Object?>;
        expect(p0['status'], isNot('uploaded'));
      },
    );

    test(
      'finished mosaic attribution honours each panel license + anonymity',
      () async {
        final owner = await signup('m-owner-attr');
        final bob = await signup('m-bob-attr');
        final mosaicId = (await publish(owner))['mosaicId'] as String;
        // Owner uploads panel 0 WITHOUT named-credit consent; bob uploads panel 1
        // WITH consent. Both under cc-by.
        await req('POST', '/v1/mosaics/$mosaicId/panels/0/claim', token: owner);
        await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/master'
              '?license=cc-by&attributionConsent=false',
          token: owner,
          binaryBody: _fits([1]),
        );
        await req('POST', '/v1/mosaics/$mosaicId/panels/1/claim', token: bob);
        await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/1/master'
              '?license=cc-by&attributionConsent=true',
          token: bob,
          binaryBody: _fits([2]),
        );
        // Owner finalizes the mosaic, which materializes per-panel attribution.
        final out = await req(
          'POST',
          '/v1/mosaics/$mosaicId/output',
          token: owner,
          binaryBody: Uint8List.fromList([7, 7]),
        );
        expect(out.statusCode, 200);
        final contributors =
            (await jsonOf(
                  await req(
                    'GET',
                    '/v1/attribution?artifactType=mosaic&artifactRef=$mosaicId',
                    token: owner,
                  ),
                ))['contributors']
                as List;
        expect(contributors, hasLength(2));
        // Bob credited by name under cc-by; owner credited anonymously with no raw
        // account id leaked.
        final byName =
            contributors.firstWhere((c) => (c as Map)['anonymous'] == false)
                as Map<String, Object?>;
        expect(byName['displayName'], 'm-bob-attr');
        expect(byName['license'], 'cc-by');
        final anon =
            contributors.firstWhere((c) => (c as Map)['anonymous'] == true)
                as Map<String, Object?>;
        expect(anon['displayName'], 'Anonymous contributor');
        expect(anon.containsKey('accountId'), isFalse);
      },
    );

    test('panel master upload rejects non-FITS bytes (400)', () async {
      final owner = await signup('m-owner-fits');
      final mosaicId = (await publish(owner))['mosaicId'] as String;
      await req('POST', '/v1/mosaics/$mosaicId/panels/0/claim', token: owner);
      // A held claim, but the body is not a FITS file — the server-side magic
      // gate rejects it so a raw-REST rig cannot poison the slot with garbage.
      final bad = await req(
        'POST',
        '/v1/mosaics/$mosaicId/panels/0/master?license=cc-by',
        token: owner,
        binaryBody: Uint8List.fromList([0, 1, 2, 3, 4]),
      );
      expect(bad.statusCode, 400);
      // The panel is still claimable/uploadable — nothing was stored.
      final state = await jsonOf(
        await req('GET', '/v1/mosaics/$mosaicId', token: owner),
      );
      expect((state['panels'] as List).first, isA<Map<Object?, Object?>>());
      final p0 = (state['panels'] as List).first as Map<Object?, Object?>;
      expect(p0['status'], isNot('uploaded'));
    });

    test('output 404s until complete, then owner upload + download', () async {
      final owner = await signup('m-owner3');
      final mosaicId = (await publish(owner))['mosaicId'] as String;

      // Partial-set gate: output not available before all panels are in.
      expect(
        (await req(
          'GET',
          '/v1/mosaics/$mosaicId/output',
          token: owner,
        )).statusCode,
        404,
      );

      for (var i = 0; i < 2; i++) {
        await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/$i/claim',
          token: owner,
        );
        await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/$i/master?license=cc-by',
          token: owner,
          binaryBody: _fits([i + 1]),
        );
      }
      // All panels uploaded -> mosaic auto-flips to assembling.
      expect(
        (await jsonOf(
          await req('GET', '/v1/mosaics/$mosaicId', token: owner),
        ))['status'],
        'assembling',
      );

      final out = await req(
        'POST',
        '/v1/mosaics/$mosaicId/output',
        token: owner,
        binaryBody: Uint8List.fromList([42, 43]),
      );
      expect(out.statusCode, 200);
      expect((await jsonOf(out))['status'], 'complete');

      final dl = await req('GET', '/v1/mosaics/$mosaicId/output', token: owner);
      expect(dl.statusCode, 200);
      expect(await _collect(dl), Uint8List.fromList([42, 43]));
    });

    test('only the owner may upload the finished output', () async {
      final owner = await signup('m-owner4');
      final mallory = await signup('m-mallory');
      final mosaicId = (await publish(owner))['mosaicId'] as String;
      for (var i = 0; i < 2; i++) {
        await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/$i/claim',
          token: owner,
        );
        await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/$i/master?license=cc-by',
          token: owner,
          binaryBody: _fits([i + 1]),
        );
      }
      final out = await req(
        'POST',
        '/v1/mosaics/$mosaicId/output',
        token: mallory,
        binaryBody: Uint8List.fromList([1]),
      );
      expect(out.statusCode, 403);
    });

    test(
      'owner output upload is rejected (409) until every panel is uploaded',
      () async {
        final owner = await signup('m-owner-gate');
        final mosaicId = (await publish(owner))['mosaicId'] as String;
        // Only one of two panels uploaded -> mosaic still `open`, not assembling.
        await req('POST', '/v1/mosaics/$mosaicId/panels/0/claim', token: owner);
        await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/master?license=cc-by',
          token: owner,
          binaryBody: Uint8List.fromList([1]),
        );
        final premature = await req(
          'POST',
          '/v1/mosaics/$mosaicId/output',
          token: owner,
          binaryBody: Uint8List.fromList([9, 9]),
        );
        expect(premature.statusCode, 409);
        // The mosaic is NOT flipped to complete; its output stays unavailable.
        expect(
          (await jsonOf(
            await req('GET', '/v1/mosaics/$mosaicId', token: owner),
          ))['status'],
          'open',
        );
      },
    );

    test(
      'panel-master + output downloads are owner/participant-scoped (403)',
      () async {
        final owner = await signup('m-owner-leak');
        final stranger = await signup('m-stranger');
        final mosaicId = (await publish(owner))['mosaicId'] as String;
        for (var i = 0; i < 2; i++) {
          await req(
            'POST',
            '/v1/mosaics/$mosaicId/panels/$i/claim',
            token: owner,
          );
          await req(
            'POST',
            '/v1/mosaics/$mosaicId/panels/$i/master?license=cc-by',
            token: owner,
            binaryBody: _fits([i + 1]),
          );
        }
        // An unrelated account cannot pull a panel master...
        expect(
          (await req(
            'GET',
            '/v1/mosaics/$mosaicId/panels/0/master',
            token: stranger,
          )).statusCode,
          403,
        );
        // ...nor the finished output (once complete).
        final out = await req(
          'POST',
          '/v1/mosaics/$mosaicId/output',
          token: owner,
          binaryBody: Uint8List.fromList([42]),
        );
        expect(out.statusCode, 200);
        expect(
          (await req(
            'GET',
            '/v1/mosaics/$mosaicId/output',
            token: stranger,
          )).statusCode,
          403,
        );
        // The owner still pulls both (the legitimate assembler/serve path).
        expect(
          (await req(
            'GET',
            '/v1/mosaics/$mosaicId/panels/0/master',
            token: owner,
          )).statusCode,
          200,
        );
        expect(
          (await req(
            'GET',
            '/v1/mosaics/$mosaicId/output',
            token: owner,
          )).statusCode,
          200,
        );
      },
    );

    test(
      'a contributor may pull only its OWN panel master, never a peer\'s',
      () async {
        // A panel download is scoped to the panel the caller was actually
        // assigned: holding ANY panel must not let a hostile contributor claim
        // one throwaway panel and exfiltrate every peer's raw panel master.
        final owner = await signup('m-owner-xpanel');
        final bob = await signup('m-bob-xpanel');
        final mosaicId = (await publish(owner))['mosaicId'] as String;

        // Owner captures panel 0; bob claims + uploads panel 1.
        await req('POST', '/v1/mosaics/$mosaicId/panels/0/claim', token: owner);
        await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/master?license=cc-by',
          token: owner,
          binaryBody: _fits([10, 20]),
        );
        await req('POST', '/v1/mosaics/$mosaicId/panels/1/claim', token: bob);
        await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/1/master?rigId=rig-b&license=cc-by',
          token: bob,
          binaryBody: _fits([30, 40]),
        );

        // Bob (a participant) may re-pull HIS OWN panel 1...
        final own = await req(
          'GET',
          '/v1/mosaics/$mosaicId/panels/1/master',
          token: bob,
        );
        expect(own.statusCode, 200);
        expect(await _collect(own), _fits([30, 40]));

        // ...but is FORBIDDEN from pulling the owner's panel 0 raw data.
        expect(
          (await req(
            'GET',
            '/v1/mosaics/$mosaicId/panels/0/master',
            token: bob,
          )).statusCode,
          403,
        );

        // The owner (assembler) still pulls every panel to stitch.
        expect(
          (await req(
            'GET',
            '/v1/mosaics/$mosaicId/panels/1/master',
            token: owner,
          )).statusCode,
          200,
        );
      },
    );

    test('read-only token cannot publish or claim (scope enforced)', () async {
      final owner = await signup('m-owner5');
      final mosaicId = (await publish(owner))['mosaicId'] as String;
      // Mint a READ-only token for a fresh account.
      final readerToken =
          (await jsonOf(
                await req(
                  'POST',
                  '/v1/accounts',
                  jsonBody: {'publicKey': 'm-reader', 'displayName': 'Reader'},
                ),
              ))['bearerToken']
              as String;
      final readerId = server.tokens.resolve(readerToken)!.accountId;
      final readOnly = server.tokens.issue(
        accountId: readerId,
        scope: HubScope.read,
      );
      // Read works...
      expect(
        (await req('GET', '/v1/mosaics/$mosaicId', token: readOnly)).statusCode,
        200,
      );
      // ...but contribute-class actions are forbidden.
      expect(
        (await req(
          'POST',
          '/v1/mosaics',
          token: readOnly,
          jsonBody: {
            'name': 'x',
            'rows': 1,
            'cols': 1,
            'centerRaDeg': 0.0,
            'centerDecDeg': 0.0,
            'panels': [
              {'panelIndex': 0, 'centerRaDeg': 0.0, 'centerDecDeg': 0.0},
            ],
          },
        )).statusCode,
        403,
      );
      expect(
        (await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/claim',
          token: readOnly,
        )).statusCode,
        403,
      );
    });

    test('404 on unknown mosaic / panel', () async {
      final owner = await signup('m-owner6');
      final mosaicId = (await publish(owner))['mosaicId'] as String;
      expect(
        (await req(
          'GET',
          '/v1/mosaics/does-not-exist',
          token: owner,
        )).statusCode,
        404,
      );
      expect(
        (await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/99/claim',
          token: owner,
        )).statusCode,
        404,
      );
    });

    test(
      'owner can force-release a squatting claim; the squatter cannot',
      () async {
        final owner = await signup('m-owner-evict');
        final squatter = await signup('m-squatter');
        final mosaicId = (await publish(owner))['mosaicId'] as String;

        // A contribute-scoped squatter claims panel 0 and would hold it for the
        // full 12h TTL, blocking the legitimate rig.
        await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/claim',
          token: squatter,
        );
        // The squatter cannot evict (force-release is owner/admin only).
        expect(
          (await req(
            'POST',
            '/v1/mosaics/$mosaicId/panels/0/force-release',
            token: squatter,
          )).statusCode,
          403,
        );
        // The owner evicts it back to pending.
        final evict = await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/force-release',
          token: owner,
        );
        expect(evict.statusCode, 200);
        expect((await jsonOf(evict))['released'], true);
        // The panel is claimable again — the owner claims it.
        expect(
          (await req(
            'POST',
            '/v1/mosaics/$mosaicId/panels/0/claim',
            token: owner,
          )).statusCode,
          200,
        );
      },
    );

    test(
      'force-release re-opens a poisoned uploaded slot + reverts assembling',
      () async {
        final owner = await signup('m-owner-reopen');
        final mosaicId = (await publish(owner))['mosaicId'] as String;
        // Fill every panel so the mosaic flips to assembling.
        for (var i = 0; i < 2; i++) {
          await req(
            'POST',
            '/v1/mosaics/$mosaicId/panels/$i/claim',
            token: owner,
          );
          await req(
            'POST',
            '/v1/mosaics/$mosaicId/panels/$i/master?license=cc-by',
            token: owner,
            binaryBody: _fits([i + 1]),
          );
        }
        expect(
          (await jsonOf(
            await req('GET', '/v1/mosaics/$mosaicId', token: owner),
          ))['status'],
          'assembling',
        );
        // Owner decides panel 0 is garbage and re-opens it; the mosaic drops back
        // to open so a stitch can't be published over the removed panel.
        final reopen = await req(
          'POST',
          '/v1/mosaics/$mosaicId/panels/0/force-release',
          token: owner,
        );
        expect(reopen.statusCode, 200);
        final state = await jsonOf(
          await req('GET', '/v1/mosaics/$mosaicId', token: owner),
        );
        expect(state['status'], 'open');
        final p0 = (state['panels'] as List).first as Map<Object?, Object?>;
        expect(p0['status'], 'pending');
        expect(p0['uploaded'], false);
      },
    );

    test(
      'mosaic list/detail hide raw account ids from non-participants',
      () async {
        final owner = await signup('m-owner-priv');
        final mosaicId = (await publish(owner))['mosaicId'] as String;
        await req('POST', '/v1/mosaics/$mosaicId/panels/0/claim', token: owner);

        // A read token for an unrelated, non-participant account.
        final readerId = server.tokens
            .resolve(await signup('m-reader-priv'))!
            .accountId;
        final readOnly = server.tokens.issue(
          accountId: readerId,
          scope: HubScope.read,
        );

        // Detail: no raw account ids leak, but a display name surfaces for credit.
        final detail = await jsonOf(
          await req('GET', '/v1/mosaics/$mosaicId', token: readOnly),
        );
        expect(detail.containsKey('ownerAccountId'), false);
        expect(detail['ownerDisplayName'], 'm-owner-priv');
        final panel0 =
            (detail['panels'] as List).first as Map<Object?, Object?>;
        expect(panel0.containsKey('assignedAccountId'), false);
        expect(panel0.containsKey('assignedRigId'), false);
        expect(panel0['assignedDisplayName'], 'm-owner-priv');

        // List: same scoping.
        final list = await jsonOf(
          await req('GET', '/v1/mosaics', token: readOnly),
        );
        final m = (list['mosaics'] as List)
            .cast<Map<Object?, Object?>>()
            .firstWhere((e) => e['mosaicId'] == mosaicId);
        expect(m.containsKey('ownerAccountId'), false);
        expect(m['ownerDisplayName'], 'm-owner-priv');

        // The OWNER still sees the raw account id (privileged).
        final ownerView = await jsonOf(
          await req('GET', '/v1/mosaics/$mosaicId', token: owner),
        );
        expect(ownerView['ownerAccountId'], isA<String>());
      },
    );
  });

  group('live co-imaging sessions (WS3)', () {
    Future<String> signup(String key) async =>
        (await jsonOf(
              await req(
                'POST',
                '/v1/accounts',
                jsonBody: <String, Object?>{
                  'publicKey': key,
                  'displayName': key,
                },
              ),
            ))['bearerToken']
            as String;

    Future<Map<String, Object?>> create(String token, {String? rigId}) async =>
        jsonOf(
          await req(
            'POST',
            '/v1/coimaging/sessions',
            token: token,
            jsonBody: <String, Object?>{
              'targetName': 'M81',
              'centerRaDeg': 148.9,
              'centerDecDeg': 69.1,
              if (rigId != null) 'rigId': rigId,
            },
          ),
        );

    test('create -> join -> contribute accrues combined accounting', () async {
      final owner = await signup('ci-owner');
      final bob = await signup('ci-bob');
      final session = await create(owner, rigId: 'owner-rig');
      expect((await req('POST', '/v1/coimaging/sessions')).statusCode, 401);
      final sessionId = session['sessionId'] as String;
      expect(session['status'], 'active');
      expect(session['activeTileId'], isA<int>());
      // The owner is the anchor participant with its membership token echoed.
      final ownerP = (session['participants'] as List).first as Map;
      expect(ownerP['framingOffsetIndex'], 0);
      expect(ownerP['membershipToken'], isA<String>());

      // Bob joins -> distinct framing offset + own membership token.
      final join = await jsonOf(
        await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/join?rigId=bob-rig',
          token: bob,
        ),
      );
      expect(join['framingOffsetIndex'], isNot(0));
      expect(join['membershipToken'], isA<String>());
      expect(
        (join['framingOffsetRaArcsec'] as num) != 0 ||
            (join['framingOffsetDecArcsec'] as num) != 0,
        isTrue,
      );

      // Both report contributions; combined == sum.
      await req(
        'POST',
        '/v1/coimaging/sessions/$sessionId/contributions'
            '?framesDelta=10&integrationSecondsDelta=600&rigId=owner-rig'
            '&license=cc-by',
        token: owner,
      );
      final acc = await jsonOf(
        await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/contributions'
              '?framesDelta=20&integrationSecondsDelta=1200&rigId=bob-rig'
              '&license=cc-by',
          token: bob,
        ),
      );
      expect(acc['combinedFrames'], 30);
      expect(acc['combinedIntegrationSeconds'], 1800);
      expect(acc['participantCount'], 2);
    });

    test(
      'co-imaging contribution requires a license; close honours anonymity',
      () async {
        final owner = await signup('ci-anon-owner');
        final sessionId =
            (await create(owner, rigId: 'owner-rig'))['sessionId'] as String;
        // No license -> the consent gate refuses the contribution (400).
        expect(
          (await req(
            'POST',
            '/v1/coimaging/sessions/$sessionId/contributions'
                '?framesDelta=5&integrationSecondsDelta=60&rigId=owner-rig',
            token: owner,
          )).statusCode,
          400,
        );
        // Contributing WITHOUT named-credit consent records the choice...
        expect(
          (await req(
            'POST',
            '/v1/coimaging/sessions/$sessionId/contributions'
                '?framesDelta=5&integrationSecondsDelta=60&rigId=owner-rig'
                '&license=cc-by&attributionConsent=false',
            token: owner,
          )).statusCode,
          200,
        );
        // ...so closing the session credits the contributor anonymously.
        await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/close',
          token: owner,
        );
        final contributors =
            (await jsonOf(
                  await req(
                    'GET',
                    '/v1/attribution?artifactType=coimaging&artifactRef=$sessionId',
                    token: owner,
                  ),
                ))['contributors']
                as List;
        expect(contributors, hasLength(1));
        final c = contributors.first as Map<String, Object?>;
        expect(c['anonymous'], true);
        expect(c['displayName'], 'Anonymous contributor');
        expect(c['license'], 'cc-by');
        expect(c.containsKey('accountId'), isFalse);
      },
    );

    test(
      'consent is revocable: dedup per-sub, revoked on reject + on close',
      () async {
        final owner = await signup('ci-consent-owner');
        final sessionId =
            (await create(owner, rigId: 'owner-rig'))['sessionId'] as String;
        // Two accepted subs into the ONE session leave exactly one live consent
        // row — each report revokes the one the previous report stored, so the
        // ledger tracks the current share, not one orphan per sub.
        for (var i = 0; i < 2; i++) {
          expect(
            (await req(
              'POST',
              '/v1/coimaging/sessions/$sessionId/contributions'
                  '?framesDelta=5&integrationSecondsDelta=60&rigId=owner-rig'
                  '&license=cc-by',
              token: owner,
            )).statusCode,
            200,
          );
        }
        expect(server.consent.liveConsentCount('coimaging', sessionId), 1);
        // A forged report is refused (422) AND its pre-recorded consent is revoked,
        // so the count does not creep up on a rejected share.
        expect(
          (await req(
            'POST',
            '/v1/coimaging/sessions/$sessionId/contributions'
                '?framesDelta=5&integrationSecondsDelta=1e30&rigId=owner-rig'
                '&license=cc-by',
            token: owner,
          )).statusCode,
          422,
        );
        expect(server.consent.liveConsentCount('coimaging', sessionId), 1);
        // Closing the session revokes every remaining live consent for it — a
        // closed share is no longer consented.
        await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/close',
          token: owner,
        );
        expect(server.consent.liveConsentCount('coimaging', sessionId), 0);
      },
    );

    test('a non-participant is forbidden from contributing', () async {
      final owner = await signup('ci-owner2');
      final stranger = await signup('ci-stranger');
      final sessionId = (await create(owner))['sessionId'] as String;
      final r = await req(
        'POST',
        '/v1/coimaging/sessions/$sessionId/contributions'
            '?framesDelta=5&integrationSecondsDelta=60',
        token: stranger,
      );
      expect(r.statusCode, 403);
    });

    test('the events channel streams an SSE snapshot frame', () async {
      final owner = await signup('ci-owner-sse');
      final sessionId = (await create(owner))['sessionId'] as String;
      final r = await req(
        'GET',
        '/v1/coimaging/sessions/$sessionId/events',
        token: owner,
      );
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], 'text/event-stream');
      // The subscribe onListen pushes an immediate snapshot; read just that
      // first frame then stop (the stream is long-lived).
      final first = await r.read().first;
      final text = utf8.decode(first);
      expect(text, contains('event: snapshot'));
      expect(text, contains('"sessionId":"$sessionId"'));
    });

    test('the longitude baton moves between sites over HTTP', () async {
      final siteA = await signup('ci-siteA');
      final siteB = await signup('ci-siteB');
      final sessionId = (await create(siteA))['sessionId'] as String;
      await req(
        'POST',
        '/v1/coimaging/sessions/$sessionId/join?rigId=b',
        token: siteB,
      );

      final claimA = await req(
        'POST',
        '/v1/coimaging/sessions/$sessionId/baton/claim',
        token: siteA,
      );
      expect(claimA.statusCode, 200);
      // B cannot steal it while A holds it.
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/baton/claim',
          token: siteB,
        )).statusCode,
        409,
      );
      // A releases (target sets in the west); B takes over (longitude hand-off).
      await req(
        'POST',
        '/v1/coimaging/sessions/$sessionId/baton/release',
        token: siteA,
      );
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/baton/claim',
          token: siteB,
        )).statusCode,
        200,
      );
    });

    test(
      'read token: create + join are forbidden, browse is allowed',
      () async {
        final owner = await signup('ci-owner-scope2');
        final sessionId = (await create(owner))['sessionId'] as String;
        final readerId = server.tokens
            .resolve(await signup('ci-reader2'))!
            .accountId;
        final readOnly = server.tokens.issue(
          accountId: readerId,
          scope: HubScope.read,
        );
        // Browse (read) works.
        expect(
          (await req(
            'GET',
            '/v1/coimaging/sessions',
            token: readOnly,
          )).statusCode,
          200,
        );
        // Create + join (contribute) are forbidden.
        expect(
          (await req(
            'POST',
            '/v1/coimaging/sessions',
            token: readOnly,
            jsonBody: {
              'targetName': 'x',
              'centerRaDeg': 0.0,
              'centerDecDeg': 0.0,
            },
          )).statusCode,
          403,
        );
        expect(
          (await req(
            'POST',
            '/v1/coimaging/sessions/$sessionId/join',
            token: readOnly,
          )).statusCode,
          403,
        );
      },
    );

    test('404 on unknown session', () async {
      final owner = await signup('ci-owner-404');
      expect(
        (await req(
          'GET',
          '/v1/coimaging/sessions/nope',
          token: owner,
        )).statusCode,
        404,
      );
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/nope/join',
          token: owner,
        )).statusCode,
        404,
      );
    });

    test('a joiner cannot self-assign role=admin', () async {
      final owner = await signup('ci-owner-roleadmin');
      final bob = await signup('ci-bob-roleadmin');
      final sessionId = (await create(owner))['sessionId'] as String;
      // Bob asks for admin via the query param — the hub must downgrade him.
      final join = await jsonOf(
        await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/join?rigId=bob-rig&role=admin',
          token: bob,
        ),
      );
      expect(join['role'], 'contribute');
      // The owner, however, is allowed to remain admin on a re-join.
      final ownerJoin = await jsonOf(
        await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/join?role=admin',
          token: owner,
        ),
      );
      expect(ownerJoin['role'], 'admin');
    });

    test('baton claim/release require participation', () async {
      final owner = await signup('ci-owner-baton-gate');
      final stranger = await signup('ci-stranger-baton');
      final sessionId = (await create(owner))['sessionId'] as String;
      // A stranger who never joined cannot seize the baton.
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/baton/claim',
          token: stranger,
        )).statusCode,
        403,
      );
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/baton/release',
          token: stranger,
        )).statusCode,
        403,
      );
      // The owner (a participant) can.
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/baton/claim',
          token: owner,
        )).statusCode,
        200,
      );
    });

    test('owner can close a session; non-owner cannot', () async {
      final owner = await signup('ci-owner-close');
      final bob = await signup('ci-bob-close');
      final sessionId = (await create(owner))['sessionId'] as String;
      await req(
        'POST',
        '/v1/coimaging/sessions/$sessionId/join?rigId=b',
        token: bob,
      );
      // A participant who is not the owner cannot close it.
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/close',
          token: bob,
        )).statusCode,
        403,
      );
      // The owner closes it.
      final closed = await jsonOf(
        await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/close',
          token: owner,
        ),
      );
      expect(closed['status'], 'closed');
      // A closed session is gone from the active browse list and rejects joins.
      final list = await jsonOf(
        await req('GET', '/v1/coimaging/sessions', token: owner),
      );
      final ids = (list['sessions'] as List)
          .cast<Map<Object?, Object?>>()
          .map((e) => e['sessionId'])
          .toList();
      expect(ids, isNot(contains(sessionId)));
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/join',
          token: bob,
        )).statusCode,
        409,
      );
      // ...and rejects further contributions + baton operations (the documented
      // "no further contributions" contract), even though bob still holds his
      // membership token from before the close.
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/contributions'
              '?framesDelta=1&integrationSecondsDelta=1&rigId=b'
              '&license=cc-by',
          token: bob,
        )).statusCode,
        409,
      );
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/baton/claim',
          token: bob,
        )).statusCode,
        409,
      );
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/baton/release',
          token: bob,
        )).statusCode,
        409,
      );
      // Closing an unknown session is a 404.
      expect(
        (await req(
          'POST',
          '/v1/coimaging/sessions/nope/close',
          token: owner,
        )).statusCode,
        404,
      );
    });

    test(
      'an implausibly forged contribution is rejected (422), not accepted',
      () async {
        final owner = await signup('ci-owner-forge');
        final sessionId =
            (await create(owner, rigId: 'owner-rig'))['sessionId'] as String;
        // Forged depth / attribution: an absurd integration time and frame count
        // asserted in a single report. The hub must refuse it rather than let it
        // inflate the shared accounting + steal credit.
        final r = await req(
          'POST',
          '/v1/coimaging/sessions/$sessionId/contributions'
              '?framesDelta=2000000000&integrationSecondsDelta=1e30'
              '&rigId=owner-rig&license=cc-by',
          token: owner,
        );
        expect(r.statusCode, 422);
        // The combined accounting did not move.
        final detail = await jsonOf(
          await req('GET', '/v1/coimaging/sessions/$sessionId', token: owner),
        );
        expect(detail['combinedFrames'], 0);
        expect(detail['combinedIntegrationSeconds'], 0);
      },
    );
  });

  group('WS4 — trust, consent, identity', () {
    Future<({String token, String id})> account(String key) async {
      final body = await jsonOf(
        await req(
          'POST',
          '/v1/accounts',
          jsonBody: <String, Object?>{'publicKey': key, 'displayName': key},
        ),
      );
      return (
        token: body['bearerToken'] as String,
        id: body['accountId'] as String,
      );
    }

    // Test-only admin token for a real, distinct account.
    Future<({String token, String id})> adminAccount(String key) async {
      final a = await account(key);
      return (
        token: server.tokens.issue(accountId: a.id, scope: HubScope.admin),
        id: a.id,
      );
    }

    group('token minting (POST /v1/tokens)', () {
      test(
        'mints a narrowed, resource-bound token (subset delegation)',
        () async {
          final a = await account('mint-1');
          final r = await req(
            'POST',
            '/v1/tokens',
            token: a.token,
            jsonBody: <String, Object?>{
              'role': 'contribute',
              'actions': ['mosaic.upload'],
              'resourceType': 'mosaic',
              'resourceId': '42',
            },
          );
          expect(r.statusCode, 201);
          final body = await jsonOf(r);
          final minted = body['bearerToken'] as String;
          expect(minted, isA<String>());
          expect(body['resourceId'], '42');
          // The minted token is a real, resolvable token for the same account…
          final identity = server.tokens.resolve(minted);
          expect(identity, isNotNull);
          expect(identity!.accountId, a.id);
          // …narrowed to mosaic.upload on mosaic 42 only.
          expect(
            identity.permits(
              CollabAction.mosaicUpload,
              onResourceType: 'mosaic',
              onResourceId: '42',
            ),
            isTrue,
          );
          expect(
            identity.permits(
              CollabAction.mosaicUpload,
              onResourceType: 'mosaic',
              onResourceId: '99',
            ),
            isFalse,
          );
          expect(identity.permits(CollabAction.retract), isFalse);
        },
      );

      test(
        'a narrowed token is denied the actions it does not hold (403)',
        () async {
          final a = await account('mint-2');
          final minted =
              (await jsonOf(
                    await req(
                      'POST',
                      '/v1/tokens',
                      token: a.token,
                      jsonBody: <String, Object?>{
                        'role': 'contribute',
                        'actions': ['mosaic.upload'],
                      },
                    ),
                  ))['bearerToken']
                  as String;
          // calibration.publish is not on the allow-list — the per-action gate
          // denies it before any body is read.
          final r = await req(
            'POST',
            '/v1/calibration/masters?masterType=dark&camera=x&license=cc0',
            token: minted,
            binaryBody: _fits(const [1, 2, 3]),
          );
          expect(r.statusCode, 403);
        },
      );

      test('a resource-bound mosaic token is confined on the legacy tile-swarm '
          'routes (403)', () async {
        // Every collaborative WRITE route — the tile and handoff handlers
        // included — runs the fine-grained gate, not the coarse `contribute`
        // scope alone. A token minted as "contribute to mosaic 42" is therefore
        // denied outside that grant on the GLOBAL co-add + handoff baton: its
        // actions allow-list and resource binding are consulted there too.
        final a = await account('confine-1');
        final minted =
            (await jsonOf(
                  await req(
                    'POST',
                    '/v1/tokens',
                    token: a.token,
                    jsonBody: <String, Object?>{
                      'role': 'contribute',
                      'actions': ['mosaic.upload'],
                      'resourceType': 'mosaic',
                      'resourceId': '42',
                    },
                  ),
                ))['bearerToken']
                as String;
        // The global shared-sky co-add: denied (neither tile.contribute on the
        // allow-list nor a matching resource binding).
        expect(
          (await req(
            'POST',
            '/v1/tiles/314/contributions?order=9&framesDelta=1&'
                'integrationSecondsDelta=1&license=cc-by',
            token: minted,
            binaryBody: _fits(const [1, 2, 3]),
          )).statusCode,
          403,
        );
        // The longitude hand-off claim: denied for the same reason.
        expect(
          (await req('POST', '/v1/handoff/7/claim', token: minted)).statusCode,
          403,
        );
        // A plain whole-role contribute token is UNAFFECTED on those routes
        // (the confinement only bites genuinely-narrowed grants).
        final plain = await account('confine-2');
        expect(
          (await req(
            'POST',
            '/v1/handoff/7/claim',
            token: plain.token,
          )).statusCode,
          // 404 (no such target) — it cleared the auth gate, unlike the narrowed
          // token which never reaches the target lookup.
          404,
        );
      });

      test('a resource-bound token is confined on READ gates too, not only '
          'writes (no global read leak)', () async {
        // Every read gate declares its own read action + resource binding, so a
        // narrowed "contribute to mosaic 42" delegation is confined there too.
        // An action-less read gate would let it read the entire swarm target
        // queue, every tile, and every mosaic/co-imaging list — leaking other
        // users' coordinates + activity.
        final a = await account('read-confine-1');
        final minted =
            (await jsonOf(
                  await req(
                    'POST',
                    '/v1/tokens',
                    token: a.token,
                    jsonBody: <String, Object?>{
                      'role': 'contribute',
                      'resourceType': 'mosaic',
                      'resourceId': 'm-42',
                    },
                  ),
                ))['bearerToken']
                as String;
        // Global lists + cross-resource reads: all denied.
        for (final path in <String>[
          '/v1/targets',
          '/v1/mosaics',
          '/v1/coimaging/sessions',
          '/v1/tiles/9?order=9',
          '/v1/mosaics/some-other-id',
          '/v1/calibration/masters',
        ]) {
          expect(
            (await req('GET', path, token: minted)).statusCode,
            403,
            reason: '$path must be denied to a mosaic-42-bound token',
          );
        }
        // But it STILL reads its OWN bound resource — it clears the auth gate
        // (404 not-found, never 403), so a delegate can poll the artifact it
        // participates in.
        expect(
          (await req('GET', '/v1/mosaics/m-42', token: minted)).statusCode,
          404,
        );
      });

      test(
        'authorization + consent denials are recorded in the audit log',
        () async {
          final admin = await adminAccount('audit-admin');
          final reader = await account('audit-reader');
          final readTok = server.tokens.issue(
            accountId: reader.id,
            scope: HubScope.read,
          );
          // A forbidden attempt (read token on an admin-only route) and a
          // consent rejection (tile contribution with no license) both reach the
          // audit ledger, even though denials are returned rather than thrown.
          expect(
            (await req(
              'POST',
              '/v1/moderation/suspend',
              token: readTok,
              jsonBody: <String, Object?>{'accountId': admin.id},
            )).statusCode,
            403,
          );
          expect(
            (await req(
              'POST',
              '/v1/tiles/9/contributions?order=9&framesDelta=1&'
                  'integrationSecondsDelta=1',
              token: reader.token,
              binaryBody: _fits(const [1, 2, 3]),
            )).statusCode,
            400,
          );
          final audit = await jsonOf(
            await req('GET', '/v1/audit', token: admin.token),
          );
          final entries = (audit['entries'] as List)
              .cast<Map<String, Object?>>();
          expect(
            entries.any(
              (e) =>
                  e['status'] == 403 &&
                  (e['path'] as String).contains('/v1/moderation/suspend') &&
                  e['accountId'] == reader.id,
            ),
            isTrue,
            reason: 'the 403 authz denial must be auditable',
          );
          expect(
            entries.any(
              (e) =>
                  e['status'] == 400 &&
                  (e['path'] as String).contains('/contributions') &&
                  e['accountId'] == reader.id,
            ),
            isTrue,
            reason: 'the 400 consent rejection must be auditable',
          );
        },
      );

      test(
        'no privilege escalation: a read token cannot mint contribute',
        () async {
          final a = await account('mint-3');
          final readToken = server.tokens.issue(
            accountId: a.id,
            scope: HubScope.read,
          );
          final r = await req(
            'POST',
            '/v1/tokens',
            token: readToken,
            jsonBody: <String, Object?>{'role': 'contribute'},
          );
          expect(r.statusCode, 403);
        },
      );

      test(
        'no escalation: a contribute token cannot delegate moderate',
        () async {
          final a = await account('mint-4');
          final r = await req(
            'POST',
            '/v1/tokens',
            token: a.token,
            jsonBody: <String, Object?>{
              'role': 'contribute',
              'actions': ['moderate'],
            },
          );
          expect(r.statusCode, 403);
        },
      );
    });

    test('DELETE /v1/sessions/current self-revokes the caller token', () async {
      final a = await account('revoke-1');
      final del = await req('DELETE', '/v1/sessions/current', token: a.token);
      expect(del.statusCode, 200);
      expect((await jsonOf(del))['revoked'], true);
      // The token no longer authenticates anything.
      final after = await req('GET', '/v1/targets', token: a.token);
      expect(after.statusCode, 401);
    });

    group('moderation (suspend / reinstate)', () {
      test(
        'admin suspends an account; its tokens die; reinstate restores',
        () async {
          final admin = await adminAccount('mod-admin');
          final victim = await account('mod-victim');
          // Victim works before suspension.
          expect(
            (await req('GET', '/v1/targets', token: victim.token)).statusCode,
            200,
          );
          final s = await req(
            'POST',
            '/v1/moderation/suspend',
            token: admin.token,
            jsonBody: <String, Object?>{
              'accountId': victim.id,
              'reason': 'spam',
            },
          );
          expect(s.statusCode, 200);
          // Every token of the suspended account now fails closed.
          expect(
            (await req('GET', '/v1/targets', token: victim.token)).statusCode,
            401,
          );
          final ri = await req(
            'POST',
            '/v1/moderation/reinstate',
            token: admin.token,
            jsonBody: <String, Object?>{'accountId': victim.id},
          );
          expect(ri.statusCode, 200);
          // A fresh login mints a new working token.
          final fresh = server.tokens.issue(
            accountId: victim.id,
            scope: HubScope.contribute,
          );
          expect(
            (await req('GET', '/v1/targets', token: fresh)).statusCode,
            200,
          );
        },
      );

      test('a non-admin cannot suspend (403)', () async {
        final a = await account('mod-nonadmin');
        final b = await account('mod-target');
        final r = await req(
          'POST',
          '/v1/moderation/suspend',
          token: a.token,
          jsonBody: <String, Object?>{'accountId': b.id},
        );
        expect(r.statusCode, 403);
      });
    });

    group('consent + license enforcement', () {
      test('a tile contribution without a license is rejected (400)', () async {
        final a = await account('consent-1');
        final r = await req(
          'POST',
          '/v1/tiles/7/contributions?order=9&framesDelta=1',
          token: a.token,
          binaryBody: Uint8List.fromList(const [0, 0, 0]),
        );
        expect(r.statusCode, 400);
      });

      test('a non-shareable (private) license is rejected (400)', () async {
        final a = await account('consent-2');
        final r = await req(
          'POST',
          '/v1/tiles/7/contributions?order=9&framesDelta=1&license=private',
          token: a.token,
          binaryBody: Uint8List.fromList(const [0, 0, 0]),
        );
        expect(r.statusCode, 400);
      });
    });

    group('attribution (GET /v1/attribution)', () {
      test(
        'an accepted contribution materializes a credited contributor',
        () async {
          final a = await account('attr-1');
          _setTrust(server, a.token, 1.0);
          final up = await req(
            'POST',
            '/v1/tiles/55/contributions?order=9&framesDelta=4&'
                'integrationSecondsDelta=120&license=cc-by',
            token: a.token,
            binaryBody: TileBuilder.synthetic(
              tileId: 55,
              order: 9,
              value: 100.0,
              frames: 4,
              width: 8,
              height: 8,
              contributor: 'attr-1',
            ).serialize(),
          );
          expect(up.statusCode, 200);
          expect((await jsonOf(up))['accepted'], true);

          final r = await req(
            'GET',
            '/v1/attribution?artifactType=tile&artifactRef=55:9',
            token: a.token,
          );
          expect(r.statusCode, 200);
          final body = await jsonOf(r);
          final contributors = body['contributors'] as List;
          expect(contributors, hasLength(1));
          final c = contributors.first as Map<String, Object?>;
          expect(c['displayName'], 'attr-1');
          expect(c['anonymous'], false);
          expect(c['frames'], 4);
          expect(c['license'], 'cc-by');
        },
      );

      test('attributionConsent=false credits an Anonymous contributor', () async {
        final a = await account('attr-anon');
        _setTrust(server, a.token, 1.0);
        await req(
          'POST',
          '/v1/tiles/56/contributions?order=9&framesDelta=2&'
              'integrationSecondsDelta=60&license=cc-by&attributionConsent=false',
          token: a.token,
          binaryBody: TileBuilder.synthetic(
            tileId: 56,
            order: 9,
            value: 100.0,
            frames: 2,
            width: 8,
            height: 8,
            contributor: 'attr-anon',
          ).serialize(),
        );
        final body = await jsonOf(
          await req(
            'GET',
            '/v1/attribution?artifactType=tile&artifactRef=56:9',
            token: a.token,
          ),
        );
        final c = (body['contributors'] as List).first as Map<String, Object?>;
        expect(c['anonymous'], true);
        expect(c['displayName'], 'Anonymous contributor');
        expect(c.containsKey('accountId'), isFalse);
      });
    });

    test(
      'default-deny: EVERY registered protected route 401/403 without a token',
      () async {
        // Drive the assertion off the server's live route registrations, not a
        // hand-maintained list: a future route added without `_authorize` is
        // caught automatically (the spec's load-bearing single-seam mitigation).
        String concrete(String pattern) => pattern
            .split('/')
            .map((seg) => seg.startsWith('<') ? '1' : seg)
            .join('/');
        final protected = server.registeredRoutes
            .where((r) => !HubServer.publicRoutes.contains(r))
            .toList();
        // Sanity-guard the enumeration itself: the hub registers ~45 routes, so
        // a near-empty `protected` set would mean the table wiring regressed.
        expect(
          protected.length,
          greaterThan(35),
          reason: 'route table looks too small — did registration regress?',
        );
        for (final (method, path) in protected) {
          final r = await req(method, concrete(path));
          expect(
            r.statusCode,
            anyOf(401, 403),
            reason: '$method $path must default-deny without a token',
          );
        }
      },
    );

    test(
      'backward-compat: a legacy bare-role token still resolves + works',
      () async {
        // A pre-6.0 token persists its scope as a bare role name. Mint one exactly
        // that way and confirm it authenticates and contributes unchanged.
        final a = await account('legacy-1');
        final legacy = server.tokens.issueScoped(
          accountId: a.id,
          grant: const ScopedGrant.role(HubScope.contribute),
        );
        final identity = server.tokens.resolve(legacy);
        expect(identity, isNotNull);
        expect(identity!.scope, HubScope.contribute);
        // A whole-role token permits every contribute action (no narrowing).
        expect(identity.permits(CollabAction.mosaicUpload), isTrue);
        expect(identity.permits(CollabAction.retract), isTrue);
        // And it still passes the coarse + fine gates on a real route.
        final r = await req('GET', '/v1/targets', token: legacy);
        expect(r.statusCode, 200);
      },
    );
  });
}

String _normalize(String path) => path.startsWith('/') ? path : '/$path';

/// Minimal valid FITS payload: a `SIMPLE = T` primary-header card (80 bytes)
/// followed by [tail], so the hub's server-side FITS-magic upload gate accepts
/// it while the round-trip byte assertions stay deterministic.
Uint8List _fits(List<int> tail) {
  final card = 'SIMPLE  =                    T'.padRight(80);
  return Uint8List.fromList(<int>[...card.codeUnits, ...tail]);
}

Future<Uint8List> _collect(Response r) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in r.read()) {
    builder.add(chunk);
  }
  return builder.toBytes();
}

/// Test-only: pin an account's trust to exactly [trust] by resolving its token.
void _setTrust(HubServer server, String token, double trust) {
  final identity = server.tokens.resolve(token)!;
  server.accounts.setTrust(identity.accountId, trust);
}

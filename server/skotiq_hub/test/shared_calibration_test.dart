// Hub shared-calibration-library service + routes.
//
// Covers the publish quality/consent gates (shareable license, flats require an
// optical-train tag, no defect maps, sensor dimensions required + verified
// against the FITS bytes, FITS-derived frame count), the sensor-keyed query +
// license filter, owner-scoped flat reuse, authoritative provenance stamping,
// download-on-accept, owner-scoped retract, and the per-action
// `calibration.publish` grant enforcement over HTTP.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Build a 16-bit FITS primary HDU with the given image axes and optional
/// `NFRAMES`, backed by a real pixel-data section (the validator now requires the
/// declared geometry to be structurally backed by pixels).
///
///  * [withData] false → emit a header-only buffer (the undersized / header-only
///    poison the geometry gate must reject).
///  * [degenerate] true → fill the data section with a constant (all-zero) value
///    (the degenerate / poison master the pixel-sanity gate must reject); the
///    default fills a non-degenerate gradient with read-noise-like structure.
Uint8List fitsBytes({
  int width = 64,
  int height = 48,
  int? frames,
  bool withData = true,
  bool degenerate = false,
}) {
  String card(String key, String value) {
    final k = key.padRight(8);
    final v = '= ${value.padLeft(20)}';
    return '$k$v'.padRight(80);
  }

  final cards = <String>[
    card('SIMPLE', 'T'),
    card('BITPIX', '16'),
    card('NAXIS', '2'),
    card('NAXIS1', '$width'),
    card('NAXIS2', '$height'),
    if (frames != null) card('NFRAMES', '$frames'),
    'END'.padRight(80),
  ];
  final headerText = cards.join();
  // Pad the header to a whole 2880-byte block.
  const block = 2880;
  final header = Uint8List.fromList(
    headerText
        .padRight(((headerText.length + block - 1) ~/ block) * block)
        .codeUnits,
  );
  if (!withData) return header;

  final pixelCount = width * height;
  final dataLen = pixelCount * 2; // BITPIX 16 → 2 bytes/pixel
  final paddedDataLen = ((dataLen + block - 1) ~/ block) * block;
  final out = Uint8List(header.length + paddedDataLen)
    ..setRange(0, header.length, header);
  final view = ByteData.sublistView(out, header.length);
  for (var i = 0; i < pixelCount; i++) {
    final value = degenerate ? 0 : ((i * 7 + (i ~/ width) * 13) % 4000) + 100;
    view.setInt16(i * 2, value, Endian.big);
  }
  return out;
}

void main() {
  late Directory tmp;
  late HubServer server;
  late Handler handler;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nshub_cal_');
    server = HubServer(
      HubConfig(
        databasePath: ':memory:',
        atlasRoot: '${tmp.path}/atlas',
        serverSecret: 'test-secret',
        openSignup: true,
      ),
    );
    handler = server.handler;
  });

  tearDown(() {
    server.dispose();
    tmp.deleteSync(recursive: true);
  });

  String signup(String key) =>
      server.accounts.signup(publicKey: key, displayName: key).account.id;

  final fits = fitsBytes();

  group('SharedCalibrationService publish gates', () {
    test('rejects a non-shareable (private) license', () {
      final acct = signup('imager');
      expect(
        () => server.calibration.publish(
          accountId: acct,
          masterType: 'dark',
          cameraModel: 'ASI2600MM',
          license: 'private',
          bytes: fits,
          sensorWidth: 64,
          sensorHeight: 48,
        ),
        throwsA(isA<CalibrationPublishRejected>()),
      );
    });

    test('rejects an unknown master type', () {
      final acct = signup('imager');
      expect(
        () => server.calibration.publish(
          accountId: acct,
          masterType: 'defectMap',
          cameraModel: 'ASI2600MM',
          license: 'cc-by',
          bytes: fits,
          sensorWidth: 64,
          sensorHeight: 48,
        ),
        throwsA(isA<CalibrationPublishRejected>()),
      );
    });

    test('rejects a flat with no optical-train tag', () {
      final acct = signup('imager');
      expect(
        () => server.calibration.publish(
          accountId: acct,
          masterType: 'flat',
          cameraModel: 'ASI2600MM',
          license: 'cc-by',
          filter: 'L',
          bytes: fits,
          sensorWidth: 64,
          sensorHeight: 48,
        ),
        throwsA(isA<CalibrationPublishRejected>()),
      );
    });

    test('rejects a master with omitted (zero) sensor dimensions', () {
      final acct = signup('imager');
      expect(
        () => server.calibration.publish(
          accountId: acct,
          masterType: 'dark',
          cameraModel: 'ASI2600MM',
          license: 'cc-by',
          bytes: fits,
          // sensorWidth/sensorHeight default to 0
        ),
        throwsA(
          isA<CalibrationPublishRejected>().having(
            (e) => e.code,
            'code',
            'missingDimensions',
          ),
        ),
      );
    });

    test('rejects bytes that are not a FITS image', () {
      final acct = signup('imager');
      expect(
        () => server.calibration.publish(
          accountId: acct,
          masterType: 'dark',
          cameraModel: 'ASI2600MM',
          license: 'cc-by',
          bytes: Uint8List.fromList(List<int>.generate(2880, (i) => i % 256)),
          sensorWidth: 64,
          sensorHeight: 48,
        ),
        throwsA(isA<CalibrationPublishRejected>()),
      );
    });

    test('rejects declared dimensions that do not match the FITS axes', () {
      final acct = signup('imager');
      expect(
        () => server.calibration.publish(
          accountId: acct,
          masterType: 'dark',
          cameraModel: 'ASI2600MM',
          license: 'cc-by',
          bytes: fitsBytes(width: 64, height: 48),
          sensorWidth: 9576, // lie: claim a different sensor geometry
          sensorHeight: 6388,
        ),
        throwsA(
          isA<CalibrationPublishRejected>().having(
            (e) => e.code,
            'code',
            'dimensionMismatch',
          ),
        ),
      );
    });

    test('derives the authoritative frame count from the FITS NFRAMES', () {
      final acct = signup('imager');
      final row = server.calibration.publish(
        accountId: acct,
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        gain: 100,
        offset: 50,
        exposureSeconds: 300,
        // The client asserts an inflated frame count to rank first…
        frameCount: 999999,
        // …but the master FITS only records 40 combined frames.
        bytes: fitsBytes(frames: 40),
        sensorWidth: 64,
        sensorHeight: 48,
      );
      expect(
        row.frameCount,
        40,
        reason: 'frame count comes from the FITS, not the client param',
      );
    });

    test('rejects a header-only buffer with no pixel data', () {
      final acct = signup('imager');
      // A ~3 KB header-only file declaring a victim sensor's exact geometry: the
      // cheapest poison. The geometry gate is only meaningful because the bytes
      // must be backed by a real pixel-data section.
      expect(
        () => server.calibration.publish(
          accountId: acct,
          masterType: 'dark',
          cameraModel: 'ASI2600MM',
          license: 'cc-by',
          bytes: fitsBytes(withData: false),
          sensorWidth: 64,
          sensorHeight: 48,
        ),
        throwsA(
          isA<CalibrationPublishRejected>().having(
            (e) => e.code,
            'code',
            'truncatedData',
          ),
        ),
      );
    });

    test('rejects a degenerate all-zero (constant) master', () {
      final acct = signup('imager');
      // Geometry + data length both check out, but the pixels carry no signal —
      // the statistical sanity gate must still refuse it.
      expect(
        () => server.calibration.publish(
          accountId: acct,
          masterType: 'dark',
          cameraModel: 'ASI2600MM',
          license: 'cc-by',
          bytes: fitsBytes(degenerate: true),
          sensorWidth: 64,
          sensorHeight: 48,
        ),
        throwsA(
          isA<CalibrationPublishRejected>().having(
            (e) => e.code,
            'code',
            'degenerateMaster',
          ),
        ),
      );
    });

    test('accepts a flat WITH an optical-train tag', () {
      final acct = signup('imager');
      final row = server.calibration.publish(
        accountId: acct,
        masterType: 'flat',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        filter: 'L',
        opticalTrain: 'trainA',
        bytes: fits,
        sensorWidth: 64,
        sensorHeight: 48,
      );
      expect(row.opticalTrain, 'trainA');
      expect(File(row.path).existsSync(), isTrue);
    });

    test('stamps authoritative provenance over a spoofed identity', () {
      final acct = signup('imager');
      final spoofed = jsonEncode(<String, Object?>{
        'accountId': 'victim',
        'displayName': 'Famous Astrophotographer',
        'frameCount': 50,
        'darkCurrent': 0.02,
      });
      final row = server.calibration.publish(
        accountId: acct,
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        gain: 100,
        offset: 50,
        exposureSeconds: 300,
        frameCount: 50,
        provenanceJson: spoofed,
        bytes: fits,
        sensorWidth: 64,
        sensorHeight: 48,
      );
      expect(row.accountId, acct, reason: 'the authoritative producer column');
      final prov = jsonDecode(row.provenanceJson) as Map<String, Object?>;
      expect(prov['accountId'], acct, reason: 'forged identity overwritten');
      expect(
        prov['displayName'],
        'imager',
        reason: 'authoritative display name',
      );
      expect(
        prov['frameCount'],
        50,
        reason: 'non-identity provenance preserved',
      );
    });
  });

  group('SharedCalibrationService query', () {
    test('matches the sensor-keyed tuple and excludes private masters', () {
      final acct = signup('imager');
      server.calibration.publish(
        accountId: acct,
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        gain: 100,
        offset: 50,
        exposureSeconds: 300,
        bytes: fitsBytes(frames: 40),
        sensorWidth: 64,
        sensorHeight: 48,
      );
      // A deeper master of the same tuple should rank first.
      server.calibration.publish(
        accountId: acct,
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        gain: 100,
        offset: 50,
        exposureSeconds: 300,
        bytes: fitsBytes(frames: 80),
        sensorWidth: 64,
        sensorHeight: 48,
      );
      // A different gain must not match.
      server.calibration.publish(
        accountId: acct,
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        gain: 200,
        offset: 50,
        exposureSeconds: 300,
        bytes: fitsBytes(frames: 100),
        sensorWidth: 64,
        sensorHeight: 48,
      );

      final matches = server.calibration.query(
        cameraModel: 'ASI2600MM',
        gain: 100,
        offset: 50,
        binX: 1,
        binY: 1,
      );
      expect(matches, hasLength(2));
      expect(
        matches.first.frameCount,
        80,
        reason: 'ranked by provenance strength (frame count) first',
      );
    });

    test('a forged inflated frame count cannot float a master to the top', () {
      final acct = signup('imager');
      // An attacker publishes first, declaring NFRAMES=999999 to grab the #1
      // slot. (Header text is forgeable, so the FITS-derived count is itself an
      // untrusted hint.)
      server.calibration.publish(
        accountId: acct,
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        gain: 100,
        offset: 50,
        exposureSeconds: 300,
        bytes: fitsBytes(frames: 999999),
        sensorWidth: 64,
        sensorHeight: 48,
      );
      // A genuinely well-supported master (frame count at/above the rank cap)
      // published later. The cap clamps both to the same top bucket, so recency
      // breaks the tie — the legit, newer master ranks first despite a far
      // smaller declared frame count.
      final legit = server.calibration.publish(
        accountId: acct,
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        gain: 100,
        offset: 50,
        exposureSeconds: 300,
        bytes: fitsBytes(frames: 300),
        sensorWidth: 64,
        sensorHeight: 48,
      );

      final matches = server.calibration.query(
        cameraModel: 'ASI2600MM',
        gain: 100,
        offset: 50,
        binX: 1,
        binY: 1,
      );
      expect(matches, hasLength(2));
      expect(
        matches.first.id,
        legit.id,
        reason: 'a forged 999999 cannot outrank a capped legitimate master',
      );
    });

    test('a different camera does not match', () {
      final acct = signup('imager');
      server.calibration.publish(
        accountId: acct,
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        gain: 100,
        offset: 50,
        bytes: fits,
        sensorWidth: 64,
        sensorHeight: 48,
      );
      final matches = server.calibration.query(
        cameraModel: 'ASI6200MM',
        gain: 100,
        offset: 50,
      );
      expect(matches, isEmpty);
    });

    test('flats are scoped to the requesting owner (no cross-train reuse)', () {
      final alice = signup('alice');
      final bob = signup('bob');
      // Both label their train with the SAME default string — a name collision.
      server.calibration.publish(
        accountId: alice,
        masterType: 'flat',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        filter: 'L',
        opticalTrain: 'Main',
        bytes: fits,
        sensorWidth: 64,
        sensorHeight: 48,
      );

      // Bob must NOT see Alice's flat even though the train name matches.
      final asBob = server.calibration.query(
        masterType: 'flat',
        cameraModel: 'ASI2600MM',
        requesterAccountId: bob,
      );
      expect(asBob, isEmpty, reason: 'a flat never crosses accounts');

      // Alice sees her own flat.
      final asAlice = server.calibration.query(
        masterType: 'flat',
        cameraModel: 'ASI2600MM',
        requesterAccountId: alice,
      );
      expect(asAlice, hasLength(1));

      // An anonymous (unknown-requester) query excludes flats entirely.
      final anon = server.calibration.query(
        masterType: 'flat',
        cameraModel: 'ASI2600MM',
      );
      expect(anon, isEmpty);
    });
  });

  group('SharedCalibrationService retract', () {
    test('only the owner may retract', () {
      final owner = signup('owner');
      final other = signup('other');
      final row = server.calibration.publish(
        accountId: owner,
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: 'cc-by',
        bytes: fits,
        sensorWidth: 64,
        sensorHeight: 48,
      );
      expect(
        () => server.calibration.delete(row.id, requesterId: other),
        throwsA(isA<CalibrationMasterForbidden>()),
      );
      server.calibration.delete(row.id, requesterId: owner);
      expect(server.calibration.get(row.id), isNull);
      expect(File(row.path).existsSync(), isFalse);
    });
  });

  group('HTTP routes', () {
    Future<Response> send(
      String method,
      String path, {
      String? token,
      Uint8List? body,
      Map<String, String> extraHeaders = const {},
    }) {
      final headers = <String, String>{
        if (token != null) 'authorization': 'Bearer $token',
        ...extraHeaders,
      };
      return Future.value(
        handler(
          Request(
            method,
            Uri.parse('http://localhost$path'),
            headers: headers,
            body: body,
          ),
        ),
      );
    }

    test('publish → query → download round-trip', () async {
      final reg = server.accounts.signup(
        publicKey: 'imager',
        displayName: 'Imager',
      );
      final token = reg.bearerToken;
      final pub = await send(
        'POST',
        '/v1/calibration/masters?masterType=dark&camera=ASI2600MM&license=cc-by'
            '&gain=100&offset=50&exposureSeconds=300&binX=1&binY=1'
            '&sensorWidth=64&sensorHeight=48',
        token: token,
        body: fitsBytes(frames: 42),
        extraHeaders: {
          'x-provenance-json': jsonEncode(<String, Object?>{
            'darkCurrent': 0.03,
          }),
        },
      );
      expect(pub.statusCode, 201);
      final pubBody =
          jsonDecode(await pub.readAsString()) as Map<String, Object?>;
      final id = pubBody['id'] as String;
      expect(pubBody['license'], 'cc-by');

      final q = await send(
        'GET',
        '/v1/calibration/masters?camera=ASI2600MM&gain=100&offset=50'
            '&binX=1&binY=1',
        token: token,
      );
      expect(q.statusCode, 200);
      final qBody = jsonDecode(await q.readAsString()) as Map<String, Object?>;
      final masters = qBody['masters'] as List;
      expect(masters, hasLength(1));
      expect((masters.first as Map)['frameCount'], 42);

      final dl = await send(
        'GET',
        '/v1/calibration/masters/$id/file',
        token: token,
      );
      expect(dl.statusCode, 200);
      final bytes = await dl.read().expand((c) => c).toList();
      expect(bytes, fitsBytes(frames: 42).toList());

      // The download carries the AUTHORITATIVE matching tuple, so the puller
      // files the bytes under what the hub stores rather than under whatever
      // metadata its own caller handed it. A master filed under the wrong tuple
      // is worse than no shared master: the matcher would subtract it from
      // lights it was never shot for.
      final meta =
          jsonDecode(utf8.decode(base64.decode(dl.headers['x-master-meta']!)))
              as Map<String, Object?>;
      expect(meta['id'], id);
      expect(meta['masterType'], 'dark');
      expect(meta['cameraModel'], 'ASI2600MM');
      expect(meta['gain'], 100);
      expect(meta['offset'], 50);
      expect(meta['binX'], 1);
      expect(meta['binY'], 1);
      expect(meta['frameCount'], 42);
      expect(meta['license'], 'cc-by');
    });

    test('a non-owner download of a foreign flat is denied (404)', () async {
      final alice = server.accounts.signup(
        publicKey: 'alice',
        displayName: 'Alice',
      );
      // Alice publishes a flat (optical-train scoped, owner-only reusable).
      final pub = await send(
        'POST',
        '/v1/calibration/masters?masterType=flat&camera=ASI2600MM&license=cc-by'
            '&gain=100&offset=50&binX=1&binY=1&filter=L&opticalTrain=trainA'
            '&sensorWidth=64&sensorHeight=48',
        token: alice.bearerToken,
        body: fits,
      );
      expect(pub.statusCode, 201);
      final id =
          (jsonDecode(await pub.readAsString()) as Map<String, Object?>)['id']
              as String;

      // Bob holds a valid read+download token but does not own the flat. Even
      // armed with the exact id, the egress check refuses him 404 (not an
      // existence oracle) — the cross-train flat leak the design forbids.
      final bob = server.accounts.signup(publicKey: 'bob', displayName: 'Bob');
      final bobDl = await send(
        'GET',
        '/v1/calibration/masters/$id/file',
        token: bob.bearerToken,
      );
      expect(bobDl.statusCode, 404);

      // Alice (the owner) can still download her own flat.
      final aliceDl = await send(
        'GET',
        '/v1/calibration/masters/$id/file',
        token: alice.bearerToken,
      );
      expect(aliceDl.statusCode, 200);
    });

    test('a token lacking the calibration.publish action is forbidden', () async {
      final id = signup('imager');
      // A contribute-scoped token narrowed to ONLY calibration.download.
      final token = server.tokens.issueScoped(
        accountId: id,
        grant: const ScopedGrant(
          scope: HubScope.contribute,
          actions: {CollabAction.calibrationDownload},
        ),
      );
      final r = await send(
        'POST',
        '/v1/calibration/masters?masterType=dark&camera=ASI2600MM&license=cc-by'
            '&sensorWidth=64&sensorHeight=48',
        token: token,
        body: fits,
      );
      expect(r.statusCode, 403);
      // But it CAN query (download action is in the allow-list).
      final q = await send(
        'GET',
        '/v1/calibration/masters?camera=ASI2600MM&gain=100&offset=50',
        token: token,
      );
      expect(q.statusCode, 200);
    });

    test('publishing under a private license is rejected (400)', () async {
      final reg = server.accounts.signup(
        publicKey: 'imager',
        displayName: 'Imager',
      );
      final r = await send(
        'POST',
        '/v1/calibration/masters?masterType=dark&camera=ASI2600MM'
            '&license=private&sensorWidth=64&sensorHeight=48',
        token: reg.bearerToken,
        body: fits,
      );
      expect(r.statusCode, 400);
    });

    test('a content-integrity poison master returns 422 (auto-flag parity) while '
        'a benign gate stays 400', () async {
      final reg = server.accounts.signup(
        publicKey: 'imager',
        displayName: 'Imager',
      );
      // A degenerate (all-zero) buffer is structurally valid FITS but carries no
      // calibration signal — a poison master. Parity with the co-imaging
      // implausible-report path: it must be a 422 so [_auditDenialMiddleware]
      // feeds it to the abuse auto-flag, NOT a 400 that neither abuse bucket
      // counts.
      final poison = await send(
        'POST',
        '/v1/calibration/masters?masterType=dark&camera=ASI2600MM&license=cc-by'
            '&sensorWidth=64&sensorHeight=48',
        token: reg.bearerToken,
        body: fitsBytes(degenerate: true),
      );
      expect(poison.statusCode, 422);
      expect(
        ((jsonDecode(await poison.readAsString()) as Map)['error']
            as Map)['code'],
        'degenerateMaster',
      );
      // A header-only buffer spoofing the declared geometry is the cheapest
      // poison — also 422.
      final undersized = await send(
        'POST',
        '/v1/calibration/masters?masterType=dark&camera=ASI2600MM&license=cc-by'
            '&sensorWidth=64&sensorHeight=48',
        token: reg.bearerToken,
        body: fitsBytes(withData: false),
      );
      expect(undersized.statusCode, 422);
      // Declared geometry that does not match the real FITS axes — a spoof — is
      // content-integrity, so 422.
      final mismatch = await send(
        'POST',
        '/v1/calibration/masters?masterType=dark&camera=ASI2600MM&license=cc-by'
            '&sensorWidth=100&sensorHeight=48',
        token: reg.bearerToken,
        body: fits,
      );
      expect(mismatch.statusCode, 422);
      expect(
        ((jsonDecode(await mismatch.readAsString()) as Map)['error']
            as Map)['code'],
        'dimensionMismatch',
      );
      // A benign malformed request (an unsharable master type) is an honest
      // mistake and must stay a 400 so it never accrues against the auto-flag.
      final benign = await send(
        'POST',
        '/v1/calibration/masters?masterType=defect&camera=ASI2600MM'
            '&license=cc-by&sensorWidth=64&sensorHeight=48',
        token: reg.bearerToken,
        body: fits,
      );
      expect(benign.statusCode, 400);
      expect(
        ((jsonDecode(await benign.readAsString()) as Map)['error']
            as Map)['code'],
        'unsharableType',
      );
    });

    test('a poison-master flood auto-suspends the account (WS4 abuse parity with '
        'tile/co-imaging)', () async {
      final reg = server.accounts.signup(
        publicKey: 'flooder',
        displayName: 'Flooder',
      );
      // Stay under the raw rate limiter (120/min) but push past the abuse
      // threshold (25). Every 422 lands in the audit ledger and feeds
      // `checkAbuse`, so a poison-master flood auto-suspends like any other
      // abuse.
      expect(server.moderation.isSuspended(reg.account.id), isFalse);
      for (var i = 0; i < ModerationService.defaultAbuseThreshold; i++) {
        final r = await send(
          'POST',
          '/v1/calibration/masters?masterType=dark&camera=ASI2600MM'
              '&license=cc-by&sensorWidth=64&sensorHeight=48',
          token: reg.bearerToken,
          body: fitsBytes(degenerate: true),
        );
        // Each request is rejected — a 422 poison rejection until the flood
        // trips the auto-suspend, after which the account is refused outright.
        expect(r.statusCode, greaterThanOrEqualTo(400));
      }
      expect(
        server.moderation.isSuspended(reg.account.id),
        isTrue,
        reason:
            'a poison-master flood must auto-suspend, exactly like the '
            'tile-fusion and co-imaging abuse paths',
      );
    });

    test(
      'a published master records a durable consent row, revoked on retract',
      () async {
        final reg = server.accounts.signup(
          publicKey: 'imager',
          displayName: 'Imager',
        );
        final pub = await send(
          'POST',
          '/v1/calibration/masters?masterType=dark&camera=ASI2600MM&license=cc-by'
              '&gain=100&offset=50&exposureSeconds=300&binX=1&binY=1'
              '&sensorWidth=64&sensorHeight=48&allowDerivatives=true',
          token: reg.bearerToken,
          body: fits,
        );
        expect(pub.statusCode, 201);
        final id =
            (jsonDecode(await pub.readAsString()) as Map<String, Object?>)['id']
                as String;
        // Parity with the tile / mosaic / co-imaging share paths: an accepted
        // master leaves exactly one live consent record keyed to it.
        expect(
          server.consent.liveConsentCount('calibration', id),
          1,
          reason: 'a shared master must leave a durable consent record',
        );
        // Retracting the master revokes the consent — the share is gone, so its
        // recorded consent must no longer read as live.
        final del = await send(
          'DELETE',
          '/v1/calibration/masters/$id',
          token: reg.bearerToken,
        );
        expect(del.statusCode, 200);
        expect(
          server.consent.liveConsentCount('calibration', id),
          0,
          reason: 'a retracted master revokes its consent record',
        );
      },
    );
  });
}

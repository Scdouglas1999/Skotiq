// A number JSON cannot carry has to be refused by the request, not by the
// encoder inside the job.
//
// `POST /api/post-session/integrate` with `"exposuresSec":[1e400]` answered
// `200 {"jobId":…,"status":"queued"}` and then failed the job with
// "Converting object to an encodable object failed: Infinity" — the only
// refusal on this surface naming neither the field, the index, nor a next step.
// The guard written for exactly this input lives in the bridge
// (`post_session/helpers.rs`: "exposuresSec[0] is …, which is not a number of
// seconds") and could never run, because `jsonEncode` threw before the payload
// reached it.
//
// The same argument covers the list's SHAPE, which the second group pins: a
// wrong-length or negative `exposuresSec` also answered `200 {"jobId":…}` and
// only failed a `/api/jobs/{id}` poll later, for a body the request path could
// already read as malformed.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/post_session_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late ProviderContainer container;
  late JobManager jobManager;
  late PostSessionHandlers handlers;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    jobManager = JobManager(emitEvent: (_) {});
    handlers = PostSessionHandlers(container, jobManager: jobManager);
  });

  tearDown(() async {
    await jobManager.dispose();
    container.dispose();
    await database.close();
  });

  // The body is a raw JSON string, never `jsonEncode`d here: `1e400` is how a
  // client writes an overflowing literal, and Dart's own encoder cannot write
  // the `double.infinity` its decoder reads back from it. This is the byte
  // sequence curl put on the wire against the running host.
  Request post(String path, String body) => Request(
    'POST',
    Uri.parse('http://localhost$path'),
    body: body,
    headers: {'content-type': 'application/json'},
  );

  String integrateBody({String exposures = '', String settings = '{}'}) =>
      '{"runId":"x","lightPaths":["/tmp/a.fits"],'
      '${exposures.isEmpty ? '' : '"exposuresSec":$exposures,'}'
      '"calibration":{},"settings":$settings,'
      '"output":{"masterFitsPath":"/tmp/o.fits"}}';

  test('integrate names the non-finite exposure by field and index', () async {
    final response = await translateHandlerErrors(
      handlers.handleIntegrateSession(
        post(
          '/api/post-session/integrate',
          integrateBody(exposures: '[1e400]'),
        ),
      ),
    );

    expect(response.statusCode, HttpStatus.badRequest);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['field'], 'exposuresSec[0]');
    expect(body['code'], 'invalid_request');
    expect(
      body['message'],
      'exposuresSec[0] is Infinity, which is not a finite number; every '
      'numeric field must be a finite value',
    );
    expect(
      jobManager.length,
      0,
      reason: 'a refused request registers no job to poll',
    );
  });

  test('master-accumulate refuses the same input the same way', () async {
    final response = await translateHandlerErrors(
      handlers.handleMasterAccumulate(
        post(
          '/api/post-session/master-accumulate',
          '{"op":"add","masterPath":"/tmp/m.fits",'
              '"lightPaths":["/tmp/a.fits"],"exposuresSec":[-1e400],'
              '"calibration":{},"settings":{}}',
        ),
      ),
    );

    expect(response.statusCode, HttpStatus.badRequest);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['field'], 'exposuresSec[0]');
    expect(body['message'], contains('-Infinity'));
    expect(jobManager.length, 0);
  });

  test('a nested non-finite is named by its own path', () async {
    final response = await translateHandlerErrors(
      handlers.handleIntegrateSession(
        post(
          '/api/post-session/integrate',
          integrateBody(settings: '{"sigmaHigh":1e400}'),
        ),
      ),
    );

    expect(response.statusCode, HttpStatus.badRequest);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['field'], 'settings.sigmaHigh');
    expect(jobManager.length, 0);
  });

  test('analyze-night refuses a non-finite exposure too', () async {
    final response = await translateHandlerErrors(
      handlers.handleAnalyzeNight(
        post(
          '/api/post-session/analyze-night',
          '{"qualities":[1.0],"weights":[1.0],"exposuresS":[1.0,1e400]}',
        ),
      ),
    );

    expect(response.statusCode, HttpStatus.badRequest);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['field'], 'exposuresS[1]');
    expect(jobManager.length, 0);
  });

  test('a body of finite numbers still queues its job', () async {
    final response = await translateHandlerErrors(
      handlers.handleIntegrateSession(
        post('/api/post-session/integrate', integrateBody(exposures: '[60.0]')),
      ),
    );

    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['status'], 'queued');
    expect(
      jobManager.length,
      1,
      reason: 'the guard refuses only what the host itself would refuse',
    );
  });

  // The same seam, one step further out: a list the host can already see is
  // the wrong SHAPE was queued as a job, answered 200 with an id, and only
  // failed on a later `/api/jobs/{id}` poll. A job id says the request's
  // inputs were shaped right; two exposures for three lights never were.
  group('exposuresSec shape', () {
    String integrateWith(String lights, String exposures) =>
        '{"runId":"x","lightPaths":$lights,"exposuresSec":$exposures,'
        '"calibration":{},"settings":{},'
        '"output":{"masterFitsPath":"/tmp/o.fits"}}';

    test('integrate refuses a short list in the request path', () async {
      final response = await translateHandlerErrors(
        handlers.handleIntegrateSession(
          post(
            '/api/post-session/integrate',
            integrateWith(
              '["/tmp/a.fits","/tmp/b.fits","/tmp/c.fits"]',
              '[60.0,60.0]',
            ),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'exposuresSec');
      expect(body['code'], 'invalid_request');
      // Verbatim the bridge's own sentence (`post_session/helpers.rs`), so the
      // 400 and the job error cannot describe one input two ways.
      expect(
        body['message'],
        'exposuresSec has 2 entries but 3 light frames were supplied; supply '
        'one exposure per light, or omit exposuresSec entirely',
      );
      expect(jobManager.length, 0, reason: 'no run id is claimed');
    });

    test('a list longer than the lights is refused too', () async {
      final response = await translateHandlerErrors(
        handlers.handleIntegrateSession(
          post(
            '/api/post-session/integrate',
            integrateWith('["/tmp/a.fits"]', '[60.0,60.0,60.0,60.0]'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['message'], contains('4 entries but 1 light frames'));
      expect(jobManager.length, 0);
    });

    test('a negative exposure is named by index', () async {
      final response = await translateHandlerErrors(
        handlers.handleIntegrateSession(
          post(
            '/api/post-session/integrate',
            integrateWith('["/tmp/a.fits","/tmp/b.fits"]', '[60.0,-100.0]'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'exposuresSec[1]');
      expect(body['message'], contains('a negative exposure'));
      expect(
        body['message'],
        contains('every entry must be a finite value >= 0'),
      );
      expect(jobManager.length, 0);
    });

    test('master-accumulate add refuses the same shapes', () async {
      final short = await translateHandlerErrors(
        handlers.handleMasterAccumulate(
          post(
            '/api/post-session/master-accumulate',
            '{"op":"add","sidecarPath":"/tmp/m.skm",'
                '"lightPaths":["/tmp/a.fits","/tmp/b.fits"],'
                '"exposuresSec":[60.0],"calibration":{},"settings":{}}',
          ),
        ),
      );
      expect(short.statusCode, HttpStatus.badRequest);
      expect(
        (jsonDecode(await short.readAsString()) as Map)['message'],
        contains('1 entries but 2 light frames'),
      );

      final negative = await translateHandlerErrors(
        handlers.handleMasterAccumulate(
          post(
            '/api/post-session/master-accumulate',
            '{"op":"add","sidecarPath":"/tmp/m.skm",'
                '"lightPaths":["/tmp/a.fits"],"exposuresSec":[-1.0],'
                '"calibration":{},"settings":{}}',
          ),
        ),
      );
      expect(negative.statusCode, HttpStatus.badRequest);
      expect(
        (jsonDecode(await negative.readAsString()) as Map)['field'],
        'exposuresSec[0]',
      );
      expect(jobManager.length, 0);
    });

    // The bridge only reads `exposuresSec` on `add`; refusing it on an op that
    // never looks at it would be a refusal the host does not make.
    test('a non-add master-accumulate op is not second-guessed', () async {
      final response = await translateHandlerErrors(
        handlers.handleMasterAccumulate(
          post(
            '/api/post-session/master-accumulate',
            '{"op":"info","sidecarPath":"/tmp/m.skm",'
                '"lightPaths":["/tmp/a.fits","/tmp/b.fits"],'
                '"exposuresSec":[60.0],"calibration":{},"settings":{}}',
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(jobManager.length, 1);
    });

    // An omitted or empty list is the documented "no exposure metadata" shape
    // and reports every frame as 0 s — it is not a mismatch.
    test('an omitted list is still the documented shape', () async {
      final response = await translateHandlerErrors(
        handlers.handleIntegrateSession(
          post(
            '/api/post-session/integrate',
            '{"runId":"x","lightPaths":["/tmp/a.fits","/tmp/b.fits"],'
                '"calibration":{},"settings":{},'
                '"output":{"masterFitsPath":"/tmp/o.fits"}}',
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(jobManager.length, 1);
    });

    test('zero seconds is allowed, as it is on the host', () async {
      final response = await translateHandlerErrors(
        handlers.handleIntegrateSession(
          post(
            '/api/post-session/integrate',
            integrateWith('["/tmp/a.fits"]', '[0.0]'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(jobManager.length, 1);
    });
  });

  // The last hole in the same seam: a wrong-length list and a negative entry
  // were refused by the request, but a wrong-TYPED one was not. `serde` refuses
  // it while decoding the args struct — inside the bridge call, after the id
  // has been minted — so `"exposuresSec":{"a":1}` answered `200 queued` and
  // only turned out refused on a later poll, as `invalid type: map, expected a
  // sequence at line 1 column 214`. Measured against the running host on
  // 2026-08-31; the arity and value cases answered 400 in the same session.
  group('exposuresSec type', () {
    String integrateWith(String lights, String exposures) =>
        '{"runId":"x","lightPaths":$lights,"exposuresSec":$exposures,'
        '"calibration":{},"settings":{},'
        '"output":{"masterFitsPath":"/tmp/o.fits"}}';

    test('integrate refuses a map where the list belongs', () async {
      final response = await translateHandlerErrors(
        handlers.handleIntegrateSession(
          post(
            '/api/post-session/integrate',
            integrateWith('["/tmp/a.fits"]', '{"a":1}'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'exposuresSec');
      expect(body['code'], 'invalid_request');
      expect(
        body['message'],
        'exposuresSec is a JSON object, not a list of exposure seconds; '
        'supply one entry per light frame, or omit exposuresSec entirely',
      );
      expect(jobManager.length, 0, reason: 'no job id is minted');
    });

    test('an explicit null is refused, not read as omitted', () async {
      final response = await translateHandlerErrors(
        handlers.handleIntegrateSession(
          post(
            '/api/post-session/integrate',
            integrateWith('["/tmp/a.fits"]', 'null'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'exposuresSec');
      expect(body['message'], contains('exposuresSec is null, not a list'));
      expect(
        jobManager.length,
        0,
        reason:
            'the struct default fills only an ABSENT field; an explicit null '
            'is what the deserializer refuses',
      );
    });

    test('a string entry is named by its index', () async {
      final response = await translateHandlerErrors(
        handlers.handleIntegrateSession(
          post(
            '/api/post-session/integrate',
            integrateWith('["/tmp/a.fits","/tmp/b.fits"]', '[60.0,"60"]'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'exposuresSec[1]');
      expect(
        body['message'],
        'exposuresSec[1] is the string "60", which is not a number of '
        'seconds; every entry must be a finite value >= 0',
      );
      expect(jobManager.length, 0);
    });

    test('master-accumulate add refuses the same types', () async {
      final mapped = await translateHandlerErrors(
        handlers.handleMasterAccumulate(
          post(
            '/api/post-session/master-accumulate',
            '{"op":"add","sidecarPath":"/tmp/m.skm",'
                '"lightPaths":["/tmp/a.fits"],"exposuresSec":{"a":1},'
                '"calibration":{},"settings":{}}',
          ),
        ),
      );
      expect(mapped.statusCode, HttpStatus.badRequest);
      expect(
        (jsonDecode(await mapped.readAsString()) as Map)['field'],
        'exposuresSec',
      );

      final booleanEntry = await translateHandlerErrors(
        handlers.handleMasterAccumulate(
          post(
            '/api/post-session/master-accumulate',
            '{"op":"add","sidecarPath":"/tmp/m.skm",'
                '"lightPaths":["/tmp/a.fits"],"exposuresSec":[true],'
                '"calibration":{},"settings":{}}',
          ),
        ),
      );
      expect(booleanEntry.statusCode, HttpStatus.badRequest);
      expect(
        (jsonDecode(await booleanEntry.readAsString()) as Map)['message'],
        contains('exposuresSec[0] is the boolean true'),
      );
      expect(jobManager.length, 0);
    });

    // The scope stays exactly the guard's: an op that never reads the field is
    // still not second-guessed, and an empty list is still the documented
    // "no exposure metadata" shape.
    test('a non-add op carrying a mistyped list is left alone', () async {
      final response = await translateHandlerErrors(
        handlers.handleMasterAccumulate(
          post(
            '/api/post-session/master-accumulate',
            '{"op":"info","sidecarPath":"/tmp/m.skm",'
                '"lightPaths":["/tmp/a.fits"],"exposuresSec":{"a":1},'
                '"calibration":{},"settings":{}}',
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(jobManager.length, 1);
    });

    test('an empty list still queues its job', () async {
      final response = await translateHandlerErrors(
        handlers.handleIntegrateSession(
          post(
            '/api/post-session/integrate',
            integrateWith('["/tmp/a.fits"]', '[]'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(jobManager.length, 1);
    });
  });
}

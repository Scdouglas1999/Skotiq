import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

void main() {
  test(
    'random forged Bearer tokens cannot bypass per-IP rate limiting',
    () async {
      final tmp = Directory.systemTemp.createTempSync('skhub_rl_');
      final server = HubServer(
        HubConfig(
          databasePath: ':memory:',
          atlasRoot: '${tmp.path}/atlas',
          serverSecret: 'test-secret',
          openSignup: true,
          tilePixels: 8,
        ),
      );
      addTearDown(() {
        server.dispose();
        tmp.deleteSync(recursive: true);
      });

      final handler = server.handler;
      var saw429 = false;
      // The per-IP read cap is 120/min; sending 130 requests each with a
      // distinct forged Bearer token from the same IP must trip 429 rather
      // than allocating 130 fresh buckets.
      for (var i = 0; i < 130; i++) {
        final res = await handler(
          Request(
            'GET',
            Uri.parse('http://localhost/v1/info'),
            headers: {
              'authorization': 'Bearer forged-random-token-$i',
              'x-forwarded-for': '203.0.113.42',
            },
          ),
        );
        if (res.statusCode == 429) {
          saw429 = true;
          break;
        }
      }
      expect(saw429, isTrue);
      final queriesAtLimit = server.tokens.resolveQueryCount;
      for (var i = 0; i < 10; i++) {
        final res = await handler(
          Request(
            'GET',
            Uri.parse('http://localhost/v1/info'),
            headers: {'authorization': 'Bearer forged-after-limit-$i'},
          ),
        );
        expect(res.statusCode, 429);
        await res.read().drain<void>();
      }
      expect(server.tokens.resolveQueryCount, queriesAtLimit);
    },
  );

  test(
    'a known token is resolved once and survives a forged-bearer flood',
    () async {
      final tmp = Directory.systemTemp.createTempSync('skhub_rl_live_');
      final server = HubServer(
        HubConfig(
          databasePath: ':memory:',
          atlasRoot: '${tmp.path}/atlas',
          serverSecret: 'test-secret',
          openSignup: true,
          tilePixels: 8,
        ),
      );
      addTearDown(() {
        server.dispose();
        tmp.deleteSync(recursive: true);
      });
      final handler = server.handler;

      final signup = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/v1/accounts'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'publicKey': 'imager-rate',
            'displayName': 'Imager',
          }),
        ),
      );
      expect(signup.statusCode, 201);
      final token =
          (jsonDecode(await signup.readAsString())
                  as Map<String, dynamic>)['bearerToken']
              as String;

      Future<int> authedStatus() async {
        final res = await handler(
          Request(
            'GET',
            Uri.parse('http://localhost/v1/tiles/42'),
            headers: {'authorization': 'Bearer $token'},
          ),
        );
        final status = res.statusCode;
        await res.read().drain<void>();
        return status;
      }

      final first = await authedStatus();
      expect(first, isNot(429));
      final queriesAfterFirst = server.tokens.resolveQueryCount;
      expect(queriesAfterFirst, 1);

      final second = await authedStatus();
      expect(second, first);
      expect(server.tokens.resolveQueryCount, queriesAfterFirst);

      var saw429 = false;
      for (var i = 0; i < 130; i++) {
        final res = await handler(
          Request(
            'GET',
            Uri.parse('http://localhost/v1/info'),
            headers: {'authorization': 'Bearer forged-$i'},
          ),
        );
        final status = res.statusCode;
        await res.read().drain<void>();
        if (status == 429) {
          saw429 = true;
          break;
        }
      }
      expect(saw429, isTrue);
      final queriesAfterFlood = server.tokens.resolveQueryCount;

      final duringFlood = await authedStatus();
      expect(duringFlood, isNot(429));
      expect(server.tokens.resolveQueryCount, queriesAfterFlood);
    },
  );
}

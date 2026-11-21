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
    },
  );
}

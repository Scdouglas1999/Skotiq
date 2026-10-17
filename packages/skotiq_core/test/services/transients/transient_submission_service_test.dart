import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';

TransientDetectionRow _detection() => TransientDetectionRow(
  id: 7,
  tileId: 42,
  detectedAt: DateTime.utc(2026, 6, 20, 6, 30, 0),
  raDeg: 187.7059,
  decDeg: 12.3911,
  residualFlux: 5000.0,
  deltaMag: null,
  snr: 18.0,
  fwhm: 2.1,
  eccentricity: 0.1,
  positionAngleDeg: 0.0,
  kind: 'newSource',
  catalogMatch: null,
  confidence: 0.8,
  reviewed: true,
  dismissed: false,
);

const _creds = TnsCredentials(
  botId: 12345,
  botName: 'SkotiqBot',
  reportingGroupId: 42,
  dataSourceId: 7,
  reporterName: 'S. Douglas',
  apiKey: 'secret-key',
  useSandbox: true,
);

void main() {
  group('TransientSubmissionService.submitToTns', () {
    test('refuses incomplete credentials without any network call', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });
      final svc = TransientSubmissionService(
        httpClient: client,
        logger: LoggingService(),
      );
      final result = await svc.submitToTns(
        detection: _detection(),
        creds: const TnsCredentials(
          botId: 0,
          botName: '',
          reportingGroupId: 0,
          dataSourceId: 0,
          reporterName: '',
          apiKey: '',
        ),
      );
      expect(result.success, isFalse);
      expect(called, isFalse);
    });

    test(
      'sends the tns_marker User-Agent + api_key, then polls for AT name',
      () async {
        String? sentUserAgent;
        String? sentApiKey;
        Map<String, dynamic>? sentData;
        var setCalls = 0;
        var replyCalls = 0;

        final client = MockClient((request) async {
          if (request.url.path.endsWith('/set/bulk-report')) {
            setCalls++;
            sentUserAgent = request.headers['User-Agent'];
            final body = Uri.splitQueryString(request.body);
            sentApiKey = body['api_key'];
            sentData = jsonDecode(body['data']!) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id_code': 200,
                'id_message': 'OK',
                'data': {'report_id': 'R999'},
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/get/bulk-report-reply')) {
            replyCalls++;
            return http.Response(
              jsonEncode({
                'id_code': 200,
                'data': {
                  'feedback': {
                    'at_report': {
                      '0': {
                        '100': {
                          'objname': 'AT2026abc',
                          'message': 'Object data uploaded',
                        },
                      },
                    },
                  },
                },
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        });

        final svc = TransientSubmissionService(
          httpClient: client,
          logger: LoggingService(),
        );
        final result = await svc.submitToTns(
          detection: _detection(),
          creds: _creds,
        );

        expect(setCalls, 1);
        expect(replyCalls, greaterThanOrEqualTo(1));
        expect(result.success, isTrue);
        expect(result.atName, 'AT2026abc');
        expect(result.reportId, 'R999');
        // Mandatory tns_marker User-Agent with the bot id + name.
        expect(sentUserAgent, contains('tns_marker'));
        expect(sentUserAgent, contains('"tns_id":12345'));
        expect(sentUserAgent, contains('"name":"SkotiqBot"'));
        // api_key in the form body, the report JSON in `data`.
        expect(sentApiKey, 'secret-key');
        expect(sentData!.containsKey('at_report'), isTrue);
      },
    );

    test('surfaces the TNS error when set/bulk-report fails', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({'id_code': 401, 'id_message': 'Unauthorized'}),
          401,
        );
      });
      final svc = TransientSubmissionService(
        httpClient: client,
        logger: LoggingService(),
      );
      final result = await svc.submitToTns(
        detection: _detection(),
        creds: _creds,
      );
      expect(result.success, isFalse);
      expect(result.message, contains('401'));
    });
  });
}

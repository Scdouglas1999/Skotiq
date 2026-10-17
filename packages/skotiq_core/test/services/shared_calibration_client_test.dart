// [SharedCalibrationClient] transport.
//
// Locks in the ASCII-safe provenance header: a Provenance whose attribution /
// notes carry non-Latin-1 characters (CJK, emoji) must be transported in a form
// dart:io's HTTP header validation accepts — a raw jsonEncode is NOT header-safe
// and dart:io throws `FormatException: Invalid HTTP header field value` on it.
// The client base64-encodes the header; the hub base64-decodes it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/models/collaboration/collaboration_models.dart';
import 'package:skotiq_core/src/services/calibration/shared_calibration_client.dart';
import 'package:skotiq_core/src/services/constellation/constellation_models.dart';

void main() {
  late Directory tmp;
  late File master;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sk_shared_cal_client_');
    master = File('${tmp.path}/master_dark.fits')
      ..writeAsBytesSync(<int>[1, 2, 3, 4, 5]);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  final asciiOnly = RegExp(r'^[A-Za-z0-9+/=]*$');

  test(
    'publishMaster transports a non-ASCII provenance as an ASCII-safe header',
    () async {
      // Display name + camera model + notes well outside Latin-1.
      const provenance = Provenance(
        displayName: '星空 撮影者 \u{1F52D}',
        cameraModel: 'ZWO ASI2600MM 望遠鏡',
        note: 'シャープな暗電流 \u{2728}',
        frameCount: 42,
        darkCurrent: 0.018,
        sensorWidth: 6248,
        sensorHeight: 4176,
      );

      http.BaseRequest? seen;
      String? provenanceHeader;
      final mock = MockClient((request) async {
        seen = request;
        provenanceHeader = request.headers['x-provenance-json'];
        return http.Response(
          jsonEncode(<String, Object?>{
            'id': 'pub-1',
            'masterType': 'dark',
            'license': 'cc-by',
            'frameCount': 42,
          }),
          201,
        );
      });

      final client = SharedCalibrationClient(
        hubBaseUrl: Uri.parse('https://hub.example.org'),
        bearerToken: 'tok',
        client: mock,
      );

      final result = await client.publishMaster(
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: ContributionLicense.ccBy,
        filePath: master.path,
        provenance: provenance,
        sensorWidth: 6248,
        sensorHeight: 4176,
        exposureSeconds: 300,
        frameCount: 42,
      );

      expect(seen, isNotNull);
      expect(result.id, 'pub-1');

      // The header value is pure ASCII (base64) — never the raw non-Latin-1 JSON
      // that dart:io would reject.
      expect(provenanceHeader, isNotNull);
      expect(asciiOnly.hasMatch(provenanceHeader!), isTrue);

      // …and it round-trips back to the original provenance JSON.
      final decoded = utf8.decode(base64.decode(provenanceHeader!));
      expect(decoded, provenance.toJsonString());
      final reparsed = Provenance.fromJsonString(decoded);
      expect(reparsed.displayName, provenance.displayName);
      expect(reparsed.cameraModel, provenance.cameraModel);
      expect(reparsed.note, provenance.note);
    },
  );

  test(
    'publishMaster rejects incomplete matching metadata before upload',
    () async {
      var requests = 0;
      final client = SharedCalibrationClient(
        hubBaseUrl: Uri.parse('https://hub.example.org'),
        bearerToken: 'tok',
        client: MockClient((request) async {
          requests++;
          return http.Response('{}', 201);
        }),
      );

      await expectLater(
        client.publishMaster(
          masterType: 'dark',
          cameraModel: '',
          license: ContributionLicense.ccBy,
          filePath: master.path,
          provenance: const Provenance(),
          exposureSeconds: 300,
        ),
        throwsA(
          isA<ConstellationException>()
              .having((e) => e.kind, 'kind', ConstellationErrorKind.protocol)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('camera model'),
                  contains('sensor dimensions'),
                  contains('frame count'),
                ),
              ),
        ),
      );
      expect(requests, 0);
    },
  );
}

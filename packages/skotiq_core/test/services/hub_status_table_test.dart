// How the hub clients read a hub's HTTP status: the kind each status becomes
// and the message the host forwards to a linked client.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/services/calibration/shared_calibration_client.dart';
import 'package:skotiq_core/src/services/constellation/constellation_client.dart';
import 'package:skotiq_core/src/services/constellation/constellation_models.dart';

/// Every status the hub answers with (`server/skotiq_hub`), plus the
/// conflict statuses the clients name (405, 423).
const _statuses = [400, 401, 403, 404, 405, 409, 413, 422, 423, 429, 500, 503];

MockClient _answering(int status) =>
    MockClient((_) async => http.Response('refused', status));

Future<ConstellationException> _failure(Future<Object?> Function() call) async {
  try {
    await call();
  } on ConstellationException catch (e) {
    return e;
  }
  fail('expected a ConstellationException');
}

Future<ConstellationException> _constellation(int status) {
  final client = ConstellationClient(
    hubBaseUrl: Uri.parse('https://hub.example.org'),
    bearerToken: 'tok',
    client: _answering(status),
  );
  return _failure(client.info);
}

Future<ConstellationException> _calibration(int status) {
  final client = SharedCalibrationClient(
    hubBaseUrl: Uri.parse('https://hub.example.org'),
    bearerToken: 'tok',
    client: _answering(status),
  );
  return _failure(() => client.deleteMaster('m1'));
}

const _kinds = <int, ConstellationErrorKind>{
  400: ConstellationErrorKind.protocol,
  401: ConstellationErrorKind.auth,
  403: ConstellationErrorKind.auth,
  404: ConstellationErrorKind.notFound,
  405: ConstellationErrorKind.conflict,
  409: ConstellationErrorKind.geometryMismatch,
  413: ConstellationErrorKind.unknown,
  422: ConstellationErrorKind.protocol,
  423: ConstellationErrorKind.conflict,
  429: ConstellationErrorKind.unknown,
  500: ConstellationErrorKind.server,
  503: ConstellationErrorKind.server,
};

void main() {
  test('the Constellation client reads every hub status', () async {
    for (final status in _statuses) {
      final e = await _constellation(status);
      expect(e.kind, _kinds[status], reason: 'HTTP $status');
      expect(e.statusCode, status);
    }
  });

  test('the shared calibration client reads every hub status', () async {
    final calibration = {
      ..._kinds,
      409: ConstellationErrorKind.protocol,
      422: ConstellationErrorKind.unknown,
    };
    for (final status in _statuses) {
      final e = await _calibration(status);
      expect(e.kind, calibration[status], reason: 'HTTP $status');
      expect(e.statusCode, status);
    }
  });

  test('a refusal names the operation, the status and the hub body', () async {
    expect(
      (await _constellation(422)).message,
      'Hub info failed: the hub rejected this request (HTTP 422): refused',
    );
    expect(
      (await _constellation(409)).message,
      'Hub info failed: tile geometry/order mismatch (hub uses a different '
      'HEALPix tiling) (HTTP 409): refused',
    );
    expect(
      (await _calibration(400)).message,
      'Delete calibration master m1 failed (HTTP 400): refused',
    );
  });
}

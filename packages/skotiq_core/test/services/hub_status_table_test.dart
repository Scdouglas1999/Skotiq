// How the hub clients read a hub's HTTP status: the kind each status becomes
// and the message the host forwards to a linked client.

import 'dart:convert';

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
  test('both hub clients read every hub status alike', () async {
    for (final status in _statuses) {
      for (final e in [
        await _constellation(status),
        await _calibration(status),
      ]) {
        expect(e.kind, _kinds[status], reason: 'HTTP $status');
        expect(e.statusCode, status);
      }
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
      (await _calibration(422)).message,
      'Delete calibration master m1 failed: the hub rejected this request '
      '(HTTP 422): refused',
    );
  });

  _hubErrorCodes();
}

http.Response _hubError(int status, String code, String message) =>
    http.Response(
      jsonEncode({
        'error': {'code': code, 'message': message},
        'requestId': 'r1',
      }),
      status,
    );

ConstellationClient _client(http.Response reply) => ConstellationClient(
  hubBaseUrl: Uri.parse('https://hub.example.org'),
  bearerToken: 'tok',
  client: MockClient((_) async => reply),
);

void _hubErrorCodes() {
  test('a follow-the-night claim another site holds is a state conflict, '
      'not a tiling mismatch', () async {
    final e = await _failure(
      () => _client(
        _hubError(409, 'handoffHeld', 'target 7 is held by another site'),
      ).claimHandoff(7),
    );
    expect(e.kind, ConstellationErrorKind.conflict);
    expect(e.statusCode, 409);
    expect(e.message, isNot(contains('geometry')));
    expect(e.message, contains('hub state conflict'));
  });

  test('every hub state-conflict 409 reads as a conflict', () async {
    for (final code in [
      'accountConflict',
      'coimagingBatonHeld',
      'coimagingSessionClosed',
      'handoffHeld',
      'mosaicNotAssembling',
      'mosaicPanelHeld',
      'notRetractable',
    ]) {
      final e = await _failure(_client(_hubError(409, code, 'no')).info);
      expect(e.kind, ConstellationErrorKind.conflict, reason: code);
    }
  });

  test('the hub geometry 409s still read as a tiling mismatch', () async {
    for (final code in [
      'geometryMismatch',
      'orderMismatch',
      'channelMismatch',
      'idMismatch',
    ]) {
      final e = await _failure(_client(_hubError(409, code, 'no')).info);
      expect(e.kind, ConstellationErrorKind.geometryMismatch, reason: code);
    }
  });
}

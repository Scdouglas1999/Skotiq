// Pairing outcomes map to what the connect flow tells a person, the pairing is
// sent as a desktop with this install's stable id, and a remembered rig keeps
// the fingerprint the list showed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

class _FakeClient extends RemotePairingClient {
  _FakeClient({this.lanResult, this.verifyResult, this.throwOnCall})
    : super(host: 'h', port: 1);

  final RemotePairingVerifyResult? lanResult;
  final RemotePairingVerifyResult? verifyResult;
  final Object? throwOnCall;
  final calls = <Map<String, String>>[];

  @override
  Future<RemotePairingVerifyResult?> lanClaim({
    required String deviceId,
    required String deviceName,
    String deviceType = 'mobile',
  }) async {
    calls.add({'id': deviceId, 'name': deviceName, 'type': deviceType});
    if (throwOnCall != null) throw throwOnCall!;
    return lanResult;
  }

  @override
  Future<RemotePairingVerifyResult> verify({
    required String code,
    required String deviceId,
    required String deviceName,
    String deviceType = 'mobile',
    String requestedScope = 'control',
  }) async {
    calls.add({'code': code, 'type': deviceType, 'scope': requestedScope});
    if (throwOnCall != null) throw throwOnCall!;
    return verifyResult!;
  }
}

final _host = DiscoveredServer(
  host: '192.168.1.32',
  webPort: 8099,
  name: 'Skotiq',
  hostName: 'DESKTOP-MMAJGAK',
  fingerprint: 'dc2f2611',
  platform: 'windows',
  version: '8.2.1',
  lanPairing: true,
);

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('rig_link'));
  tearDown(() => dir.delete(recursive: true));

  RigLinkService serviceWith(_FakeClient client) => RigLinkService(
    store: LinkedRigStore(
      dataDirectory: () async => dir,
      secureStore: InMemorySecureKeyValueStore(),
    ),
    clientFactory: (_) => client,
  );

  test('one tap pairs as a desktop and grants control', () async {
    final client = _FakeClient(
      lanResult: const RemotePairingVerifyResult(
        success: true,
        token: 'tok',
        tokenScope: 'control',
      ),
    );
    final service = serviceWith(client);
    final pairing = await service.pairOneTap(_host, deviceName: 'Skotiq test');
    expect(pairing.token, 'tok');
    expect(pairing.scope, 'control');
    expect(client.calls.single['type'], 'desktop');
    expect(client.calls.single['name'], 'Skotiq test');
    expect(client.calls.single['id'], startsWith('desktop:'));

    final rig = await service.remember(_host, pairing);
    expect(rig.name, 'DESKTOP-MMAJGAK');
    expect(rig.fingerprint, 'dc2f2611');
    expect(await service.store.readToken(), 'tok');
  });

  test('a host that wants a code says so', () async {
    final service = serviceWith(_FakeClient());
    await expectLater(
      service.pairOneTap(_host, deviceName: 'x'),
      throwsA(
        isA<RigPairingFailure>().having(
          (f) => f.kind,
          'kind',
          RigPairingFailureKind.oneTapUnavailable,
        ),
      ),
    );
  });

  test('a code with full access asks for admin', () async {
    final client = _FakeClient(
      verifyResult: const RemotePairingVerifyResult(
        success: true,
        token: 'tok',
        tokenScope: 'admin',
      ),
    );
    final pairing = await serviceWith(client).pairWithCode(
      _host,
      code: 'orbit nebula 4821',
      deviceName: 'x',
      fullAccess: true,
    );
    expect(pairing.scope, 'admin');
    expect(client.calls.single['scope'], 'admin');
    expect(client.calls.single['code'], 'ORBIT-NEBULA-4821');
  });

  test('wrong and spent codes are told apart', () async {
    Future<RigPairingFailureKind> kindFor(String error, int status) async {
      final client = _FakeClient(
        verifyResult: RemotePairingVerifyResult.failure(
          statusCode: status,
          body: {'error': error, 'message': 'm'},
        ),
      );
      try {
        await serviceWith(client).pairWithCode(
          _host,
          code: 'A-B-1',
          deviceName: 'x',
          fullAccess: false,
        );
      } on RigPairingFailure catch (f) {
        return f.kind;
      }
      fail('expected a failure');
    }

    expect(
      await kindFor('invalid_pairing_code', 401),
      RigPairingFailureKind.invalidCode,
    );
    expect(
      await kindFor('pairing_code_expired', 401),
      RigPairingFailureKind.expiredCode,
    );
    expect(await kindFor('locked', 429), RigPairingFailureKind.rateLimited);
  });

  test('a different identity at the address is never paired with', () async {
    final client = _FakeClient(
      throwOnCall: RemotePairingFingerprintMismatch(
        expected: 'dc2f2611',
        actual: 'ffff0000',
      ),
    );
    await expectLater(
      serviceWith(client).pairOneTap(_host, deviceName: 'x'),
      throwsA(
        isA<RigPairingFailure>().having(
          (f) => f.kind,
          'kind',
          RigPairingFailureKind.fingerprintMismatch,
        ),
      ),
    );
  });
}

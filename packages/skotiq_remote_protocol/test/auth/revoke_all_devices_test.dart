// Revoke-all: "take my rig off the network now" is one decision.
//
// A pairing store inherited from an earlier install can hold a dozen phones,
// tablets and browsers, several with `control` or `admin` scope. Revoking them
// one row-menu at a time is how the one that mattered gets left behind, so the
// host owns a bulk revoke — and it has to do all three things a single revoke
// does: deauthorize the stored row (the auth middleware trusts `is_active`),
// drop the device's cellular-push rows (a deauthorized phone must stop
// receiving criticals), and announce the session token so an already-connected
// client is evicted without a host restart.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  late PairingDatabase db;
  late TokenManager tokenManager;

  setUp(() {
    db = PairingDatabase.forTesting(NativeDatabase.memory());
    tokenManager = TokenManager(db);
  });

  tearDown(() async {
    tokenManager.setRevocationListener(null);
    await db.close();
  });

  Future<void> pair(String deviceId, {String grant = 'control'}) =>
      db.addPairedDevice(
        deviceId: deviceId,
        deviceName: 'Device $deviceId',
        sessionToken: 'tok-$deviceId',
        deviceType: 'mobile',
        authGrantSpec: grant,
      );

  test('revokes every active device and reports how many', () async {
    await pair('phone-1');
    await pair('phone-2');
    await pair('browser-1', grant: 'admin');

    expect(await tokenManager.revokeAllDevices(), 3);
    expect(await db.getActivePairedDevices(), isEmpty);
  });

  test('every revoked session token is announced for cache eviction', () async {
    await pair('phone-1');
    await pair('phone-2');

    final evicted = <String>[];
    tokenManager.setRevocationListener(evicted.add);

    await tokenManager.revokeAllDevices();

    // Keyed by token value, not device id: the middleware's in-memory map has
    // no device ids in it, so a bulk revoke that announced nothing would leave
    // both clients authorized until the host restarted.
    expect(evicted, containsAll(<String>['tok-phone-1', 'tok-phone-2']));
  });

  test('cellular-push rows go with the revoked devices', () async {
    await pair('phone-1');
    await db.upsertPushToken(
      deviceId: 'phone-1',
      platform: 'fcm',
      token: 'push-1',
    );

    await tokenManager.revokeAllDevices();

    expect(await db.getPushTokensByPlatform('fcm'), isEmpty);
  });

  test('an already-revoked device is not counted or re-announced', () async {
    await pair('phone-1');
    await tokenManager.revokeDevice('phone-1');

    final evicted = <String>[];
    tokenManager.setRevocationListener(evicted.add);

    expect(
      await tokenManager.revokeAllDevices(),
      0,
      reason:
          'Reporting a revocation that revoked nothing is the '
          'app-says-something-untrue class.',
    );
    expect(evicted, isEmpty);
  });
}

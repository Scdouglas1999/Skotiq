import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/push/database_push_token_store.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// Phase D — the DB-backed [PushTokenStore] adapter.
///
/// Guards two production gaps an in-memory store cannot show:
///  - the store implements [StalePushTokenSink], so the deliveries' automatic
///    404/410 cleanup actually deletes the dead token row;
///  - a revoked device's token never fans out, because `revokeDevice` deletes
///    its push rows AND `getPushTokensByPlatform` joins on `is_active`.
void main() {
  late PairingDatabase db;
  late DatabasePushTokenStore store;

  setUp(() {
    db = PairingDatabase.forTesting(NativeDatabase.memory());
    store = DatabasePushTokenStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pair(String deviceId) => db.addPairedDevice(
    deviceId: deviceId,
    deviceName: 'Test $deviceId',
    sessionToken: 'tok-$deviceId',
    deviceType: 'mobile',
  );

  test('implements StalePushTokenSink (so 404/410 cleanup is not a no-op)', () {
    expect(store, isA<StalePushTokenSink>());
  });

  test(
    'removeStaleToken deletes the dead token row (FCM 404 / APNs 410)',
    () async {
      await pair('phone-1');
      await pair('phone-2');
      await db.upsertPushToken(
        deviceId: 'phone-1',
        platform: 'fcm',
        token: 'DEAD',
      );
      await db.upsertPushToken(
        deviceId: 'phone-2',
        platform: 'fcm',
        token: 'LIVE',
      );

      await (store as StalePushTokenSink).removeStaleToken('DEAD');

      final remaining = await store.tokensForPlatform('fcm');
      expect(remaining.map((t) => t.token), ['LIVE']);
    },
  );

  test('revoking a device drops its token from the fan-out set', () async {
    await pair('keep');
    await pair('revoked');
    await db.upsertPushToken(deviceId: 'keep', platform: 'fcm', token: 'KEEP');
    await db.upsertPushToken(
      deviceId: 'revoked',
      platform: 'fcm',
      token: 'REVOKED',
    );

    // Both reachable while active.
    expect(
      (await store.tokensForPlatform('fcm')).map((t) => t.deviceId).toSet(),
      {'keep', 'revoked'},
    );

    await db.revokeDevice('revoked');

    // revokeDevice deletes the push row, and the fan-out query additionally
    // joins on is_active — so the deauthorized phone is gone from the set.
    final after = await store.tokensForPlatform('fcm');
    expect(after.map((t) => t.deviceId), ['keep']);
    expect(await db.getPushTokensForDevice('revoked'), isEmpty);
  });
}

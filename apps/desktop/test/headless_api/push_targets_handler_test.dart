// Regression coverage for `GET /api/push/targets` — the host's answer to
// "can a critical alert actually reach a phone right now?".
//
// Observed live (2026-07-25): Settings -> Notifications rendered "Push
// critical alerts to mobile" toggled ON with nothing indicating that this
// device could not receive them. On Android in a stock build none ever can —
// `apps/mobile/android/app/google-services.json` is absent, so the client logs
// `FCM not configured (no google-services.json); push registration dormant`
// and never registers a token. This endpoint is what lets the UI say so,
// instead of the setting asserting a capability the system does not have.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_service.dart';
import 'package:skotiq_desktop/headless_api/handlers/push_handlers.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:shelf/shelf.dart';

void main() {
  group('GET /api/push/targets', () {
    late PairingDatabase database;
    late PairingService pairingService;
    var channel = PushDeliveryChannel.none;
    late PushHandlers handlers;

    setUp(() {
      database = PairingDatabase.forTesting(NativeDatabase.memory());
      pairingService = PairingService(database: database);
      channel = PushDeliveryChannel.none;
      handlers = PushHandlers(
        ensurePairingService: () => pairingService,
        logger: LoggingService(
          nativeInitWithLogging: ({logDirectory}) {},
          nativeInit: () {},
          currentLogFileProvider: () => null,
        ),
        deliveryChannel: () => channel,
      );
    });

    tearDown(() async {
      await pairingService.close();
    });

    Future<Map<String, dynamic>> targets() async {
      final response = await handlers.handleGetTargets(
        Request('GET', Uri.parse('http://localhost/api/push/targets')),
      );
      expect(response.statusCode, HttpStatus.ok);
      return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    }

    Future<void> pairDevice(String deviceId) async {
      await database.addPairedDevice(
        deviceId: deviceId,
        deviceName: 'Device $deviceId',
        deviceType: 'mobile',
        sessionToken: 'token-$deviceId',
        expiresAt: DateTime.now().add(const Duration(days: 30)),
      );
    }

    test('reports zero targets when nothing has registered', () async {
      final body = await targets();

      expect(body['registeredDeviceCount'], 0);
      expect(body['fcmTokenCount'], 0);
      expect(body['apnsTokenCount'], 0);
      expect(body['cloudDeliveryConfigured'], isFalse);
      // The single question the UI asks.
      expect(body['canDeliver'], isFalse);

      final parsed = PushDeliveryTargets.fromJson(body);
      expect(parsed.canDeliver, isFalse);
      expect(parsed.blockedReason, isNotNull);
    });

    test(
      'a registered token alone is NOT enough when no channel is configured',
      () async {
        await pairDevice('phone-1');
        await database.upsertPushToken(
          deviceId: 'phone-1',
          platform: 'fcm',
          token: 'fcm-token-value',
        );

        final body = await targets();
        expect(body['registeredDeviceCount'], 1);
        expect(body['fcmTokenCount'], 1);
        expect(body['cloudDeliveryConfigured'], isFalse);
        // Registered, but the host has nothing to send WITH.
        expect(body['canDeliver'], isFalse);
        expect(
          PushDeliveryTargets.fromJson(body).blockedReason,
          contains('no push delivery configured'),
        );
      },
    );

    test('reports a deliverable target once both halves are true', () async {
      channel = PushDeliveryChannel.cloud;
      await pairDevice('phone-1');
      await database.upsertPushToken(
        deviceId: 'phone-1',
        platform: 'fcm',
        token: 'fcm-token-value',
      );

      final body = await targets();
      expect(body['registeredDeviceCount'], 1);
      expect(body['canDeliver'], isTrue);
      expect(PushDeliveryTargets.fromJson(body).blockedReason, isNull);
    });

    test('a would-send mock is not a delivery channel', () async {
      channel = PushDeliveryChannel.mock;
      await pairDevice('phone-1');
      await database.upsertPushToken(
        deviceId: 'phone-1',
        platform: 'fcm',
        token: 'fcm-token-value',
      );

      final body = await targets();
      expect(body['registeredDeviceCount'], 1);
      // A MockRemotePushDelivery records what it would have sent and reaches
      // no phone, so it must not read as a configured channel.
      expect(body['deliveryChannel'], 'mock');
      expect(body['cloudDeliveryConfigured'], isFalse);
      expect(body['canDeliver'], isFalse);
      expect(PushDeliveryTargets.fromJson(body).blockedReason, isNotNull);
    });

    test('names the channel on every answer', () async {
      expect((await targets())['deliveryChannel'], 'none');
      channel = PushDeliveryChannel.cloud;
      expect((await targets())['deliveryChannel'], 'cloud');
    });

    test('counts devices, not tokens, and splits by platform', () async {
      channel = PushDeliveryChannel.cloud;
      await pairDevice('phone-1');
      await pairDevice('phone-2');
      // One device registered on both platforms — still ONE device.
      await database.upsertPushToken(
        deviceId: 'phone-1',
        platform: 'fcm',
        token: 'fcm-1',
      );
      await database.upsertPushToken(
        deviceId: 'phone-1',
        platform: 'apns',
        token: 'apns-1',
      );
      await database.upsertPushToken(
        deviceId: 'phone-2',
        platform: 'apns',
        token: 'apns-2',
      );

      final body = await targets();
      expect(body['registeredDeviceCount'], 2);
      expect(body['fcmTokenCount'], 1);
      expect(body['apnsTokenCount'], 2);
    });

    test('never returns token values or device identifiers', () async {
      channel = PushDeliveryChannel.cloud;
      await pairDevice('phone-secret');
      await database.upsertPushToken(
        deviceId: 'phone-secret',
        platform: 'fcm',
        token: 'super-secret-token-value',
      );

      final response = await handlers.handleGetTargets(
        Request('GET', Uri.parse('http://localhost/api/push/targets')),
      );
      final raw = await response.readAsString();

      expect(raw, isNot(contains('super-secret-token-value')));
      expect(raw, isNot(contains('phone-secret')));
    });

    test(
      'tracks the live delivery configuration, not a boot snapshot',
      () async {
        await pairDevice('phone-1');
        await database.upsertPushToken(
          deviceId: 'phone-1',
          platform: 'fcm',
          token: 'fcm-1',
        );

        expect((await targets())['canDeliver'], isFalse);
        channel = PushDeliveryChannel.cloud;
        expect((await targets())['canDeliver'], isTrue);
      },
    );
  });
}

// `paired_devices.last_connected_at` had no writer in production.
//
// The only code that stamped it — TokenManager.verifySessionToken — has no
// production caller: the auth middleware authenticates paired bearers against
// its in-memory `_pairedSessionTokens` map, which was hydrated from Drift at
// boot and never wrote back. So the Paired Devices screen reported
// "Not seen yet / No connection recorded yet" for a phone that was driving the
// rig at that very moment, and an operator had no way to tell a live client
// from an abandoned pairing they should revoke.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_service.dart';
import 'package:skotiq_desktop/headless_api_server.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../headless_api/handler_test_helpers.dart';

const _deviceId = 'phone-1';
const _sessionToken = 'paired-session-token-abcdefgh';

void main() {
  group('paired device activity', () {
    late ProviderContainer container;
    late HeadlessApiServer server;
    late PairingDatabase database;
    late PairingService pairingService;
    late HttpClient client;
    late Uri baseUri;

    setUp(() async {
      database = PairingDatabase.forTesting(NativeDatabase.memory());
      // Paired before boot, exactly like a phone that paired last night: the
      // server hydrates the token into its in-memory map at start().
      await database.addPairedDevice(
        deviceId: _deviceId,
        deviceName: 'Pixel',
        sessionToken: _sessionToken,
        deviceType: 'android',
        expiresAt: DateTime.now().add(const Duration(days: 30)),
        authGrantSpec: 'control',
      );
      pairingService = PairingService(database: database);
      container = createHeadlessTestContainer(
        overrides: [
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '2.5.0', buildNumber: 5),
          ),
        ],
      );
      server = HeadlessApiServer(
        port: 0,
        container: container,
        bindLocalOnly: true,
        authToken: 'admin-token',
        pairingService: pairingService,
      );
      await server.start();
      client = HttpClient();
      baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      await pairingService.close();
      container.dispose();
    });

    test('an authenticated request records the device as seen', () async {
      expect(
        (await database.getPairedDevice(_deviceId))?.lastConnectedAt,
        isNull,
        reason: 'nothing has connected yet',
      );

      final status = await _get(
        client,
        baseUri,
        '/api/status',
        token: _sessionToken,
      );
      expect(status, isNot(HttpStatus.unauthorized));
      expect(status, isNot(HttpStatus.forbidden));

      final seenAt = await _awaitLastConnected(database);
      expect(
        seenAt,
        isNotNull,
        reason:
            'The device just made an authenticated request; the Paired '
            'Devices screen must not still read "Not seen yet".',
      );
      expect(
        DateTime.now().difference(seenAt!).inMinutes,
        lessThan(1),
        reason: 'The stamp must be this connection, not a stale one.',
      );
    });

    test('an unknown bearer never marks a paired device as seen', () async {
      final status = await _get(
        client,
        baseUri,
        '/api/status',
        token: 'not-a-real-token',
      );
      expect(status, anyOf(HttpStatus.forbidden, HttpStatus.unauthorized));

      // Give the fire-and-forget write the same window the positive test uses.
      final seenAt = await _awaitLastConnected(database);
      expect(seenAt, isNull);
    });
  });
}

Future<DateTime?> _awaitLastConnected(PairingDatabase database) async {
  // The stamp is deliberately off the request path, so poll rather than
  // assuming it lands before the response does.
  for (var attempt = 0; attempt < 40; attempt++) {
    final row = await database.getPairedDevice(_deviceId);
    if (row?.lastConnectedAt != null) return row!.lastConnectedAt;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return null;
}

Future<int> _get(
  HttpClient client,
  Uri baseUri,
  String path, {
  required String token,
}) async {
  final request = await client.openUrl('GET', baseUri.replace(path: path));
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  final response = await request.close();
  await response.transform(utf8.decoder).join();
  return response.statusCode;
}

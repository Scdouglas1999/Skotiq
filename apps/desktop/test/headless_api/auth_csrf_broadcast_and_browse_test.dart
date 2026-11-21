import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_desktop/headless_api/auth/auth_cookie.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_service.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api/handlers/broadcast_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/filesystem_handlers.dart';
import 'package:skotiq_desktop/headless_api_server.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_remote_protocol/wire.dart';

import 'handler_test_helpers.dart';

class _TestSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

void main() {
  group('Auth policy, CSRF, broadcast, and browse', () {
    test('AuthApi routes permit view-scope clients', () {
      expect(AuthApi.wsTicketIssue.route.scope, ApiScope.view);
      expect(AuthApi.cookieIssue.route.scope, ApiScope.view);
      expect(AuthApi.logout.route.scope, ApiScope.view);
    });

    test('empty HeadlessAuthGrant fails closed on toSpec/parseSpec', () {
      final empty = HeadlessAuthGrant.forResources(const {});
      final spec = empty.toSpec();
      expect(spec, isEmpty);
      expect(spec, isNot('view'));
      expect(HeadlessAuthGrant.parseSpec(spec), isNull);
    });

    test('AuthCookieManager.validateCsrf enforces csrfExpiresAt', () {
      var now = DateTime.utc(2026, 11, 21, 12, 0, 0);
      final manager = AuthCookieManager(now: () => now);
      final session = manager.mint('tok-1');
      expect(
        manager.validateCsrf(
          cookieToken: session.cookieToken,
          presented: session.csrfToken,
        ),
        isTrue,
      );

      // Advance past csrfLifetime while cookieLifetime is still valid.
      now = now.add(AuthCookieManager.csrfLifetime + const Duration(hours: 1));
      expect(manager.resolveBearer(session.cookieToken), 'tok-1');
      expect(
        manager.validateCsrf(
          cookieToken: session.cookieToken,
          presented: session.csrfToken,
        ),
        isFalse,
      );
    });

    test('fetchCsrf keeps a live token and rotates it after expiry', () {
      var now = DateTime.utc(2026, 11, 21, 12);
      final manager = AuthCookieManager(now: () => now, random: Random(1));
      final session = manager.mint('tok-1');
      expect(manager.fetchCsrf(session.cookieToken), session.csrfToken);

      now = now.add(const Duration(days: 1));
      expect(manager.fetchCsrf(session.cookieToken), session.csrfToken);

      now = now.add(
        AuthCookieManager.csrfLifetime + const Duration(seconds: 1),
      );
      final rotated = manager.fetchCsrf(session.cookieToken);
      expect(rotated, isNotNull);
      expect(rotated, isNot(session.csrfToken));
      expect(
        manager.validateCsrf(
          cookieToken: session.cookieToken,
          presented: session.csrfToken,
        ),
        isFalse,
      );
      expect(
        manager.validateCsrf(
          cookieToken: session.cookieToken,
          presented: rotated,
        ),
        isTrue,
      );
    });

    test(
      'BroadcastHandlers renders private broadcast page using URLSearchParams token forwarding instead of hardcoded ellipsis',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final svc = container.read(liveStackingBroadcastServiceProvider);
        svc.activate(
          LiveStackingNode(
            id: 'node-1',
            broadcastEnabled: true,
            authToken: 'secret-live-token',
          ),
        );

        final handlers = BroadcastHandlers(container: container);
        final response = await handlers.handleBroadcastPage(
          Request(
            'GET',
            Uri.parse('http://localhost/broadcast?token=secret-live-token'),
          ),
        );
        expect(response.statusCode, 200);
        final html = await response.readAsString();
        expect(html, isNot(contains('?token=…')));
        expect(html, contains('URLSearchParams(window.location.search)'));
        expect(html, isNot(contains('secret-live-token')));
      },
    );

    test(
      'FileSystemHandlers.handleBrowseDirectories rejects out-of-root non-existent path with 403 (no existence oracle)',
      () async {
        final allowedRoot = await Directory.systemTemp.createTemp('fs_root_');
        addTearDown(() => allowedRoot.delete(recursive: true));
        final container = ProviderContainer(
          overrides: [appSettingsProvider.overrideWith(_TestSettings.new)],
        );
        addTearDown(container.dispose);

        final handlers = FileSystemHandlers(
          container,
          environment: {'SKOTIQ_BROWSE_ROOTS': 'Root=${allowedRoot.path}'},
        );
        final outsideMissing =
            '${Directory.systemTemp.path}${Platform.pathSeparator}definitely_missing_outside_dir_999999';
        final response = await handlers.handleBrowseDirectories(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/files/browse?path=${Uri.encodeQueryComponent(outsideMissing)}',
            ),
          ),
        );
        expect(response.statusCode, 403);
      },
    );

    test(
      'view-scope token can mint a WS ticket and connect, and a ticket for a revoked paired device is rejected at WS upgrade',
      () async {
        final db = PairingDatabase.forTesting(NativeDatabase.memory());
        final pairingService = PairingService(database: db);
        final container = createHeadlessTestContainer(
          overrides: [
            appSettingsProvider.overrideWith(_TestSettings.new),
            appVersionProvider.overrideWithValue(
              const AppVersionInfo(version: '9.0.2', buildNumber: 1),
            ),
          ],
        );
        addTearDown(container.dispose);
        final server = HeadlessApiServer(
          container: container,
          port: 0,
          bindLocalOnly: true,
          pairingService: pairingService,
          scopedAuthTokens: const {'viewer-tok': HeadlessTokenScope.view},
        );
        await server.start();
        addTearDown(server.stop);

        final client = HttpClient();
        addTearDown(client.close);

        // 1. View-scope token mints a ticket and upgrades /api/ws successfully.
        final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.actualPort}/api/ws/ticket'),
        );
        req.headers.set('authorization', 'Bearer viewer-tok');
        req.headers.set('x-skotiq-version', '9.0.2');
        final res = await req.close();
        final resText = await res.transform(utf8.decoder).join();
        expect(res.statusCode, 200, reason: resText);
        final body = jsonDecode(resText) as Map<String, dynamic>;
        final ticket = body['ticket'] as String;
        expect(ticket, isNotEmpty);

        final ws = await WebSocket.connect(
          'ws://127.0.0.1:${server.actualPort}/api/ws?ticket=$ticket',
          headers: {'x-skotiq-version': '9.0.2'},
        );
        await ws.close();

        // 2. Paired device mints a ticket, gets revoked before connecting,
        // and MUST be rejected on WS upgrade (not admitted on stale ticket).
        final start = await pairingService.startPairing();
        final verifyReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.actualPort}/api/pairing/verify'),
        );
        verifyReq.headers.set('content-type', 'application/json');
        verifyReq.headers.set('x-skotiq-version', '9.0.2');
        verifyReq.write(
          jsonEncode({
            'code': start.code,
            'deviceId': 'revoked-ws-device',
            'deviceName': 'Revoked Phone',
            'deviceType': 'mobile',
            'requestedScope': 'view',
          }),
        );
        final verifyRes = await verifyReq.close();
        expect(verifyRes.statusCode, 200);
        final verifyBody =
            jsonDecode(await verifyRes.transform(utf8.decoder).join())
                as Map<String, dynamic>;
        final pairedToken = verifyBody['token'] as String;

        final ticketReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.actualPort}/api/ws/ticket'),
        );
        ticketReq.headers.set('authorization', 'Bearer $pairedToken');
        ticketReq.headers.set('x-skotiq-version', '9.0.2');
        final ticketRes = await ticketReq.close();
        expect(ticketRes.statusCode, 200);
        final ticketBody =
            jsonDecode(await ticketRes.transform(utf8.decoder).join())
                as Map<String, dynamic>;
        final revokedTicket = ticketBody['ticket'] as String;

        // Revoke the device BEFORE the WebSocket upgrade happens.
        await pairingService.tokenManager.revokeDevice('revoked-ws-device');

        final upgradeReq = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:${server.actualPort}/api/ws?ticket=$revokedTicket',
          ),
        );
        upgradeReq.headers.set('x-skotiq-version', '9.0.2');
        final upgradeRes = await upgradeReq.close();
        await upgradeRes.drain<void>();
        expect(upgradeRes.statusCode, 401);
      },
    );

    test(
      'cookie logout succeeds without a CSRF token; other posts still require one',
      () async {
        final container = createHeadlessTestContainer(
          overrides: [
            appSettingsProvider.overrideWith(_TestSettings.new),
            appVersionProvider.overrideWithValue(
              const AppVersionInfo(version: '9.0.2', buildNumber: 1),
            ),
          ],
        );
        addTearDown(container.dispose);
        final server = HeadlessApiServer(
          container: container,
          port: 0,
          bindLocalOnly: true,
          scopedAuthTokens: const {'viewer-tok': HeadlessTokenScope.view},
        );
        await server.start();
        addTearDown(server.stop);
        final client = HttpClient();
        addTearDown(client.close);

        final cookieReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.actualPort}/api/auth/cookie'),
        );
        cookieReq.headers.set('authorization', 'Bearer viewer-tok');
        cookieReq.headers.set('x-skotiq-version', '9.0.2');
        final cookieRes = await cookieReq.close();
        final cookieBody = await cookieRes.transform(utf8.decoder).join();
        expect(cookieRes.statusCode, 200, reason: cookieBody);
        final setCookie = cookieRes.headers.value('set-cookie');
        expect(setCookie, isNotNull);
        final cookieHeader = setCookie!.split(';').first;

        final blocked = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.actualPort}/api/auth/cookie'),
        );
        blocked.headers.set('cookie', cookieHeader);
        blocked.headers.set('x-skotiq-version', '9.0.2');
        final blockedRes = await blocked.close();
        final blockedBody = await blockedRes.transform(utf8.decoder).join();
        expect(blockedRes.statusCode, 403, reason: blockedBody);
        expect(blockedBody, contains('csrf'));

        final logoutReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.actualPort}/api/auth/logout'),
        );
        logoutReq.headers.set('cookie', cookieHeader);
        logoutReq.headers.set('x-skotiq-version', '9.0.2');
        final logoutRes = await logoutReq.close();
        final logoutBody = await logoutRes.transform(utf8.decoder).join();
        expect(logoutRes.statusCode, 200, reason: logoutBody);
      },
    );
  });
}

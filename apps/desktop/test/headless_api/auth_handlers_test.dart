import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/auth/auth_cookie.dart';
import 'package:skotiq_desktop/headless_api/auth/ws_ticket_manager.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api/handlers/auth_handlers.dart';
import 'package:shelf/shelf.dart';

void main() {
  late AuthHandlers handlers;

  setUp(() {
    handlers = AuthHandlers(
      wsTicketManager: WsTicketManager(),
      authCookieManager: AuthCookieManager(),
      scopeForToken: (token) =>
          token == 'valid' ? HeadlessTokenScope.admin : null,
      logger: LoggingService(),
    );
  });

  test('plain-HTTP LAN dashboard receives a browser-usable cookie', () async {
    final response = await handlers.handleAuthCookieIssue(
      Request(
        'POST',
        Uri.parse('http://192.168.1.47:8080/api/auth/cookie'),
        headers: {'authorization': 'Bearer valid'},
      ),
    );

    final cookie = response.headers['set-cookie'];
    expect(cookie, contains('HttpOnly'));
    expect(cookie, contains('SameSite=Strict'));
    expect(cookie, isNot(contains('; Secure')));
  });

  test('HTTPS dashboard cookie retains the Secure attribute', () async {
    final response = await handlers.handleAuthCookieIssue(
      Request(
        'POST',
        Uri.parse('https://rig.example/api/auth/cookie'),
        headers: {'authorization': 'Bearer valid'},
      ),
    );

    expect(response.headers['set-cookie'], contains('; Secure'));
  });
}

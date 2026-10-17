import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless/headless_security_advisories.dart';

void main() {
  group('headlessSecurityAdvisories', () {
    test('loopback-only is always safe, regardless of auth/tls', () {
      expect(
        headlessSecurityAdvisories(
          bindLocalOnly: true,
          hasAuth: false,
          tlsEnabled: false,
        ),
        isEmpty,
      );
      expect(
        headlessSecurityAdvisories(
          bindLocalOnly: true,
          hasAuth: true,
          tlsEnabled: true,
        ),
        isEmpty,
      );
    });

    test('LAN exposure with auth AND tls produces no advisories', () {
      expect(
        headlessSecurityAdvisories(
          bindLocalOnly: false,
          hasAuth: true,
          tlsEnabled: true,
        ),
        isEmpty,
      );
    });

    test('LAN exposure without auth warns about unauthenticated control', () {
      final advisories = headlessSecurityAdvisories(
        bindLocalOnly: false,
        hasAuth: false,
        tlsEnabled: true,
      );
      expect(advisories, hasLength(1));
      expect(advisories.single, contains('UNAUTHENTICATED LAN CONTROL'));
    });

    test('LAN exposure without tls warns about cleartext credentials', () {
      final advisories = headlessSecurityAdvisories(
        bindLocalOnly: false,
        hasAuth: true,
        tlsEnabled: false,
      );
      expect(advisories, hasLength(1));
      expect(advisories.single, contains('TLS IS OFF'));
    });

    test('LAN exposure with neither auth nor tls warns about both', () {
      final advisories = headlessSecurityAdvisories(
        bindLocalOnly: false,
        hasAuth: false,
        tlsEnabled: false,
      );
      expect(advisories, hasLength(2));
      expect(
        advisories.any((a) => a.contains('UNAUTHENTICATED LAN CONTROL')),
        isTrue,
      );
      expect(advisories.any((a) => a.contains('TLS IS OFF')), isTrue);
    });
  });
}

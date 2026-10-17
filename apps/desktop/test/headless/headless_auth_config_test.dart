// Tests for parseHeadlessAuthConfig
// (apps/desktop/lib/headless/headless_auth_config.dart).
//
// parseHeadlessAuthConfig reads BOTH CLI args and Platform.environment. A Dart
// test process cannot inject env vars, so these tests assert the CLI-driven
// behaviour and the defaults that hold when the SKOTIQ_* env vars are
// absent (the normal CI state). Each test that depends on the absence of env
// vars is written so it remains correct whether or not the operator has set
// any SKOTIQ_* variables, by only asserting on what the CLI args drive.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless/headless_auth_config.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api/handlers/pairing_handlers.dart'
    show PairingMode;

void main() {
  group('parseHeadlessAuthConfig — defaults (no CLI args)', () {
    final config = parseHeadlessAuthConfig(const []);

    test('default port is 8080', () {
      expect(config.port, 8080);
    });

    test('requireAuth defaults to false', () {
      expect(config.requireAuth, isFalse);
    });

    test('allowUnauthenticated defaults to false (fail closed)', () {
      expect(config.allowUnauthenticated, isFalse);
    });

    test('pairing mode defaults to lanOpen (one-tap LAN pairing)', () {
      expect(config.pairingMode, PairingMode.lanOpen);
    });

    test('TLS is disabled by default', () {
      expect(config.tlsEnabled, isFalse);
      expect(config.tlsCertPath, isNull);
      expect(config.tlsKeyPath, isNull);
    });

    test('scoped tokens and CORS origins are empty by default', () {
      expect(config.scopedTokens, isEmpty);
      expect(config.corsAllowedOrigins, isEmpty);
    });
  });

  group('bind mode — the security-critical default', () {
    // NOTE (verified behaviour): the headless server binds LOOPBACK-ONLY by
    // default. With no token and no --allow-unauthenticated-lan flag,
    // bindLocalOnly resolves to TRUE. The implementation is:
    //   bindLocalOnly = !hasAuthentication && !allowUnauthenticatedLan
    // i.e. the rig will NOT expose itself to the LAN until the operator either
    // configures authentication or explicitly opts into unauthenticated LAN.
    test('default bind is loopback-only with no token and no LAN flag', () {
      final config = parseHeadlessAuthConfig(const []);
      expect(
        config.bindLocalOnly,
        isTrue,
        reason: 'secure default must be loopback-only, not 0.0.0.0',
      );
      expect(config.token, isNull);
    });

    test('supplying an auth token opens binding to the LAN', () {
      // Having authentication means bindLocalOnly flips to false: the rig is
      // safe to expose because requests must present the token.
      final config = parseHeadlessAuthConfig(const ['--auth-token=secret']);
      expect(config.token, 'secret');
      expect(config.bindLocalOnly, isFalse);
    });

    test('--require-auth alone counts as authentication and opens the LAN', () {
      final config = parseHeadlessAuthConfig(const ['--require-auth']);
      expect(config.requireAuth, isTrue);
      expect(config.bindLocalOnly, isFalse);
    });

    test('a scoped token alone counts as authentication and opens the LAN', () {
      final config = parseHeadlessAuthConfig(const ['--view-token=v1']);
      expect(config.scopedTokens, containsPair('v1', HeadlessTokenScope.view));
      expect(config.bindLocalOnly, isFalse);
    });
  });

  group('unauthenticated LAN behaviour', () {
    // NOTE (verified behaviour): --allow-unauthenticated-lan is the ONLY way to
    // expose the server to the LAN WITHOUT any authentication. It does not add
    // a token or force --require-auth; it simply lets bindLocalOnly become
    // false while token stays null. This is an explicit, deliberate opt-in.
    test('--allow-unauthenticated-lan opens LAN with no token', () {
      final config = parseHeadlessAuthConfig(const [
        '--allow-unauthenticated-lan',
      ]);
      expect(config.token, isNull);
      expect(config.requireAuth, isFalse);
      expect(
        config.bindLocalOnly,
        isFalse,
        reason: 'explicit opt-in exposes the server unauthenticated',
      );
    });

    // --allow-unauthenticated is the serve-open escape hatch (authentication),
    // distinct from --allow-unauthenticated-lan (network bind). It does not, on
    // its own, open the LAN bind — that still requires the LAN flag.
    test('--allow-unauthenticated sets the serve-open escape hatch', () {
      final config = parseHeadlessAuthConfig(const ['--allow-unauthenticated']);
      expect(config.allowUnauthenticated, isTrue);
      expect(config.token, isNull);
      expect(
        config.bindLocalOnly,
        isTrue,
        reason: 'serve-open does not by itself open the LAN bind',
      );
    });
  });

  group('token normalisation', () {
    test('a whitespace-only --auth-token is collapsed to null', () {
      final config = parseHeadlessAuthConfig(const ['--auth-token=   ']);
      expect(config.token, isNull);
      // With no real authentication it falls back to loopback-only.
      expect(config.bindLocalOnly, isTrue);
    });

    test('an empty --auth-token is collapsed to null', () {
      final config = parseHeadlessAuthConfig(const ['--auth-token=']);
      expect(config.token, isNull);
      expect(config.bindLocalOnly, isTrue);
    });

    test('a token with surrounding text is kept verbatim (not trimmed)', () {
      // The non-empty branch keeps the token exactly as supplied.
      final config = parseHeadlessAuthConfig(const ['--auth-token=abc123']);
      expect(config.token, 'abc123');
    });
  });

  group('port parsing', () {
    test('--port overrides the default', () {
      final config = parseHeadlessAuthConfig(const ['--port=9090']);
      expect(config.port, 9090);
    });

    test('an unparseable --port falls back to the prior value (8080)', () {
      final config = parseHeadlessAuthConfig(const ['--port=not-a-number']);
      expect(config.port, 8080);
    });
  });

  group('scoped tokens', () {
    test('view and control tokens map to their scopes', () {
      final config = parseHeadlessAuthConfig(const [
        '--view-token=viewer',
        '--control-token=operator',
      ]);
      expect(
        config.scopedTokens,
        containsPair('viewer', HeadlessTokenScope.view),
      );
      expect(
        config.scopedTokens,
        containsPair('operator', HeadlessTokenScope.control),
      );
    });

    test('a blank scoped token is ignored', () {
      final config = parseHeadlessAuthConfig(const ['--view-token=   ']);
      expect(config.scopedTokens, isEmpty);
    });

    test('scopedTokens is unmodifiable', () {
      final config = parseHeadlessAuthConfig(const ['--view-token=v']);
      expect(
        () => config.scopedTokens['x'] = HeadlessTokenScope.admin,
        throwsUnsupportedError,
      );
    });
  });

  group('fine-grained scoped tokens', () {
    test('--scoped-token parses a per-resource grant spec', () {
      final config = parseHeadlessAuthConfig(const [
        '--scoped-token=cam=camera:control,mount:view',
      ]);
      final grant = config.fineGrainedTokens['cam'];
      expect(grant, isNotNull);
      expect(
        grant!.levelFor(HeadlessResource.camera),
        HeadlessAccessLevel.control,
      );
      expect(grant.levelFor(HeadlessResource.mount), HeadlessAccessLevel.view);
      expect(grant.isAdmin, isFalse);
    });

    test('--scoped-token accepts a coarse name as the spec', () {
      final config = parseHeadlessAuthConfig(const ['--scoped-token=op=admin']);
      expect(config.fineGrainedTokens['op']!.isAdmin, isTrue);
    });

    test('a fine-grained token alone opens the LAN', () {
      final config = parseHeadlessAuthConfig(const [
        '--scoped-token=cam=camera:control',
      ]);
      expect(config.bindLocalOnly, isFalse);
    });

    test('a malformed spec is skipped (fail-closed launch)', () {
      final config = parseHeadlessAuthConfig(const [
        '--scoped-token=cam=warp:control',
        '--scoped-token=no-equals-sign',
      ]);
      expect(config.fineGrainedTokens, isEmpty);
    });

    test('fineGrainedTokens is unmodifiable', () {
      final config = parseHeadlessAuthConfig(const [
        '--scoped-token=cam=camera:control',
      ]);
      expect(
        () => config.fineGrainedTokens['x'] = HeadlessAuthGrant.admin(),
        throwsUnsupportedError,
      );
    });
  });

  group('CORS origins', () {
    test('--cors-origin accumulates non-empty origins', () {
      final config = parseHeadlessAuthConfig(const [
        '--cors-origin=https://a.example',
        '--cors-origin=https://b.example',
      ]);
      expect(
        config.corsAllowedOrigins,
        containsAll(<String>['https://a.example', 'https://b.example']),
      );
    });

    test('a blank --cors-origin is ignored', () {
      final config = parseHeadlessAuthConfig(const ['--cors-origin=   ']);
      expect(config.corsAllowedOrigins, isEmpty);
    });

    test('corsAllowedOrigins is unmodifiable', () {
      final config = parseHeadlessAuthConfig(const [
        '--cors-origin=https://a.example',
      ]);
      expect(
        () => config.corsAllowedOrigins.add('https://evil.example'),
        throwsUnsupportedError,
      );
    });
  });

  group('TLS path implications', () {
    test('--tls enables TLS with no cert/key paths', () {
      final config = parseHeadlessAuthConfig(const ['--tls']);
      expect(config.tlsEnabled, isTrue);
      expect(config.tlsCertPath, isNull);
      expect(config.tlsKeyPath, isNull);
    });

    test('a --tls-cert path implies TLS even without --tls', () {
      final config = parseHeadlessAuthConfig(const [
        '--tls-cert=/etc/ssl/rig.pem',
      ]);
      expect(config.tlsEnabled, isTrue);
      expect(config.tlsCertPath, '/etc/ssl/rig.pem');
    });

    test('a --tls-key path alone also implies TLS', () {
      final config = parseHeadlessAuthConfig(const [
        '--tls-key=/etc/ssl/rig.key',
      ]);
      expect(config.tlsEnabled, isTrue);
      expect(config.tlsKeyPath, '/etc/ssl/rig.key');
    });

    test('a whitespace-only --tls-cert is treated as unset', () {
      final config = parseHeadlessAuthConfig(const ['--tls-cert=   ']);
      expect(config.tlsCertPath, isNull);
      // No path and no --tls means TLS stays off (when env is clean).
      expect(config.tlsEnabled, isFalse);
    });

    test('both cert and key paths are captured', () {
      final config = parseHeadlessAuthConfig(const [
        '--tls-cert=/c.pem',
        '--tls-key=/k.pem',
      ]);
      expect(config.tlsEnabled, isTrue);
      expect(config.tlsCertPath, '/c.pem');
      expect(config.tlsKeyPath, '/k.pem');
    });
  });

  group('pairing flags', () {
    test('--pairing-print-codes enables code printing', () {
      final config = parseHeadlessAuthConfig(const ['--pairing-print-codes']);
      expect(config.pairingPrintCodes, isTrue);
    });
  });
}

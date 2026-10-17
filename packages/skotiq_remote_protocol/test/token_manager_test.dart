import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_remote_protocol/src/auth/token_manager.dart';
import 'package:skotiq_remote_protocol/src/database/pairing_database.dart';

class MockPairingDatabase extends Mock implements PairingDatabase {}

class FakePairedDevicesCompanion extends Fake
    implements PairedDevicesCompanion {}

void main() {
  // mocktail requires non-primitive matcher fallbacks be registered up front
  // so `any()` / `any(named: ...)` for these types is safe in stubs and
  // verifications across the entire test file.
  setUpAll(() {
    registerFallbackValue(DateTime(2025, 1, 1));
  });

  group('TokenManager', () {
    late MockPairingDatabase mockDb;
    late TokenManager tokenManager;

    setUp(() {
      mockDb = MockPairingDatabase();
      tokenManager = TokenManager(mockDb);
      // The expiry/revoke sweep deletes each affected device's push rows so a
      // deauthorized phone stops receiving cellular criticals. Stub these as
      // no-ops by default; the dedicated sweep test verifies the call count.
      when(
        () => mockDb.deletePushTokensForDevice(any()),
      ).thenAnswer((_) async {});
      when(
        () => mockDb.deletePushPrefsForDevice(any()),
      ).thenAnswer((_) async {});
    });

    tearDown(() {
      tokenManager.setRevocationListener(null);
    });

    group('generateSecureToken', () {
      test('produces a 64-character hex string', () {
        final token = tokenManager.generateSecureToken();

        expect(token.length, equals(64));
        expect(token, matches(RegExp(r'^[0-9a-f]{64}$')));
      });

      test('generates unique tokens on successive calls', () {
        final tokens = <String>{};
        for (int i = 0; i < 50; i++) {
          tokens.add(tokenManager.generateSecureToken());
        }
        // All 50 should be unique
        expect(tokens.length, equals(50));
      });
    });

    group('generatePairingCode', () {
      test('follows WORD-WORD-NNNN format', () {
        final token = tokenManager.generateSecureToken();
        final code = tokenManager.generatePairingCode(token);

        expect(code, matches(RegExp(r'^[A-Z]+-[A-Z]+-\d{4}$')));
      });

      test('is deterministic for the same token', () {
        final token = tokenManager.generateSecureToken();
        final code1 = tokenManager.generatePairingCode(token);
        final code2 = tokenManager.generatePairingCode(token);

        expect(code1, equals(code2));
      });
    });

    group('verifySessionToken', () {
      test('returns valid for correct device and token', () async {
        final device = _fakePairedDevice(
          deviceId: 'device-1',
          sessionToken: 'aabbccdd' * 8, // 64 hex chars
          isActive: true,
        );

        when(
          () => mockDb.getPairedDevice('device-1'),
        ).thenAnswer((_) async => device);
        when(
          () => mockDb.updateLastConnected('device-1'),
        ).thenAnswer((_) async {});

        final result = await tokenManager.verifySessionToken(
          deviceId: 'device-1',
          token: 'aabbccdd' * 8,
        );

        expect(result, equals(TokenVerificationResult.valid));
        verify(() => mockDb.updateLastConnected('device-1')).called(1);
      });

      test('returns invalid for wrong token', () async {
        final device = _fakePairedDevice(
          deviceId: 'device-1',
          sessionToken: 'aabbccdd' * 8,
          isActive: true,
        );

        when(
          () => mockDb.getPairedDevice('device-1'),
        ).thenAnswer((_) async => device);

        final result = await tokenManager.verifySessionToken(
          deviceId: 'device-1',
          token: '11223344' * 8,
        );

        expect(result, equals(TokenVerificationResult.invalid));
        verifyNever(() => mockDb.updateLastConnected(any()));
      });

      test('returns deviceNotFound for unknown device', () async {
        when(
          () => mockDb.getPairedDevice('unknown'),
        ).thenAnswer((_) async => null);

        final result = await tokenManager.verifySessionToken(
          deviceId: 'unknown',
          token: 'anything',
        );

        expect(result, equals(TokenVerificationResult.deviceNotFound));
      });

      test('returns deviceRevoked for inactive device', () async {
        final device = _fakePairedDevice(
          deviceId: 'device-revoked',
          sessionToken: 'aabbccdd' * 8,
          isActive: false,
        );

        when(
          () => mockDb.getPairedDevice('device-revoked'),
        ).thenAnswer((_) async => device);

        final result = await tokenManager.verifySessionToken(
          deviceId: 'device-revoked',
          token: 'aabbccdd' * 8,
        );

        expect(result, equals(TokenVerificationResult.deviceRevoked));
      });
    });

    group('revokeDevice', () {
      test('delegates to database revokeDevice', () async {
        // revokeDevice now also reads the device row first so it can
        // surface the session token to the revocation listener. Stub the
        // read with a non-null device so the path executes both sides.
        when(() => mockDb.getPairedDevice('dev-1')).thenAnswer(
          (_) async => _fakePairedDevice(
            deviceId: 'dev-1',
            sessionToken: 'aabbccdd' * 8,
            isActive: true,
          ),
        );
        when(() => mockDb.revokeDevice('dev-1')).thenAnswer((_) async {});

        await tokenManager.revokeDevice('dev-1');

        verify(() => mockDb.revokeDevice('dev-1')).called(1);
      });
    });

    group('hashToken', () {
      test('returns consistent SHA-256 hash for same input', () {
        final hash1 = tokenManager.hashToken('my-token');
        final hash2 = tokenManager.hashToken('my-token');

        expect(hash1, equals(hash2));
        // SHA-256 produces a 64-char hex string
        expect(hash1.length, equals(64));
        expect(hash1, matches(RegExp(r'^[0-9a-f]{64}$')));
      });

      test('different tokens produce different hashes', () {
        final hash1 = tokenManager.hashToken('token-a');
        final hash2 = tokenManager.hashToken('token-b');

        expect(hash1, isNot(equals(hash2)));
      });
    });

    group('verifyPairing', () {
      test('returns invalidCode when session not found', () async {
        when(
          () => mockDb.getPairingSession('BAD-0000'),
        ).thenAnswer((_) async => null);

        final result = await tokenManager.verifyPairing(
          pairingCode: 'BAD-0000',
          deviceId: 'dev-1',
          deviceName: 'Test Phone',
        );

        expect(result, equals(PairingResult.invalidCode));
      });

      test('returns codeAlreadyUsed when session is consumed', () async {
        final session = _fakePairingSession(
          pairingCode: 'STAR-1234',
          isUsed: true,
          expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        );

        when(
          () => mockDb.getPairingSession('STAR-1234'),
        ).thenAnswer((_) async => session);

        final result = await tokenManager.verifyPairing(
          pairingCode: 'STAR-1234',
          deviceId: 'dev-1',
          deviceName: 'Test Phone',
        );

        expect(result, equals(PairingResult.codeAlreadyUsed));
      });

      test('returns codeExpired when session is past expiry', () async {
        final session = _fakePairingSession(
          pairingCode: 'MOON-LYRA-5678',
          isUsed: false,
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        );

        when(
          () => mockDb.getPairingSession('MOON-LYRA-5678'),
        ).thenAnswer((_) async => session);

        final result = await tokenManager.verifyPairing(
          pairingCode: 'MOON-LYRA-5678',
          deviceId: 'dev-1',
          deviceName: 'Test Phone',
        );

        expect(result, equals(PairingResult.codeExpired));
      });

      test(
        'reissues a fresh token when pairing an already paired device',
        () async {
          final session = _fakePairingSession(
            pairingCode: 'STAR-LYRA-1234',
            sessionToken: '11223344' * 8,
            isUsed: false,
            expiresAt: DateTime.now().add(const Duration(minutes: 5)),
          );
          final existingDevice = _fakePairedDevice(
            deviceId: 'dev-1',
            sessionToken: 'aabbccdd' * 8,
            isActive: true,
          );

          when(
            () => mockDb.getPairingSession('STAR-LYRA-1234'),
          ).thenAnswer((_) async => session);
          when(
            () => mockDb.getPairedDevice('dev-1'),
          ).thenAnswer((_) async => existingDevice);
          when(
            () => mockDb.markPairingSessionUsed('STAR-LYRA-1234'),
          ).thenAnswer((_) async {});
          when(
            () => mockDb.deletePairedDevice('dev-1'),
          ).thenAnswer((_) async {});
          when(
            () => mockDb.addPairedDevice(
              deviceId: 'dev-1',
              deviceName: 'Test Phone',
              sessionToken: '11223344' * 8,
              deviceType: 'mobile',
              expiresAt: any(named: 'expiresAt'),
              authGrantSpec: 'camera:control,mount:view',
            ),
          ).thenAnswer((_) async {});
          when(
            () => mockDb.deleteUsedPairingSessions(),
          ).thenAnswer((_) async {});

          final result = await tokenManager.completePairing(
            pairingCode: 'star-lyra-1234',
            deviceId: 'dev-1',
            deviceName: 'Test Phone',
            authGrantSpec: 'camera:control,mount:view',
          );

          expect(result.result, equals(PairingResult.deviceAlreadyPaired));
          expect(result.sessionToken, equals('11223344' * 8));
          verify(() => mockDb.deletePairedDevice('dev-1')).called(1);
          verify(
            () => mockDb.addPairedDevice(
              deviceId: 'dev-1',
              deviceName: 'Test Phone',
              sessionToken: '11223344' * 8,
              deviceType: 'mobile',
              expiresAt: any(named: 'expiresAt'),
              authGrantSpec: 'camera:control,mount:view',
            ),
          ).called(1);
        },
      );
    });

    group('verifySessionToken (expiry)', () {
      test(
        'returns expired when device token is past its expires_at',
        () async {
          final past = DateTime.now().subtract(const Duration(minutes: 1));
          final device = _fakePairedDevice(
            deviceId: 'device-expired',
            sessionToken: 'aabbccdd' * 8,
            isActive: true,
            expiresAt: past,
          );

          when(
            () => mockDb.getPairedDevice('device-expired'),
          ).thenAnswer((_) async => device);

          final result = await tokenManager.verifySessionToken(
            deviceId: 'device-expired',
            token: 'aabbccdd' * 8,
          );

          expect(result, equals(TokenVerificationResult.expired));
          // No DB write should have happened — expired tokens must not bump
          // last_connected_at because they cannot be honoured.
          verifyNever(() => mockDb.updateLastConnected(any()));
        },
      );

      test('returns valid when expires_at is in the future', () async {
        final future = DateTime.now().add(const Duration(hours: 1));
        final device = _fakePairedDevice(
          deviceId: 'device-unexpired',
          sessionToken: 'aabbccdd' * 8,
          isActive: true,
          expiresAt: future,
        );

        when(
          () => mockDb.getPairedDevice('device-unexpired'),
        ).thenAnswer((_) async => device);
        when(
          () => mockDb.updateLastConnected('device-unexpired'),
        ).thenAnswer((_) async {});

        final result = await tokenManager.verifySessionToken(
          deviceId: 'device-unexpired',
          token: 'aabbccdd' * 8,
        );

        expect(result, equals(TokenVerificationResult.valid));
      });

      test('treats null expires_at as no expiry (backward compat)', () async {
        final device = _fakePairedDevice(
          deviceId: 'device-legacy',
          sessionToken: 'aabbccdd' * 8,
          isActive: true,
          expiresAt: null,
        );

        when(
          () => mockDb.getPairedDevice('device-legacy'),
        ).thenAnswer((_) async => device);
        when(
          () => mockDb.updateLastConnected('device-legacy'),
        ).thenAnswer((_) async {});

        final result = await tokenManager.verifySessionToken(
          deviceId: 'device-legacy',
          token: 'aabbccdd' * 8,
        );

        expect(result, equals(TokenVerificationResult.valid));
      });

      test('expired path invokes the revocation listener', () async {
        final past = DateTime.now().subtract(const Duration(minutes: 1));
        final device = _fakePairedDevice(
          deviceId: 'device-expired-listener',
          sessionToken: 'eeeeeeee' * 8,
          isActive: true,
          expiresAt: past,
        );

        when(
          () => mockDb.getPairedDevice('device-expired-listener'),
        ).thenAnswer((_) async => device);

        String? evicted;
        tokenManager.setRevocationListener((token) => evicted = token);

        final result = await tokenManager.verifySessionToken(
          deviceId: 'device-expired-listener',
          token: 'eeeeeeee' * 8,
        );

        expect(result, equals(TokenVerificationResult.expired));
        expect(evicted, equals('eeeeeeee' * 8));
      });
    });

    group('revokeDevice (propagation)', () {
      test('invokes the revocation listener with the session token', () async {
        final device = _fakePairedDevice(
          deviceId: 'dev-revoked',
          sessionToken: 'ffffffff' * 8,
          isActive: true,
        );

        when(
          () => mockDb.getPairedDevice('dev-revoked'),
        ).thenAnswer((_) async => device);
        when(() => mockDb.revokeDevice('dev-revoked')).thenAnswer((_) async {});

        String? evicted;
        tokenManager.setRevocationListener((token) => evicted = token);

        await tokenManager.revokeDevice('dev-revoked');

        expect(evicted, equals('ffffffff' * 8));
        verify(() => mockDb.revokeDevice('dev-revoked')).called(1);
      });

      test('a separate GUI manager notifies the host manager cache', () async {
        final device = _fakePairedDevice(
          deviceId: 'dev-gui-revoked',
          sessionToken: 'abababab' * 8,
          isActive: true,
        );
        when(
          () => mockDb.getPairedDevice('dev-gui-revoked'),
        ).thenAnswer((_) async => device);
        when(
          () => mockDb.revokeDevice('dev-gui-revoked'),
        ).thenAnswer((_) async {});

        final hostManager = TokenManager(mockDb);
        addTearDown(() => hostManager.setRevocationListener(null));
        String? evicted;
        hostManager.setRevocationListener((token) => evicted = token);

        // The GUI owns a distinct TokenManager/Drift connection in production.
        // Revoking there must still invalidate the embedded server's cache now,
        // rather than leaving the bearer usable until the 60-second sweep.
        await tokenManager.revokeDevice('dev-gui-revoked');

        expect(evicted, device.sessionToken);
      });

      test('is a no-op for an unknown device id (no listener call)', () async {
        when(
          () => mockDb.getPairedDevice('nope'),
        ).thenAnswer((_) async => null);
        when(() => mockDb.revokeDevice('nope')).thenAnswer((_) async {});

        var called = false;
        tokenManager.setRevocationListener((_) => called = true);

        await tokenManager.revokeDevice('nope');

        expect(called, isFalse);
      });
    });

    group('purgeExpiredAndRevokedSessions', () {
      test(
        'separates expired and revoked rows and notifies listener',
        () async {
          final past = DateTime.now().subtract(const Duration(minutes: 1));
          final expiredDevice = _fakePairedDevice(
            deviceId: 'dev-expired',
            sessionToken: 'expiredtok' * 6 + 'abcd',
            isActive: true,
            expiresAt: past,
          );
          final revokedDevice = _fakePairedDevice(
            deviceId: 'dev-revoked-sweep',
            sessionToken: 'revokedtok' * 6 + 'abcd',
            isActive: false,
            expiresAt: null,
          );

          when(
            () => mockDb.getExpiredOrRevokedDevices(any()),
          ).thenAnswer((_) async => [expiredDevice, revokedDevice]);
          when(
            () => mockDb.deleteExpiredPairedDevices(any()),
          ).thenAnswer((_) async {});

          final evicted = <String>[];
          tokenManager.setRevocationListener(evicted.add);

          final result = await tokenManager.purgeExpiredAndRevokedSessions();

          expect(result.expiredTokens, equals([expiredDevice.sessionToken]));
          expect(result.revokedTokens, equals([revokedDevice.sessionToken]));
          expect(
            evicted,
            containsAll([
              expiredDevice.sessionToken,
              revokedDevice.sessionToken,
            ]),
          );
          // Expired rows must be hard-deleted; revoked rows retained for audit.
          verify(() => mockDb.deleteExpiredPairedDevices(any())).called(1);
        },
      );

      test('no-op when nothing matches', () async {
        when(
          () => mockDb.getExpiredOrRevokedDevices(any()),
        ).thenAnswer((_) async => []);

        final result = await tokenManager.purgeExpiredAndRevokedSessions();

        expect(result.isEmpty, isTrue);
        verifyNever(() => mockDb.deleteExpiredPairedDevices(any()));
      });
    });
  });
}

/// Creates a fake [PairedDevice] with the given properties.
/// PairedDevice is a Drift-generated data class, so we construct it directly.
PairedDevice _fakePairedDevice({
  required String deviceId,
  required String sessionToken,
  required bool isActive,
  DateTime? expiresAt,
}) {
  return PairedDevice(
    deviceId: deviceId,
    deviceName: 'Test Device',
    sessionToken: sessionToken,
    pairedAt: DateTime(2025, 1, 1),
    lastConnectedAt: null,
    deviceType: 'mobile',
    isActive: isActive,
    expiresAt: expiresAt,
    authGrantSpec: 'control',
  );
}

/// Creates a fake [PairingSession] with the given properties.
PairingSession _fakePairingSession({
  required String pairingCode,
  required bool isUsed,
  required DateTime expiresAt,
  String sessionToken = '',
}) {
  return PairingSession(
    id: 1,
    pairingCode: pairingCode,
    sessionToken: sessionToken.isEmpty ? 'aabbccdd' * 8 : sessionToken,
    createdAt: DateTime(2025, 1, 1),
    expiresAt: expiresAt,
    isUsed: isUsed,
  );
}

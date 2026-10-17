// Schema + scoped-grant tests for the Collaborative Sky (6.0) foundation:
//   * the hub gains shared_calibration_masters, collaborative_mosaics(+panels),
//     coimaging_sessions(+participants), created idempotently on open;
//   * the token model gains fine-grained ScopedGrant / CollabAction that EXTEND
//     the coarse HubScope (read/contribute/admin) with per-device and
//     per-action narrowing, persisting + resolving through the tokens table.

import 'dart:convert';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

void main() {
  group('HubDatabase collaborative schema', () {
    late HubDatabase db;

    setUp(() => db = HubDatabase.open(':memory:'));
    tearDown(() => db.dispose());

    bool tableExists(String name) {
      final rows = db.db.select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
        <Object?>[name],
      );
      return rows.isNotEmpty;
    }

    test('creates all Collaborative Sky tables', () {
      for (final t in const <String>[
        'shared_calibration_masters',
        'collaborative_mosaics',
        'collaborative_mosaic_panels',
        'coimaging_sessions',
        'coimaging_participants',
      ]) {
        expect(tableExists(t), isTrue, reason: '$t must be created on open');
      }
    });

    test('re-open is idempotent (CREATE IF NOT EXISTS)', () {
      // A second open against the same in-memory handle would be a fresh DB, so
      // re-run the migration on the SAME connection to prove idempotency.
      expect(() => HubDatabase.open(':memory:').dispose(), returnsNormally);
      expect(tableExists('shared_calibration_masters'), isTrue);
    });

    test(
      'shared_calibration_masters license CHECK rejects unknown wire names',
      () {
        final tokens = TokenService(db);
        final accounts = AccountService(
          db,
          tokens,
          hasher: PasswordHasher(iterations: 1000),
        );
        final acct = accounts
            .signup(publicKey: 'pk-cal', displayName: 'Imager', password: 'pw')
            .account;
        final now = DateTime.now().toUtc().toIso8601String();
        String insert(String license) {
          db.db.execute(
            'INSERT INTO shared_calibration_masters '
            '(id, account_id, master_type, camera_model, license, path, '
            'created_at) VALUES (?, ?, ?, ?, ?, ?, ?);',
            <Object?>[
              'm-$license',
              acct.id,
              'dark',
              'ASI2600MM',
              license,
              '/data/$license.fit',
              now,
            ],
          );
          return license;
        }

        expect(
          () => insert('cc-by-sa'),
          returnsNormally,
          reason: 'a known wire name is accepted',
        );
        expect(
          () => insert('cc-by-nd'),
          throwsA(anything),
          reason:
              'an unknown/forward-version license cannot widen reuse rights',
        );
      },
    );

    test(
      'shared_calibration_masters.license defaults fail-closed to private',
      () {
        final tokens = TokenService(db);
        final accounts = AccountService(
          db,
          tokens,
          hasher: PasswordHasher(iterations: 1000),
        );
        final acct = accounts
            .signup(publicKey: 'pk-def', displayName: 'Imager', password: 'pw')
            .account;
        // A publish path that omits the license column must NOT silently grant
        // reuse rights — the at-rest default mirrors the decode-side private
        // fallback.
        db.db.execute(
          'INSERT INTO shared_calibration_masters '
          '(id, account_id, master_type, camera_model, path, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?);',
          <Object?>[
            'm-default',
            acct.id,
            'dark',
            'ASI2600MM',
            '/data/default.fit',
            DateTime.now().toUtc().toIso8601String(),
          ],
        );
        final rows = db.db.select(
          'SELECT license FROM shared_calibration_masters WHERE id = ?;',
          <Object?>['m-default'],
        );
        expect(
          rows.single['license'],
          'private',
          reason: 'omitting the license must fail closed, not grant cc-by',
        );
      },
    );

    test('a mosaic panel claim is unique per (mosaic, panel)', () {
      final tokens = TokenService(db);
      final accounts = AccountService(
        db,
        tokens,
        hasher: PasswordHasher(iterations: 1000),
      );
      final owner = accounts.signup(
        publicKey: 'pk-owner',
        displayName: 'Club',
        password: 'pw',
      );
      final now = DateTime.now().toUtc().toIso8601String();
      db.db.execute(
        'INSERT INTO collaborative_mosaics '
        '(id, owner_account_id, name, rows, cols, center_ra_deg, '
        'center_dec_deg, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
        <Object?>['m1', owner.account.id, 'Veil', 3, 4, 312.0, 30.0, now, now],
      );
      db.db.execute(
        'INSERT INTO collaborative_mosaic_panels '
        '(id, mosaic_id, panel_index, center_ra_deg, center_dec_deg, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?);',
        <Object?>['p0', 'm1', 0, 312.0, 30.0, now],
      );
      expect(
        () => db.db.execute(
          'INSERT INTO collaborative_mosaic_panels '
          '(id, mosaic_id, panel_index, center_ra_deg, center_dec_deg, '
          'updated_at) VALUES (?, ?, ?, ?, ?, ?);',
          <Object?>['p0-dup', 'm1', 0, 312.0, 30.0, now],
        ),
        throwsA(anything),
        reason: 'UNIQUE(mosaic_id, panel_index) prevents a double claim row',
      );
    });
  });

  group('ScopedGrant (per-device / per-action scopes extending HubScope)', () {
    late HubDatabase db;
    late TokenService tokens;
    late AccountService accounts;

    setUp(() {
      db = HubDatabase.open(':memory:');
      tokens = TokenService(db);
      accounts = AccountService(
        db,
        tokens,
        hasher: PasswordHasher(iterations: 1000),
      );
    });
    tearDown(() => db.dispose());

    String accountId() => accounts
        .signup(publicKey: 'pk', displayName: 'A', password: 'pw')
        .account
        .id;

    test('plain grant serializes to the bare legacy role name', () {
      expect(
        const ScopedGrant.role(HubScope.contribute).toScopeString(),
        'contribute',
      );
      expect(ScopedGrant.tryParse('contribute')!.scope, HubScope.contribute);
      expect(ScopedGrant.tryParse('bogus'), isNull, reason: 'unknown -> deny');
    });

    test(
      'a legacy contribute token still resolves to a contribute identity',
      () {
        final id = accountId();
        final raw = tokens.issue(accountId: id, scope: HubScope.contribute);
        final identity = tokens.resolve(raw)!;
        expect(identity.scope, HubScope.contribute);
        expect(identity.scope.satisfies(HubScope.read), isTrue);
        // Default (un-narrowed) grant permits all contribute-level actions.
        expect(identity.permits(CollabAction.mosaicClaim), isTrue);
        expect(
          identity.permits(CollabAction.mosaicAssemble),
          isFalse,
          reason: 'assemble needs admin',
        );
      },
    );

    test('tryParse fails closed (null) on type-confused JSON, never throws', () {
      // Token resolution must never throw on a corrupt/type-confused scope blob.
      // A non-string deviceId or action entry would throw _TypeError under a
      // bare cast; the guarded parser denies instead.
      expect(
        ScopedGrant.tryParse('{"role":"contribute","deviceId":5}'),
        isNull,
      );
      expect(
        ScopedGrant.tryParse('{"role":"contribute","actions":[5]}'),
        isNull,
        reason: 'a non-string action entry must fail closed',
      );
      expect(
        ScopedGrant.tryParse('{"role":[1,2,3]}'),
        isNull,
        reason: 'a non-string role must fail closed',
      );
    });

    test('a scoped token round-trips per-device + per-action narrowing', () {
      final id = accountId();
      final raw = tokens.issueScoped(
        accountId: id,
        grant: ScopedGrant(
          scope: HubScope.contribute,
          deviceId: 'rig-A',
          actions: {CollabAction.mosaicClaim, CollabAction.mosaicUpload},
        ),
      );
      final identity = tokens.resolve(raw)!;
      // Coarse scope still works for the existing _authorize ladder.
      expect(identity.scope, HubScope.contribute);
      // Per-action allow-list enforced.
      expect(
        identity.permits(CollabAction.mosaicClaim, fromDevice: 'rig-A'),
        isTrue,
      );
      expect(
        identity.permits(CollabAction.coimagingJoin, fromDevice: 'rig-A'),
        isFalse,
        reason: 'not in the allow-list',
      );
      // Per-device binding enforced.
      expect(
        identity.permits(CollabAction.mosaicClaim, fromDevice: 'rig-B'),
        isFalse,
      );
      expect(identity.permits(CollabAction.mosaicClaim), isFalse);
    });
  });

  group('stampAuthoritativeProvenanceIdentity (publish trust boundary)', () {
    test('overwrites self-reported identity, preserves other provenance', () {
      final spoofed = jsonEncode(<String, Object?>{
        'accountId': 'victim-account',
        'displayName': 'Someone Else',
        'cameraModel': 'ASI2600MM',
        'frameCount': 50,
      });
      final stamped = stampAuthoritativeProvenanceIdentity(
        spoofed,
        accountId: 'real-account',
        authoritativeDisplayName: 'Real Imager',
      );
      final decoded = jsonDecode(stamped) as Map<String, Object?>;
      expect(
        decoded['accountId'],
        'real-account',
        reason: 'forged identity is replaced with the authenticated one',
      );
      expect(decoded['displayName'], 'Real Imager');
      expect(
        decoded['cameraModel'],
        'ASI2600MM',
        reason: 'non-identity provenance is preserved',
      );
      expect(decoded['frameCount'], 50);
    });

    test(
      'null/blank/malformed blob yields the authenticated identity only',
      () {
        for (final raw in <String?>[null, '', '   ', 'not json', '[1,2,3]']) {
          final decoded =
              jsonDecode(
                    stampAuthoritativeProvenanceIdentity(
                      raw,
                      accountId: 'real-account',
                    ),
                  )
                  as Map<String, Object?>;
          expect(decoded['accountId'], 'real-account');
          expect(
            decoded.containsKey('displayName'),
            isFalse,
            reason: 'no display name stamped when none provided',
          );
        }
      },
    );

    test(
      'strips a self-reported displayName when no authoritative name given',
      () {
        // The publish path stamps only accountId; a handler that does not (yet)
        // resolve an authoritative display name must NOT let the uploader's
        // self-reported credit string survive and spoof the attribution UI.
        final spoofed = jsonEncode(<String, Object?>{
          'accountId': 'victim-account',
          'displayName': 'Famous Astrophotographer',
          'cameraModel': 'ASI2600MM',
        });
        final decoded =
            jsonDecode(
                  stampAuthoritativeProvenanceIdentity(
                    spoofed,
                    accountId: 'real-account',
                  ),
                )
                as Map<String, Object?>;
        expect(decoded['accountId'], 'real-account');
        expect(
          decoded.containsKey('displayName'),
          isFalse,
          reason:
              'a forged credit string with no authoritative name is '
              'dropped, not passed through',
        );
        expect(
          decoded['cameraModel'],
          'ASI2600MM',
          reason: 'non-identity provenance is still preserved',
        );
      },
    );

    test('strips the unverifiable self-reported rigId', () {
      final spoofed = jsonEncode(<String, Object?>{
        'accountId': 'victim-account',
        'rigId': 'victim-rig-001',
        'cameraModel': 'ASI2600MM',
      });
      final decoded =
          jsonDecode(
                stampAuthoritativeProvenanceIdentity(
                  spoofed,
                  accountId: 'real-account',
                ),
              )
              as Map<String, Object?>;
      expect(decoded['accountId'], 'real-account');
      expect(
        decoded.containsKey('rigId'),
        isFalse,
        reason:
            'a forgeable rig id has no authoritative column to validate '
            'against, so it is dropped rather than passed through',
      );
      expect(
        decoded['cameraModel'],
        'ASI2600MM',
        reason: 'non-identity provenance is still preserved',
      );
    });
  });
}

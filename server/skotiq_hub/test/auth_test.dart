import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

void main() {
  group('PasswordHasher', () {
    // Low iteration count keeps the test fast; production uses the default.
    final hasher = PasswordHasher(iterations: 1000);

    test('verifies a correct password and rejects a wrong one', () {
      final stored = hasher.hash('correct horse battery staple');
      expect(hasher.verify('correct horse battery staple', stored), isTrue);
      expect(hasher.verify('Tr0ub4dor&3', stored), isFalse);
    });

    test('two hashes of the same password differ (random salt)', () {
      final a = hasher.hash('same');
      final b = hasher.hash('same');
      expect(a, isNot(equals(b)));
      expect(hasher.verify('same', a), isTrue);
      expect(hasher.verify('same', b), isTrue);
    });

    test('malformed stored value never authenticates', () {
      expect(hasher.verify('x', 'not-a-real-hash'), isFalse);
      expect(hasher.verify('x', r'pbkdf2-sha256$abc$def'), isFalse);
      expect(hasher.verify('x', ''), isFalse);
    });
  });

  group('TokenService + AccountService', () {
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

    test('signup issues a resolvable contribute token', () {
      final result = accounts.signup(
        publicKey: 'pk-1',
        displayName: 'Alice',
        password: 'pw',
      );
      expect(result.account.trust, AccountService.defaultTrust);
      final identity = tokens.resolve(result.bearerToken);
      expect(identity, isNotNull);
      expect(identity!.accountId, result.account.id);
      expect(identity.scope, HubScope.contribute);
    });

    test('duplicate public key conflicts', () {
      accounts.signup(publicKey: 'pk-1', displayName: 'Alice');
      expect(
        () => accounts.signup(publicKey: 'pk-1', displayName: 'Bob'),
        throwsA(isA<AccountConflict>()),
      );
    });

    test('login with right password issues a token, wrong returns null', () {
      accounts.signup(publicKey: 'pk-1', displayName: 'Alice', password: 'pw');
      expect(accounts.login(publicKey: 'pk-1', password: 'pw'), isNotNull);
      expect(accounts.login(publicKey: 'pk-1', password: 'nope'), isNull);
      expect(accounts.login(publicKey: 'pk-x', password: 'pw'), isNull);
    });

    test('admin scope satisfies lower scopes', () {
      expect(HubScope.admin.satisfies(HubScope.read), isTrue);
      expect(HubScope.admin.satisfies(HubScope.contribute), isTrue);
      expect(HubScope.contribute.satisfies(HubScope.admin), isFalse);
      expect(HubScope.read.satisfies(HubScope.contribute), isFalse);
    });

    test('unknown token resolves to null', () {
      expect(tokens.resolve('deadbeef'), isNull);
    });

    test('expired token is purged on resolve', () {
      final result = accounts.signup(publicKey: 'pk', displayName: 'A');
      // Issue an already-expired token directly.
      final expired = tokens.issue(
        accountId: result.account.id,
        scope: HubScope.read,
        lifetime: const Duration(milliseconds: -1),
      );
      expect(tokens.resolve(expired), isNull);
    });
  });

  group('LoginThrottle (per-account lockout)', () {
    test('locks an account after maxFailures within the window', () {
      final throttle = LoginThrottle(
        maxFailures: 3,
        window: const Duration(minutes: 15),
        lockout: const Duration(minutes: 15),
      );
      final t0 = DateTime(2026, 6, 20, 22);
      expect(throttle.isLocked('pk', now: t0), isFalse);
      expect(throttle.recordFailure('pk', now: t0), isFalse);
      expect(throttle.recordFailure('pk', now: t0), isFalse);
      // The third failure trips the lock.
      expect(throttle.recordFailure('pk', now: t0), isTrue);
      expect(throttle.isLocked('pk', now: t0), isTrue);
      expect(throttle.retryAfterSeconds('pk', now: t0), greaterThan(0));
    });

    test('lockout expires after the lockout duration', () {
      final throttle = LoginThrottle(
        maxFailures: 2,
        lockout: const Duration(minutes: 10),
        window: const Duration(minutes: 10),
      );
      final t0 = DateTime(2026, 6, 20, 22);
      throttle.recordFailure('pk', now: t0);
      throttle.recordFailure('pk', now: t0);
      expect(throttle.isLocked('pk', now: t0), isTrue);
      final later = t0.add(const Duration(minutes: 11));
      expect(throttle.isLocked('pk', now: later), isFalse);
    });

    test('a success clears the failure counter', () {
      final throttle = LoginThrottle(maxFailures: 3);
      final t0 = DateTime(2026, 6, 20, 22);
      throttle.recordFailure('pk', now: t0);
      throttle.recordFailure('pk', now: t0);
      throttle.recordSuccess('pk');
      // Two fresh failures should not yet lock (counter was reset).
      expect(throttle.recordFailure('pk', now: t0), isFalse);
      expect(throttle.recordFailure('pk', now: t0), isFalse);
      expect(throttle.isLocked('pk', now: t0), isFalse);
    });

    test('lockout is per-account, not shared across accounts', () {
      final throttle = LoginThrottle(maxFailures: 2);
      final t0 = DateTime(2026, 6, 20, 22);
      throttle.recordFailure('victim', now: t0);
      throttle.recordFailure('victim', now: t0);
      expect(throttle.isLocked('victim', now: t0), isTrue);
      // A different account is unaffected — the lock does not bleed across keys.
      expect(throttle.isLocked('other', now: t0), isFalse);
    });
  });

  group('secret policy', () {
    test('rejects known placeholders and short/low-variety secrets', () {
      expect(secretWeakness('change-me'), isNotNull);
      expect(secretWeakness('CHANGE-ME'), isNotNull); // case-insensitive
      expect(secretWeakness('secret'), isNotNull);
      expect(secretWeakness('short'), isNotNull); // too short
      expect(
        secretWeakness('aaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
        isNotNull,
      ); // variety
      expect(secretWeakness(''), isNotNull);
    });

    test('accepts a high-entropy secret', () {
      expect(secretWeakness('skhub-3f9a2b7c1d8e4f06a5b9c2d1e0f3a4b5'), isNull);
      expect(secretWeakness('correct horse battery staple 42!!'), isNull);
    });
  });

  group('ScopedGrant.tryParse (fail-closed)', () {
    test('a bare legacy role name parses to a plain whole-role grant', () {
      final g = ScopedGrant.tryParse('contribute');
      expect(g, isNotNull);
      expect(g!.scope, HubScope.contribute);
      expect(g.deviceId, isNull);
      expect(g.actions, isNull);
      expect(g.resourceType, isNull);
      // A plain role round-trips back to the bare wire form (no JSON).
      expect(g.toScopeString(), 'contribute');
    });

    test('an unknown bare role fails closed to null', () {
      expect(ScopedGrant.tryParse('superuser'), isNull);
      expect(ScopedGrant.tryParse(''), isNull);
    });

    test('a JSON narrowed grant decodes device + action + resource binding', () {
      final json =
          '{"role":"contribute","deviceId":"rig-7","actions":["mosaic.upload"],'
          '"resourceType":"mosaic","resourceId":"42"}';
      final g = ScopedGrant.tryParse(json);
      expect(g, isNotNull);
      expect(g!.scope, HubScope.contribute);
      expect(g.deviceId, 'rig-7');
      expect(g.actions, {CollabAction.mosaicUpload});
      expect(g.resourceType, 'mosaic');
      expect(g.resourceId, '42');
      expect(g.isResourceBound, isTrue);
    });

    test('a JSON grant with an unknown base role fails closed to null', () {
      expect(ScopedGrant.tryParse('{"role":"superuser"}'), isNull);
    });

    test('a type-confused / corrupt scope value fails closed to null', () {
      // A non-string role/deviceId must not throw a _TypeError — it denies.
      expect(ScopedGrant.tryParse('{"role":123}'), isNull);
      expect(ScopedGrant.tryParse('{"role":["contribute"]}'), isNull);
      expect(ScopedGrant.tryParse('{not json'), isNull);
    });

    test('round-trips a narrowed grant through toScopeString', () {
      const g = ScopedGrant(
        scope: HubScope.contribute,
        deviceId: 'rig-1',
        actions: {CollabAction.mosaicClaim},
        resourceType: 'mosaic',
        resourceId: '9',
      );
      final reparsed = ScopedGrant.tryParse(g.toScopeString())!;
      expect(reparsed.scope, HubScope.contribute);
      expect(reparsed.deviceId, 'rig-1');
      expect(reparsed.actions, {CollabAction.mosaicClaim});
      expect(reparsed.resourceType, 'mosaic');
      expect(reparsed.resourceId, '9');
    });
  });

  group('ScopedGrant.permits (device / action / resource matrix)', () {
    test('a plain role permits every action its scope satisfies', () {
      const g = ScopedGrant.role(HubScope.contribute);
      expect(g.permits(CollabAction.mosaicUpload), isTrue);
      expect(g.permits(CollabAction.calibrationDownload), isTrue);
      // contribute cannot satisfy an admin-min action.
      expect(g.permits(CollabAction.moderate), isFalse);
      expect(g.permits(CollabAction.mosaicAssemble), isFalse);
    });

    test('an action allow-list denies an action not on the list', () {
      const g = ScopedGrant(
        scope: HubScope.contribute,
        actions: {CollabAction.mosaicUpload},
      );
      expect(g.permits(CollabAction.mosaicUpload), isTrue);
      // The exact over-broad authority the spec set out to fix: a contribute
      // role no longer permits EVERY contribute action.
      expect(g.permits(CollabAction.retract), isFalse);
      expect(g.permits(CollabAction.coimagingContribute), isFalse);
    });

    test('a device binding denies a request from another device', () {
      const g = ScopedGrant(scope: HubScope.contribute, deviceId: 'rig-1');
      expect(g.permits(CollabAction.mosaicUpload, fromDevice: 'rig-1'), isTrue);
      expect(
        g.permits(CollabAction.mosaicUpload, fromDevice: 'rig-2'),
        isFalse,
      );
      expect(g.permits(CollabAction.mosaicUpload), isFalse);
    });

    test('a resource binding denies every other resource', () {
      const g = ScopedGrant(
        scope: HubScope.contribute,
        actions: {CollabAction.mosaicUpload},
        resourceType: 'mosaic',
        resourceId: '42',
      );
      // contribute-to-mosaic-42 permits mosaic 42…
      expect(
        g.permits(
          CollabAction.mosaicUpload,
          onResourceType: 'mosaic',
          onResourceId: '42',
        ),
        isTrue,
      );
      // …but not mosaic 99, and not a global (resource-less) verb.
      expect(
        g.permits(
          CollabAction.mosaicUpload,
          onResourceType: 'mosaic',
          onResourceId: '99',
        ),
        isFalse,
      );
      expect(g.permits(CollabAction.mosaicUpload), isFalse);
    });
  });

  group('stampAuthoritativeProvenanceIdentity (publish trust boundary)', () {
    test('overwrites accountId and strips self-reported displayName/rigId', () {
      const forged =
          '{"accountId":"victim","displayName":"Famous Astrophotographer",'
          '"rigId":"someone-elses-rig","cameraModel":"ASI2600","frameCount":50}';
      final stamped = stampAuthoritativeProvenanceIdentity(
        forged,
        accountId: 'real-account',
      );
      // Non-identity provenance survives; identity is corrected/stripped.
      expect(stamped, contains('"accountId":"real-account"'));
      expect(stamped, isNot(contains('Famous Astrophotographer')));
      expect(stamped, isNot(contains('someone-elses-rig')));
      expect(stamped, contains('ASI2600'));
      expect(stamped, contains('50'));
    });

    test('sets displayName only from the server-authoritative name', () {
      final stamped = stampAuthoritativeProvenanceIdentity(
        '{"displayName":"spoofed"}',
        accountId: 'a',
        authoritativeDisplayName: 'Real Name',
      );
      expect(stamped, contains('"displayName":"Real Name"'));
      expect(stamped, isNot(contains('spoofed')));
    });

    test('a null/malformed blob yields a bare authenticated identity', () {
      final fromNull = stampAuthoritativeProvenanceIdentity(
        null,
        accountId: 'a',
      );
      expect(fromNull, '{"accountId":"a"}');
      final fromGarbage = stampAuthoritativeProvenanceIdentity(
        'not json at all',
        accountId: 'a',
      );
      expect(fromGarbage, '{"accountId":"a"}');
    });
  });

  group('Moderation + suspension (fail-closed token resolution)', () {
    late HubDatabase db;
    late TokenService tokens;
    late AccountService accounts;
    late ModerationService moderation;

    setUp(() {
      db = HubDatabase.open(':memory:');
      tokens = TokenService(db);
      accounts = AccountService(
        db,
        tokens,
        hasher: PasswordHasher(iterations: 1000),
      );
      moderation = ModerationService(db, tokens);
    });

    tearDown(() => db.dispose());

    test('a suspended account cannot log in for a fresh token (H1)', () {
      // The resolve-time kill switch already fails old tokens closed, but a
      // 200 login for a suspended account wrote a false "successful login"
      // audit row and grew the token table (hub-sweep finding H1).
      final signup = accounts.signup(
        publicKey: 'pk-h1',
        displayName: 'H1',
        password: 'pw',
      );
      expect(accounts.login(publicKey: 'pk-h1', password: 'pw'), isNotNull);
      moderation.suspend(targetAccountId: signup.account.id, reason: 'spam');
      expect(accounts.login(publicKey: 'pk-h1', password: 'pw'), isNull);
      moderation.reinstate(targetAccountId: signup.account.id);
      expect(accounts.login(publicKey: 'pk-h1', password: 'pw'), isNotNull);
    });

    test('a suspended account fails closed at resolve, reinstate restores', () {
      final signup = accounts.signup(publicKey: 'pk', displayName: 'A');
      // A fresh token resolves before suspension.
      final live = signup.bearerToken;
      expect(tokens.resolve(live), isNotNull);

      moderation.suspend(targetAccountId: signup.account.id, reason: 'spam');
      // Every token the account holds is now dead (revoked + fail-closed join).
      expect(tokens.resolve(live), isNull);
      expect(moderation.isSuspended(signup.account.id), isTrue);
      // A token minted in a race window would STILL fail closed on resolve.
      final raced = tokens.issue(
        accountId: signup.account.id,
        scope: HubScope.contribute,
      );
      expect(tokens.resolve(raced), isNull);

      moderation.reinstate(targetAccountId: signup.account.id);
      expect(moderation.isSuspended(signup.account.id), isFalse);
      // A NEW token works again after reinstatement.
      final fresh = tokens.issue(
        accountId: signup.account.id,
        scope: HubScope.contribute,
      );
      expect(tokens.resolve(fresh), isNotNull);
    });

    test(
      'checkAbuse auto-suspends past the rejected-contribution threshold',
      () {
        final signup = accounts.signup(publicKey: 'pk', displayName: 'A');
        // Seed rejected contributions directly in the ledger.
        for (var i = 0; i < 25; i++) {
          db.db.execute(
            'INSERT INTO contributions (id, account_id, tile_id, healpix_order, '
            'frames_delta, integration_seconds_delta, trust_applied, status, '
            'delta_path, created_at) '
            "VALUES (?, ?, 1, 9, 1, 1.0, 0.0, 'rejected', '', ?);",
            <Object?>[
              'c$i',
              signup.account.id,
              DateTime.now().toUtc().toIso8601String(),
            ],
          );
        }
        expect(moderation.checkAbuse(signup.account.id), isTrue);
        expect(moderation.isSuspended(signup.account.id), isTrue);
      },
    );

    // Seed [n] rejected contributions for [accountId] timestamped [age] ago.
    var seedSeq = 0;
    void seedRejects(String accountId, int n, {Duration age = Duration.zero}) {
      final at = DateTime.now().toUtc().subtract(age).toIso8601String();
      for (var i = 0; i < n; i++) {
        db.db.execute(
          'INSERT INTO contributions (id, account_id, tile_id, healpix_order, '
          'frames_delta, integration_seconds_delta, trust_applied, status, '
          'delta_path, created_at) '
          "VALUES (?, ?, 1, 9, 1, 1.0, 0.0, 'rejected', '', ?);",
          <Object?>['c-${seedSeq++}', accountId, at],
        );
      }
    }

    test('rejects older than the abuse window do NOT auto-suspend (no lifetime '
        'tally on an honest long-term account)', () {
      final signup = accounts.signup(publicKey: 'pk', displayName: 'A');
      // 25 rejects spread across the account's lifetime but all OUTSIDE the
      // rolling window — an honest flaky rig over many months.
      seedRejects(signup.account.id, 25, age: const Duration(days: 30));
      expect(moderation.checkAbuse(signup.account.id), isFalse);
      expect(moderation.isSuspended(signup.account.id), isFalse);
    });

    test('a reinstate truly un-sticks an account: pre-lift rejects no longer '
        're-suspend it', () {
      final signup = accounts.signup(publicKey: 'pk', displayName: 'A');
      // Cross the threshold with recent rejects → auto-suspended.
      seedRejects(signup.account.id, 25);
      expect(moderation.checkAbuse(signup.account.id), isTrue);
      expect(moderation.isSuspended(signup.account.id), isTrue);
      // An operator lifts the suspension.
      expect(moderation.reinstate(targetAccountId: signup.account.id), isTrue);
      expect(moderation.isSuspended(signup.account.id), isFalse);
      // The 25 pre-lift rejects persist forever, but they predate the reinstate,
      // so the very next rejected contribution must NOT immediately re-suspend
      // the account (the bug: a lifetime count made reinstate futile).
      seedRejects(signup.account.id, 1);
      expect(moderation.checkAbuse(signup.account.id), isFalse);
      expect(moderation.isSuspended(signup.account.id), isFalse);
    });

    test('checkAbuse folds in audit-log denials beyond tile fusion (401/403/'
        '422), not only the contributions ledger', () {
      final signup = accounts.signup(publicKey: 'pk', displayName: 'A');
      final now = DateTime.now().toUtc().toIso8601String();
      // A flood of forbidden/rejected attempts recorded ONLY in the audit log
      // (e.g. co-imaging rejections + forbidden probes) — no contributions rows.
      for (var i = 0; i < 25; i++) {
        db.db.execute(
          'INSERT INTO audit_log (at, account_id, method, path, status, detail) '
          'VALUES (?, ?, ?, ?, ?, ?);',
          <Object?>[now, signup.account.id, 'POST', '/v1/x', 422, 'denied'],
        );
      }
      expect(moderation.checkAbuse(signup.account.id), isTrue);
      expect(moderation.isSuspended(signup.account.id), isTrue);
    });
  });

  group('trust model', () {
    test('no history sits at the prior', () {
      final t = computeTrust(
        meanResidual: null,
        acceptedFrames: 0,
        rejectedFrames: 0,
      );
      expect(t, closeTo(AccountService.defaultTrust, 1e-9));
    });

    test('clean low-residual contributor earns trust up', () {
      final t = computeTrust(
        meanResidual: 0.1,
        acceptedFrames: 500,
        rejectedFrames: 0,
      );
      expect(t, greaterThan(0.9));
    });

    test('a poisoner is driven toward the floor', () {
      final t = computeTrust(
        meanResidual: 8.0,
        acceptedFrames: 0,
        rejectedFrames: 100,
      );
      expect(t, lessThan(0.1));
      expect(t, greaterThanOrEqualTo(0.05));
    });
  });
}

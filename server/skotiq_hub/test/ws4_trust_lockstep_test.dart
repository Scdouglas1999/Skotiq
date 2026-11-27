import 'dart:convert';
import 'dart:io';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

/// Trust / consent / identity guards that need no HTTP harness:
///  * the cross-package wire lock-step: the hub and `skotiq_core` cannot
///    import each other and agree only by identical wire strings, so the hub
///    writes the words it understands to
///    `test_fixtures/wire_words/hub_collaboration.json` and a core test checks
///    the client enums against them.
///  * consent-record revocation stamps `revoked_at` (the retraction leg).
///  * attribution recompute drops a credit that falls to zero (the retraction
///    leg on the attribution ledger).
void main() {
  group('cross-package wire lock-step (skotiq_core <-> hub)', () {
    /// Regenerate with `SKOTIQ_WRITE_FIXTURES=1 dart test
    /// test/ws4_trust_lockstep_test.dart`.
    test('the collaboration words the hub understands are the fixture', () {
      final words = {
        'actions': [for (final a in CollabAction.values) a.wireName]..sort(),
        'licenses': ConsentService.knownLicenses.toList()..sort(),
        'roles': [for (final s in HubScope.values) s.wireName],
      };
      final fixture = File(
        '../../test_fixtures/wire_words/hub_collaboration.json',
      );
      if (Platform.environment.containsKey('SKOTIQ_WRITE_FIXTURES')) {
        fixture.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(words)}\n',
        );
        return;
      }
      expect(
        jsonDecode(fixture.readAsStringSync()),
        words,
        reason:
            'the hub collaboration words changed; regenerate the fixture '
            'and update the client enums in skotiq_core',
      );
    });

    test('the shareable licenses are every known one but private', () {
      expect(ConsentService.shareableLicenses, isNot(contains('private')));
      expect(
        ConsentService.knownLicenses.difference(
          ConsentService.shareableLicenses,
        ),
        equals({'private'}),
      );
    });
  });

  group('consent revocation + attribution recompute (retraction legs)', () {
    late HubDatabase db;
    late ConsentService consent;
    late AttributionService attribution;
    late AccountService accounts;
    late TokenService tokens;

    setUp(() {
      db = HubDatabase.open(':memory:');
      tokens = TokenService(db);
      accounts = AccountService(db, tokens);
      consent = ConsentService(db);
      attribution = AttributionService(db, accounts);
    });

    tearDown(() => db.dispose());

    String makeAccount(String key) =>
        accounts.signup(publicKey: key, displayName: key).account.id;

    test('revoke stamps revoked_at exactly once (idempotent guard)', () {
      final accountId = makeAccount('consent-revoke');
      final id = consent.record(
        accountId: accountId,
        artifactType: 'tile',
        artifactRef: '9:9',
        license: 'cc-by',
      );
      // First revoke stamps revoked_at and reports success.
      expect(consent.revoke(id), isTrue);
      // A second revoke is a no-op: the `revoked_at IS NULL` guard means the row
      // is already stamped, so no row is updated. This is the durable proof that
      // revoked_at was persisted the first time.
      expect(consent.revoke(id), isFalse);
      // A null / unknown id fails closed to false, never throws.
      expect(consent.revoke(null), isFalse);
      expect(consent.revoke('does-not-exist'), isFalse);
    });

    test('recompute drops a credit whose frames fall to zero', () {
      final accountId = makeAccount('attr-recompute');
      attribution.recordAccepted(
        artifactType: 'tile',
        artifactRef: '55:9',
        accountId: accountId,
        frames: 4,
        integrationSeconds: 120,
        license: 'cc-by',
      );
      expect(
        attribution.list(artifactType: 'tile', artifactRef: '55:9'),
        hasLength(1),
      );
      // Retracting the only contribution subtracts its exact frames/integration;
      // the credit falls to zero and is removed entirely so the finished
      // artifact no longer names a contributor whose work was retracted.
      attribution.recompute(
        artifactType: 'tile',
        artifactRef: '55:9',
        accountId: accountId,
        frames: 4,
        integrationSeconds: 120,
      );
      expect(
        attribution.list(artifactType: 'tile', artifactRef: '55:9'),
        isEmpty,
      );
    });

    test('recompute keeps a credit that still has frames after a partial '
        'retraction', () {
      final accountId = makeAccount('attr-partial');
      attribution.recordAccepted(
        artifactType: 'tile',
        artifactRef: '55:9',
        accountId: accountId,
        frames: 10,
        integrationSeconds: 300,
        license: 'cc-by',
      );
      attribution.recompute(
        artifactType: 'tile',
        artifactRef: '55:9',
        accountId: accountId,
        frames: 4,
        integrationSeconds: 120,
      );
      final credits = attribution.list(
        artifactType: 'tile',
        artifactRef: '55:9',
      );
      expect(credits, hasLength(1));
      expect(credits.first['frames'], 6);
      expect(credits.first['integrationSeconds'], 180);
    });
  });
}

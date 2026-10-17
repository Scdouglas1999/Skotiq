import 'dart:io';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

/// Trust / consent / identity guards that need no HTTP harness:
///  * the cross-package wire lock-step: the hub and `skotiq_core` cannot
///    import each other and agree only by identical wire strings, so a rename
///    on one side breaks delegation/consent at runtime with NO compile error.
///    This reads the client enum source and pins it against the typed hub
///    enums.
///  * consent-record revocation stamps `revoked_at` (the retraction leg).
///  * attribution recompute drops a credit that falls to zero (the retraction
///    leg on the attribution ledger).
void main() {
  group('cross-package wire lock-step (skotiq_core <-> hub)', () {
    // The client trust model lives in a sibling package the hub cannot import.
    // Locate its source relative to the repo root regardless of the test cwd
    // (dart test → package dir; melos → repo root).
    File clientModelFile() {
      const rel =
          'packages/skotiq_core/lib/src/models/collaboration/'
          'collaboration_models.dart';
      var dir = Directory.current;
      for (var i = 0; i < 6; i++) {
        final candidate = File('${dir.path}/$rel');
        if (candidate.existsSync()) return candidate;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
      fail(
        'could not locate the client collaboration_models.dart from '
        '${Directory.current.path}; the lock-step guard cannot run',
      );
    }

    /// Extract the wire strings from the enum-constant section of [enumName]
    /// (the block between `enum <name> {` and the first `;` that closes the
    /// constants). Each constant carries its wire name as its first
    /// single-quoted argument, e.g. `mosaicPublish('mosaic.publish')`.
    Set<String> clientWireNames(String source, String enumName) {
      // Strip `//`/`///` line comments first: a doc comment inside the enum
      // block can carry a semicolon (e.g. ContributionLicense's "not shared;
      // private to the contributor"), which would otherwise be mistaken for the
      // `;` that closes the constant list and truncate the block to nothing.
      // Wire names are single-quoted and contain no `//`, so cutting each line
      // at its first `//` never touches a constant.
      source = source
          .split('\n')
          .map((line) {
            final i = line.indexOf('//');
            return i < 0 ? line : line.substring(0, i);
          })
          .join('\n');
      final open = source.indexOf('enum $enumName {');
      expect(
        open,
        greaterThanOrEqualTo(0),
        reason:
            'enum $enumName vanished from the client model — lock-step '
            'guard is stale',
      );
      final semi = source.indexOf(';', open);
      expect(semi, greaterThan(open));
      final block = source.substring(open, semi);
      // Match a constant line: `identifier('wire.name'` — the FIRST quoted arg
      // is the wire name. Skip the `enum X {` header itself.
      final re = RegExp(r"([A-Za-z][A-Za-z0-9]*)\s*\(\s*'([^']+)'");
      return re.allMatches(block).map((m) => m.group(2)!).toSet();
    }

    late String clientSource;
    setUp(() {
      clientSource = clientModelFile().readAsStringSync();
    });

    test('every client CollaborativeAction verb is understood by the hub', () {
      final clientActions = clientWireNames(
        clientSource,
        'CollaborativeAction',
      );
      // Sanity: the guard actually parsed the enum (not an empty regex match).
      expect(
        clientActions,
        contains('mosaic.upload'),
        reason: 'the client action parse produced nothing recognizable',
      );
      final hubActions = CollabAction.values.map((a) => a.wireName).toSet();
      // Every action a client can embed in a scoped-token grant MUST resolve on
      // the hub via CollabAction.fromWire, or delegation silently drops it.
      final missing = clientActions.difference(hubActions);
      expect(
        missing,
        isEmpty,
        reason:
            'client CollaborativeAction verbs the hub does not recognize '
            '(delegation would silently drop these): $missing',
      );
      // Round-trip each through fromWire to prove resolution, not just presence.
      for (final wire in clientActions) {
        expect(
          CollabAction.fromWire(wire),
          isNotNull,
          reason: 'CollabAction.fromWire($wire) failed — wire drift',
        );
      }
    });

    test(
      'the client ContributionLicense set equals the hub known-license set',
      () {
        final clientLicenses = clientWireNames(
          clientSource,
          'ContributionLicense',
        );
        expect(
          clientLicenses,
          equals(ConsentService.knownLicenses),
          reason:
              'license wire drift between skotiq_core '
              'ContributionLicense and hub ConsentService.knownLicenses — the '
              'consent CHECK + client license enum are out of lock-step',
        );
        // And the shareable subset never includes `private` (the "do not share"
        // sentinel), which every share path rejects.
        expect(ConsentService.shareableLicenses, isNot(contains('private')));
        expect(
          ConsentService.knownLicenses.difference(
            ConsentService.shareableLicenses,
          ),
          equals({'private'}),
        );
      },
    );

    test('the client CollaborativeRole names match the hub HubScope names', () {
      final clientRoles = clientWireNames(clientSource, 'CollaborativeRole');
      final hubRoles = HubScope.values.map((s) => s.wireName).toSet();
      expect(clientRoles, equals(hubRoles));
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

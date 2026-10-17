// Unit tests for the shared trust primitives: Provenance,
// ContributionConsent/License, and the scoped-role/permission model. These lock
// the wire round-trip and the permission semantics every collaborative feature
// and the hub's mirrored `ScopedGrant` depend on.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/collaboration/collaboration_models.dart';

void main() {
  group('Provenance', () {
    test('round-trips through JSON string', () {
      const p = Provenance(
        accountId: 'acct-1',
        displayName: 'Alice',
        rigId: 'rig-7',
        cameraModel: 'ASI2600MM',
        frameCount: 50,
        darkCurrent: 0.012,
        sensorWidth: 6248,
        sensorHeight: 4176,
      );
      final back = Provenance.fromJsonString(p.toJsonString());
      expect(back.accountId, 'acct-1');
      expect(back.displayName, 'Alice');
      expect(back.rigId, 'rig-7');
      expect(back.cameraModel, 'ASI2600MM');
      expect(back.frameCount, 50);
      expect(back.darkCurrent, 0.012);
      expect(back.sensorWidth, 6248);
      expect(back.sensorHeight, 4176);
    });

    test('tolerant decode returns empty on null/blank/garbage', () {
      expect(Provenance.fromJsonString(null).accountId, isNull);
      expect(Provenance.fromJsonString('').accountId, isNull);
      expect(Provenance.fromJsonString('not json').accountId, isNull);
    });

    test('tolerant decode does not throw on type-confused fields', () {
      // A type-confused identity field (accountId as a number) would throw
      // _TypeError under a bare cast; the guarded parser yields null instead.
      final p = Provenance.fromJsonString(
        '{"accountId":123,"frameCount":"lots","cameraModel":["a"]}',
      );
      expect(p.accountId, isNull);
      expect(p.cameraModel, isNull);
      expect(p.frameCount, isNull);
    });
  });

  group('ContributionLicense / ContributionConsent', () {
    test('license wire parse + attribution/shareable semantics', () {
      expect(ContributionLicense.fromWire('cc0'), ContributionLicense.cc0);
      expect(
        ContributionLicense.fromWire('unknown'),
        ContributionLicense.private,
        reason:
            'unknown decodes to the most restrictive (non-shareable) '
            'license, never silently broadening reuse rights',
      );
      expect(
        ContributionLicense.fromWire(null),
        ContributionLicense.private,
        reason: 'null decodes fail-closed',
      );
      expect(
        ContributionLicense.fromWire(
          'unknown',
          fallback: ContributionLicense.ccBy,
        ),
        ContributionLicense.ccBy,
        reason: 'an explicit UI default may opt into a permissive fallback',
      );
      expect(ContributionLicense.cc0.requiresAttribution, isFalse);
      expect(ContributionLicense.ccBy.requiresAttribution, isTrue);
      expect(ContributionLicense.private.isShareable, isFalse);
      expect(ContributionLicense.ccBySa.isShareable, isTrue);
    });

    test('consent round-trips and gates sharing on license', () {
      const consent = ContributionConsent(
        license: ContributionLicense.ccBySa,
        shareRawSubframes: true,
        allowDerivatives: false,
        attributionName: 'Bob',
      );
      final back = ContributionConsent.fromJsonString(consent.toJsonString());
      expect(back.license, ContributionLicense.ccBySa);
      expect(back.shareRawSubframes, isTrue);
      expect(back.allowDerivatives, isFalse);
      expect(back.attributionName, 'Bob');
      expect(back.permitsSharing, isTrue);

      const private = ContributionConsent(license: ContributionLicense.private);
      expect(private.permitsSharing, isFalse);
    });

    test('consent decode fails CLOSED on null/blank/malformed', () {
      for (final raw in <String?>[null, '', '   ', 'not json', '[1,2,3]']) {
        final c = ContributionConsent.fromJsonString(raw);
        expect(
          c,
          same(ContributionConsent.denied),
          reason: 'a missing/garbled consent record grants nothing',
        );
        expect(c.permitsSharing, isFalse);
        expect(c.allowDerivatives, isFalse);
        expect(c.allowRedistribution, isFalse);
        expect(c.shareRawSubframes, isFalse);
        expect(c.license, ContributionLicense.private);
      }
    });

    test('consent decode fails CLOSED on type-confused JSON (no throw)', () {
      // A type-confused flag (a string/number where a bool is expected) must
      // decode to the fail-closed `false`, never throw a _TypeError out of the
      // gate. The flags below are all non-bool and must all read false.
      for (final raw in <String>[
        '{"shareRawSubframes":"yes"}',
        '{"license":"cc-by","allowRedistribution":"true"}',
        '{"allowDerivatives":1,"shareRawSubframes":1}',
      ]) {
        final c = ContributionConsent.fromJsonString(raw);
        expect(c.allowDerivatives, isFalse);
        expect(c.allowRedistribution, isFalse);
        expect(c.shareRawSubframes, isFalse);
      }
      // A type-confused (non-string) license decodes to the most-restrictive
      // private default, so nothing may be shared.
      final badLicense = ContributionConsent.fromJsonString('{"license":42}');
      expect(badLicense.license, ContributionLicense.private);
      expect(badLicense.permitsSharing, isFalse);
    });

    test('consent fromJson defaults missing flags to non-permissive', () {
      // A stripped/partial record (only a license, no flags) must not infer
      // derivative/redistribution rights the producer never recorded.
      final c = ContributionConsent.fromJson(<String, dynamic>{
        'license': 'cc-by',
      });
      expect(c.license, ContributionLicense.ccBy);
      expect(c.allowDerivatives, isFalse);
      expect(c.allowRedistribution, isFalse);
      expect(c.shareRawSubframes, isFalse);
    });

    test(
      'interactive constructor default stays permissive (explicit publish)',
      () {
        // The const constructor is the publish-UI default driven by user action.
        const ui = ContributionConsent();
        expect(ui.license, ContributionLicense.ccBy);
        expect(ui.allowDerivatives, isTrue);
        expect(ui.allowRedistribution, isTrue);
      },
    );

    test('license wire set is pinned to the hub CHECK-constraint lock-step set', () {
      // CROSS-PACKAGE GUARD (lock-step with the hub). The hub's SQLite schema
      // hardcodes this exact set in a `CHECK (license IN (...))` on both
      // shared_calibration_masters and consent_records (hub_database.dart).
      // skotiq_hub cannot import this enum, so the coupling is enforced by
      // pinning BOTH sides to the same canonical set: if a ContributionLicense
      // value is added/renamed here this test fails, forcing the matching hub
      // CHECK update — otherwise a publish under the new license would be
      // silently rejected at INSERT time deep in the hub with no compile error.
      // The hub side asserts its CHECK equals the same set
      // (hub_database_upgrade_test.dart).
      expect(
        ContributionLicense.values.map((l) => l.wireName).toSet(),
        equals(<String>{'private', 'cc0', 'cc-by', 'cc-by-sa', 'cc-by-nc'}),
        reason:
            'adding/renaming a license wire name requires updating the '
            "hub's license CHECK constraints in hub_database.dart in lock-step",
      );
    });
  });

  group('CollaborativeRole ladder', () {
    test('admin satisfies contribute satisfies read', () {
      expect(
        CollaborativeRole.admin.satisfies(CollaborativeRole.contribute),
        isTrue,
      );
      expect(
        CollaborativeRole.contribute.satisfies(CollaborativeRole.read),
        isTrue,
      );
      expect(
        CollaborativeRole.read.satisfies(CollaborativeRole.contribute),
        isFalse,
      );
    });
  });

  group('CollaborativePermission', () {
    test('plain role serializes to the bare legacy scope name', () {
      expect(
        CollaborativePermission.role(
          CollaborativeRole.contribute,
        ).toScopeString(),
        'contribute',
      );
    });

    test('plain contribute permits its default actions but not admin ones', () {
      final grant = CollaborativePermission.role(CollaborativeRole.contribute);
      expect(grant.permits(CollaborativeAction.mosaicClaim), isTrue);
      expect(grant.permits(CollaborativeAction.coimagingContribute), isTrue);
      expect(
        grant.permits(CollaborativeAction.mosaicAssemble),
        isFalse,
        reason: 'assemble needs admin',
      );
      expect(grant.permits(CollaborativeAction.moderate), isFalse);
    });

    test(
      'per-action narrowing restricts to the allow-list (still role-capped)',
      () {
        const grant = CollaborativePermission(
          role: CollaborativeRole.contribute,
          actions: {CollaborativeAction.mosaicClaim},
        );
        expect(grant.permits(CollaborativeAction.mosaicClaim), isTrue);
        expect(
          grant.permits(CollaborativeAction.mosaicUpload),
          isFalse,
          reason: 'not in the allow-list',
        );
        // Listing an over-privileged action does not grant it.
        const sneaky = CollaborativePermission(
          role: CollaborativeRole.contribute,
          actions: {CollaborativeAction.mosaicAssemble},
        );
        expect(sneaky.permits(CollaborativeAction.mosaicAssemble), isFalse);
      },
    );

    test('per-device scoping requires the matching device', () {
      const grant = CollaborativePermission(
        role: CollaborativeRole.contribute,
        deviceId: 'rig-A',
      );
      expect(
        grant.permits(CollaborativeAction.mosaicClaim, fromDevice: 'rig-A'),
        isTrue,
      );
      expect(
        grant.permits(CollaborativeAction.mosaicClaim, fromDevice: 'rig-B'),
        isFalse,
      );
      expect(
        grant.permits(CollaborativeAction.mosaicClaim),
        isFalse,
        reason: 'no device presented to a device-bound grant',
      );
    });

    test('scope-string round-trips a narrowed grant as JSON', () {
      const grant = CollaborativePermission(
        role: CollaborativeRole.contribute,
        deviceId: 'rig-A',
        actions: {
          CollaborativeAction.mosaicClaim,
          CollaborativeAction.mosaicUpload,
        },
      );
      final scope = grant.toScopeString();
      expect(scope.startsWith('{'), isTrue);
      final back = CollaborativePermission.fromScopeString(scope);
      expect(back.role, CollaborativeRole.contribute);
      expect(back.deviceId, 'rig-A');
      expect(back.actions, {
        CollaborativeAction.mosaicClaim,
        CollaborativeAction.mosaicUpload,
      });
    });

    test(
      'fromScopeString parses legacy bare role and fails closed on garbage',
      () {
        expect(
          CollaborativePermission.fromScopeString('admin').role,
          CollaborativeRole.admin,
        );
        expect(
          CollaborativePermission.fromScopeString(null).role,
          CollaborativeRole.read,
          reason: 'null fails closed to read',
        );
        expect(
          CollaborativePermission.fromScopeString('{bad json').role,
          CollaborativeRole.read,
        );
      },
    );

    test('fromScopeString fails closed on type-confused JSON (no throw)', () {
      // A non-string role / deviceId / action entry would throw _TypeError
      // under a bare cast; the guarded parser denies to a read-only grant.
      expect(
        CollaborativePermission.fromScopeString('{"role":[1,2,3]}').role,
        CollaborativeRole.read,
      );
      final p = CollaborativePermission.fromScopeString(
        '{"role":"contribute","deviceId":5,"actions":[7]}',
      );
      expect(p.role, CollaborativeRole.contribute);
      expect(p.deviceId, isNull, reason: 'a non-string deviceId is dropped');
      expect(
        p.actions,
        isEmpty,
        reason: 'a non-string action entry is dropped',
      );
    });
  });
}

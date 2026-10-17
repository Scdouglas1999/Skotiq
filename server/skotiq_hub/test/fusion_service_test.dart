import 'dart:io';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late HubDatabase db;
  late TileStore store;
  late TokenService tokens;
  late AccountService accounts;
  late FusionService fusion;

  /// A fusion service whose accepted tile geometry matches the compact test
  /// tiles (the geometry policy is exercised in its own group below; here we
  /// want the merge algebra, so we permit the small sizes the fixtures use).
  FusionService fusionFor({int tilePixels = 8}) {
    return FusionService(
      db: db,
      store: store,
      accounts: accounts,
      expectedTilePixels: tilePixels,
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nshub_fusion_');
    db = HubDatabase.open(':memory:');
    store = TileStore(tmp.path);
    tokens = TokenService(db);
    accounts = AccountService(
      db,
      tokens,
      hasher: PasswordHasher(iterations: 1000),
    );
    // Full-trust accounts so the fusion equals the unweighted co-add.
    fusion = fusionFor();
  });

  tearDown(() {
    db.dispose();
    tmp.deleteSync(recursive: true);
  });

  /// Force an account's trust to exactly [trust] for deterministic assertions.
  void setTrust(String accountId, double trust) {
    db.db.execute('UPDATE accounts SET trust = ? WHERE id = ?;', <Object?>[
      trust,
      accountId,
    ]);
  }

  test('two uploaded contributions fuse to the local co-add of both', () {
    final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
    final bob = accounts.signup(publicKey: 'B', displayName: 'Bob');
    setTrust(alice.account.id, 1.0);
    setTrust(bob.account.id, 1.0);

    // Alice: 2 frames at value 100. Bob: 3 frames at value 200.
    final aliceDelta = TileBuilder.synthetic(
      tileId: 42,
      order: 9,
      value: 100.0,
      frames: 2,
      width: 8,
      height: 8,
      contributor: alice.account.id,
    );
    final bobDelta = TileBuilder.synthetic(
      tileId: 42,
      order: 9,
      value: 200.0,
      frames: 3,
      width: 8,
      height: 8,
      contributor: bob.account.id,
    );

    // Upload both through the fusion service.
    final r1 = fusion.contribute(
      accountId: alice.account.id,
      tileId: 42,
      order: 9,
      deltaBytes: aliceDelta.serialize(),
      framesDelta: 2,
      integrationSecondsDelta: 600.0,
      medianFwhm: 2.0,
    );
    expect(r1.accepted, isTrue);
    final r2 = fusion.contribute(
      accountId: bob.account.id,
      tileId: 42,
      order: 9,
      deltaBytes: bobDelta.serialize(),
      framesDelta: 3,
      integrationSecondsDelta: 900.0,
      medianFwhm: 2.5,
    );
    expect(r2.accepted, isTrue);
    expect(r2.totalFramesAfter, 5);
    expect(r2.contributorsAfter, 2);

    // The server's fused tile.
    final fused = store.load(42, 9)!;
    final fusedMean = fused.finalizeMean();

    // The local co-add of the same two deltas (the keystone's merge_tiles).
    final local = mergeSigned(aliceDelta.clone(), bobDelta, 1.0, 1.0);
    final localMean = local.finalizeMean();

    expect(fusedMean.length, localMean.length);
    for (var i = 0; i < fusedMean.length; i++) {
      // Both equal the weighted mean (2*100 + 3*200)/5 = 160.
      expect(fusedMean[i], closeTo(localMean[i], 1e-9));
      expect(fusedMean[i], closeTo(160.0, 1e-9));
    }
    // And the running vectors themselves match (bit-parity of the algebra).
    for (var i = 0; i < fused.slotCount; i++) {
      expect(fused.sumW[i], closeTo(local.sumW[i], 1e-12));
      expect(fused.sumWx[i], closeTo(local.sumWx[i], 1e-12));
      expect(fused.coverage[i], local.coverage[i]);
    }
  });

  test('retraction restores the tile exactly', () {
    final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
    final bob = accounts.signup(publicKey: 'B', displayName: 'Bob');
    setTrust(alice.account.id, 1.0);
    setTrust(bob.account.id, 1.0);

    fusion.contribute(
      accountId: alice.account.id,
      tileId: 1,
      order: 9,
      deltaBytes: TileBuilder.synthetic(
        tileId: 1,
        order: 9,
        value: 100.0,
        frames: 4,
        width: 8,
        height: 8,
        contributor: alice.account.id,
      ).serialize(),
      framesDelta: 4,
      integrationSecondsDelta: 1200.0,
    );
    final beforeBob = store.load(1, 9)!.finalizeMean();

    final bobOutcome = fusion.contribute(
      accountId: bob.account.id,
      tileId: 1,
      order: 9,
      deltaBytes: TileBuilder.synthetic(
        tileId: 1,
        order: 9,
        value: 900.0,
        frames: 1,
        width: 8,
        height: 8,
        contributor: bob.account.id,
      ).serialize(),
      framesDelta: 1,
      integrationSecondsDelta: 300.0,
    );
    expect(bobOutcome.accepted, isTrue);

    final retraction = fusion.retract(
      bobOutcome.contributionId,
      requesterId: bob.account.id,
    );
    expect(retraction.retracted, isTrue);
    expect(retraction.totalFramesAfter, 4);

    final afterRetract = store.load(1, 9)!.finalizeMean();
    for (var i = 0; i < beforeBob.length; i++) {
      expect(afterRetract[i], closeTo(beforeBob[i], 1e-9));
    }
  });

  test('a contributor cannot retract another contributor\'s upload', () {
    final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
    final bob = accounts.signup(publicKey: 'B', displayName: 'Bob');
    final outcome = fusion.contribute(
      accountId: alice.account.id,
      tileId: 1,
      order: 9,
      deltaBytes: TileBuilder.synthetic(
        tileId: 1,
        order: 9,
        value: 1.0,
        frames: 1,
        width: 8,
        height: 8,
        contributor: alice.account.id,
      ).serialize(),
      framesDelta: 1,
      integrationSecondsDelta: 1.0,
    );
    expect(
      () => fusion.retract(outcome.contributionId, requesterId: bob.account.id),
      throwsA(isA<ContributionForbidden>()),
    );
  });

  test('a gross outlier contribution is rejected, not fused', () {
    final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
    final mallory = accounts.signup(publicKey: 'M', displayName: 'Mallory');
    setTrust(alice.account.id, 1.0);
    setTrust(mallory.account.id, 1.0);

    // Establish a clean stack around value 100 with realistic per-pixel scatter.
    final clean = TileBuilder.synthetic(
      tileId: 5,
      order: 9,
      value: 100.0,
      frames: 10,
      width: 8,
      height: 8,
      contributor: alice.account.id,
    );
    // Add a tiny gradient so the base has nonzero robust spread.
    for (var i = 0; i < clean.slotCount; i++) {
      final jitter = (i % 7) - 3.0; // -3..3
      clean.sumWx[i] += clean.sumW[i] * jitter * 0.1;
      clean.sumWx2[i] =
          clean.sumW[i] * (100.0 + jitter * 0.1) * (100.0 + jitter * 0.1);
    }
    fusion.contribute(
      accountId: alice.account.id,
      tileId: 5,
      order: 9,
      deltaBytes: clean.serialize(),
      framesDelta: 10,
      integrationSecondsDelta: 3000.0,
      medianFwhm: 2.0,
    );

    // Mallory uploads a wildly off-scale contribution (value 1e6).
    final poison = TileBuilder.synthetic(
      tileId: 5,
      order: 9,
      value: 1000000.0,
      frames: 1,
      width: 8,
      height: 8,
      contributor: mallory.account.id,
    );
    final outcome = fusion.contribute(
      accountId: mallory.account.id,
      tileId: 5,
      order: 9,
      deltaBytes: poison.serialize(),
      framesDelta: 1,
      integrationSecondsDelta: 300.0,
      medianFwhm: 9.0,
    );
    expect(outcome.accepted, isFalse);
    expect(outcome.verdict.reason, 'outlier-rejected');

    // The stack still reads ~100, never poisoned toward 1e6.
    final mean = store.load(5, 9)!.finalizeMean();
    for (final v in mean) {
      expect(v, lessThan(200.0));
    }
    // Mallory's trust took a hit.
    final updated = accounts.getById(mallory.account.id)!;
    expect(updated.trust, lessThan(1.0));
  });

  test('a NaN-poisoned delta is rejected before it can reach the merge', () {
    final mallory = accounts.signup(publicKey: 'M', displayName: 'Mallory');
    final poison = TileBuilder.synthetic(
      tileId: 7,
      order: 9,
      value: 100.0,
      frames: 1,
      width: 8,
      height: 8,
      contributor: mallory.account.id,
    );
    // Embed a NaN in a slot the attacker leaves uncovered so the quality gate
    // (which only inspects doubly-covered pixels) would never look at it.
    poison.sumWx[3] = double.nan;
    poison.coverage[3] = 0;
    expect(
      () => fusion.contribute(
        accountId: mallory.account.id,
        tileId: 7,
        order: 9,
        deltaBytes: poison.serialize(),
        framesDelta: 1,
        integrationSecondsDelta: 300.0,
      ),
      throwsA(
        isA<TileCodecException>().having((e) => e.code, 'code', 'corrupt'),
      ),
    );
    // Nothing was folded — the tile does not even exist.
    expect(store.load(7, 9), isNull);
  });

  test('forged provenance/contributors are overwritten by server-validated '
      'stats', () {
    final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
    final mallory = accounts.signup(publicKey: 'M', displayName: 'Mallory');
    setTrust(mallory.account.id, 1.0);

    final forged = TileBuilder.synthetic(
      tileId: 11,
      order: 9,
      value: 100.0,
      frames: 1,
      width: 8,
      height: 8,
      contributor: mallory.account.id,
    );
    // Mallory inflates totals and forges Alice into the contributor list.
    final prov = forged.header['provenance']! as Map<String, Object?>;
    prov['total_frames'] = 1000000;
    prov['total_integration_seconds'] = 9.9e9;
    prov['contributors'] = <String>[mallory.account.id, alice.account.id];

    final outcome = fusion.contribute(
      accountId: mallory.account.id,
      tileId: 11,
      order: 9,
      deltaBytes: forged.serialize(),
      framesDelta: 3, // the server-validated truth
      integrationSecondsDelta: 900.0,
    );
    expect(outcome.accepted, isTrue);
    // The fused tile carries the server's stats, not the forged ones, and only
    // the authenticated contributor.
    expect(outcome.totalFramesAfter, 3);
    expect(outcome.integrationSecondsAfter, closeTo(900.0, 1e-9));
    expect(outcome.contributorsAfter, 1);
    final fused = store.load(11, 9)!;
    expect(fused.totalFrames, 3);
    expect(fused.contributors, <String>[mallory.account.id]);
    expect(fused.contributors, isNot(contains(alice.account.id)));
  });

  test('a tile-id mismatch in the body is a 409-mapping conflict', () {
    final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
    expect(
      () => fusion.contribute(
        accountId: alice.account.id,
        tileId: 42,
        order: 9,
        deltaBytes: TileBuilder.synthetic(
          tileId: 99, // wrong id in the body
          order: 9,
          value: 1.0,
          frames: 1,
          width: 8,
          height: 8,
        ).serialize(),
        framesDelta: 1,
        integrationSecondsDelta: 1.0,
      ),
      throwsA(
        isA<TileCodecException>().having(
          (e) => e.code,
          'code',
          'geometryMismatch',
        ),
      ),
    );
  });

  group('untrusted-header geometry gate', () {
    test('a delta whose size != hub tilePixels is rejected (400)', () {
      final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
      // The hub here expects 8x8 tiles; a 16x16 upload would seed an oversized
      // geometry from the untrusted header.
      expect(
        () => fusion.contribute(
          accountId: alice.account.id,
          tileId: 3,
          order: 9,
          deltaBytes: TileBuilder.synthetic(
            tileId: 3,
            order: 9,
            value: 1.0,
            frames: 1,
            width: 16,
            height: 16,
          ).serialize(),
          framesDelta: 1,
          integrationSecondsDelta: 1.0,
        ),
        throwsA(
          isA<ContributionRejected>().having(
            (e) => e.code,
            'code',
            'badRequest',
          ),
        ),
      );
      expect(store.load(3, 9), isNull); // nothing seeded
    });

    test('a delta with a non-whitelisted channel count is rejected (400)', () {
      final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
      expect(
        () => fusion.contribute(
          accountId: alice.account.id,
          tileId: 4,
          order: 9,
          deltaBytes: TileBuilder.synthetic(
            tileId: 4,
            order: 9,
            value: 1.0,
            frames: 1,
            channels: 2, // not 1 or 3
            width: 8,
            height: 8,
          ).serialize(),
          framesDelta: 1,
          integrationSecondsDelta: 1.0,
        ),
        throwsA(
          isA<ContributionRejected>().having(
            (e) => e.code,
            'code',
            'badRequest',
          ),
        ),
      );
    });

    test('a 3-channel (OSC) delta at the right size is accepted', () {
      final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
      final outcome = fusion.contribute(
        accountId: alice.account.id,
        tileId: 6,
        order: 9,
        deltaBytes: TileBuilder.synthetic(
          tileId: 6,
          order: 9,
          value: 1.0,
          frames: 1,
          channels: 3,
          width: 8,
          height: 8,
          contributor: alice.account.id,
        ).serialize(),
        framesDelta: 1,
        integrationSecondsDelta: 1.0,
      );
      expect(outcome.accepted, isTrue);
    });
  });

  group('self-reported delta clamping', () {
    test('a framesDelta above the ceiling is rejected (400)', () {
      final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
      final fusionTight = FusionService(
        db: db,
        store: store,
        accounts: accounts,
        expectedTilePixels: 8,
        maxFramesPerContribution: 10,
      );
      expect(
        () => fusionTight.contribute(
          accountId: alice.account.id,
          tileId: 8,
          order: 9,
          deltaBytes: TileBuilder.synthetic(
            tileId: 8,
            order: 9,
            value: 1.0,
            frames: 1,
            width: 8,
            height: 8,
          ).serialize(),
          framesDelta: 999999, // wildly inflated
          integrationSecondsDelta: 1.0,
        ),
        throwsA(
          isA<ContributionRejected>().having(
            (e) => e.code,
            'code',
            'badRequest',
          ),
        ),
      );
    });

    test('a negative integrationSecondsDelta is rejected (400)', () {
      final alice = accounts.signup(publicKey: 'A', displayName: 'Alice');
      expect(
        () => fusion.contribute(
          accountId: alice.account.id,
          tileId: 9,
          order: 9,
          deltaBytes: TileBuilder.synthetic(
            tileId: 9,
            order: 9,
            value: 1.0,
            frames: 1,
            width: 8,
            height: 8,
          ).serialize(),
          framesDelta: 1,
          integrationSecondsDelta: -5.0,
        ),
        throwsA(
          isA<ContributionRejected>().having(
            (e) => e.code,
            'code',
            'badRequest',
          ),
        ),
      );
    });
  });
}

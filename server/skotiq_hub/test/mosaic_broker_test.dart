// Collaborative-mosaic claim broker + assembly coordinator (unit level, over
// the in-memory HubDatabase).
//
// Covers: publish inserts the mosaic + panels open/'pending'; claim returns a
// token; claim CONTENTION (a second account claiming the same panel is refused
// — the core anti-double-collect guarantee); two different panels claim
// concurrently by two accounts both succeed; expired claims free the panel for
// re-claim; same-account re-claim renews; recordUpload persists provenance +
// flips status='uploaded'; PARTIAL-SET GATING (allPanelsUploaded only when every
// panel is in; assembly/output refused before that; status auto-advances).

import 'dart:io';
import 'dart:typed_data';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

void main() {
  late HubDatabase db;
  late MosaicBrokerService broker;
  late String owner;
  late String alice;
  late String bob;

  setUp(() {
    db = HubDatabase.open(':memory:');
    broker = MosaicBrokerService(db);
    final accounts = AccountService(db, TokenService(db));
    owner = accounts
        .signup(publicKey: 'owner', displayName: 'Owner')
        .account
        .id;
    alice = accounts
        .signup(publicKey: 'alice', displayName: 'Alice')
        .account
        .id;
    bob = accounts.signup(publicKey: 'bob', displayName: 'Bob').account.id;
  });

  tearDown(() => db.dispose());

  String publish4() => broker.publish(
    ownerAccountId: owner,
    name: 'Veil 2x2',
    rows: 2,
    cols: 2,
    centerRaDeg: 312.0,
    centerDecDeg: 30.0,
    panels: const [
      MosaicPanelSpec(panelIndex: 0, centerRaDeg: 311.5, centerDecDeg: 29.5),
      MosaicPanelSpec(panelIndex: 1, centerRaDeg: 312.5, centerDecDeg: 29.5),
      MosaicPanelSpec(panelIndex: 2, centerRaDeg: 311.5, centerDecDeg: 30.5),
      MosaicPanelSpec(panelIndex: 3, centerRaDeg: 312.5, centerDecDeg: 30.5),
    ],
  );

  test('publish inserts the mosaic + all panels in pending/open state', () {
    final id = publish4();
    final mosaic = broker.getMosaic(id)!;
    expect(mosaic.status, 'open');
    expect(mosaic.ownerAccountId, owner);
    expect(mosaic.rows, 2);
    expect(mosaic.cols, 2);
    final panels = broker.panelStates(id);
    expect(panels.length, 4);
    expect(panels.map((p) => p.panelIndex), [0, 1, 2, 3]);
    expect(panels.every((p) => p.status == 'pending'), isTrue);
  });

  test('claimPanel returns a token and marks the panel claimed', () {
    final id = publish4();
    final claim = broker.claimPanel(
      mosaicId: id,
      panelIndex: 0,
      accountId: alice,
      rigId: 'rig-alice',
    );
    expect(claim, isNotNull);
    expect(claim!.claimToken, isNotEmpty);
    expect(claim.panelIndex, 0);
    final panel = broker.panelStates(id).firstWhere((p) => p.panelIndex == 0);
    expect(panel.status, 'claimed');
    expect(panel.assignedAccountId, alice);
    expect(panel.assignedRigId, 'rig-alice');
  });

  test('a second account claiming the SAME panel is refused (contention)', () {
    final id = publish4();
    expect(
      broker.claimPanel(mosaicId: id, panelIndex: 0, accountId: alice),
      isNotNull,
    );
    // Bob cannot take a panel Alice still holds — the anti-double-collect gate.
    expect(
      broker.claimPanel(mosaicId: id, panelIndex: 0, accountId: bob),
      isNull,
    );
  });

  test(
    'two DIFFERENT panels claim concurrently by two accounts both succeed',
    () {
      final id = publish4();
      expect(
        broker.claimPanel(mosaicId: id, panelIndex: 0, accountId: alice),
        isNotNull,
      );
      expect(
        broker.claimPanel(mosaicId: id, panelIndex: 1, accountId: bob),
        isNotNull,
      );
    },
  );

  test('same-account re-claim renews the baton', () {
    final id = publish4();
    final first = broker.claimPanel(
      mosaicId: id,
      panelIndex: 0,
      accountId: alice,
    )!;
    final renewed = broker.claimPanel(
      mosaicId: id,
      panelIndex: 0,
      accountId: alice,
    )!;
    expect(renewed.claimToken, isNot(equals(first.claimToken)));
    expect(
      renewed.expiresAt.isAfter(first.expiresAt) ||
          renewed.expiresAt.isAtSameMomentAs(first.expiresAt),
      isTrue,
    );
  });

  test('an expired claim frees the panel for re-claim', () {
    final id = publish4();
    broker.claimPanel(mosaicId: id, panelIndex: 0, accountId: alice);
    // Force the claim_expires_at into the past (mirrors the handoff tests).
    db.db.execute(
      'UPDATE collaborative_mosaic_panels SET claim_expires_at = ? '
      'WHERE mosaic_id = ? AND panel_index = 0;',
      <Object?>['2000-01-01T00:00:00.000Z', id],
    );
    // Bob can now take it (Alice's claim lapsed).
    expect(
      broker.claimPanel(mosaicId: id, panelIndex: 0, accountId: bob),
      isNotNull,
    );
    final panel = broker.panelStates(id).firstWhere((p) => p.panelIndex == 0);
    expect(panel.assignedAccountId, bob);
  });

  test('claim throws on an unknown mosaic or panel', () {
    final id = publish4();
    expect(
      () =>
          broker.claimPanel(mosaicId: 'nope', panelIndex: 0, accountId: alice),
      throwsA(isA<MosaicNotFound>()),
    );
    expect(
      () => broker.claimPanel(mosaicId: id, panelIndex: 99, accountId: alice),
      throwsA(isA<MosaicPanelNotFound>()),
    );
  });

  test('release frees a held panel; non-holder release is a no-op', () {
    final id = publish4();
    broker.claimPanel(mosaicId: id, panelIndex: 0, accountId: alice);
    expect(
      broker.releasePanel(mosaicId: id, panelIndex: 0, accountId: bob),
      isFalse,
    );
    expect(
      broker.releasePanel(mosaicId: id, panelIndex: 0, accountId: alice),
      isTrue,
    );
    expect(
      broker.claimPanel(mosaicId: id, panelIndex: 0, accountId: bob),
      isNotNull,
    );
  });

  test('recordUpload persists provenance + flips status to uploaded', () {
    final id = publish4();
    broker.claimPanel(
      mosaicId: id,
      panelIndex: 0,
      accountId: alice,
      rigId: 'rig-a',
    );
    expect(
      broker.holdsClaim(mosaicId: id, panelIndex: 0, accountId: alice),
      isTrue,
    );
    final panel = broker.recordUpload(
      mosaicId: id,
      panelIndex: 0,
      accountId: alice,
      masterId: 'm-0',
      path: '/tmp/m0.fits',
      rigId: 'rig-a',
    )!;
    expect(panel.status, 'uploaded');
    expect(panel.assignedAccountId, alice);
    expect(panel.assignedRigId, 'rig-a');
    expect(panel.uploadedMasterId, 'm-0');
    expect(broker.panelMasterPath(id, 0), '/tmp/m0.fits');
    // An uploaded panel is terminal — never re-claimable.
    expect(
      broker.claimPanel(mosaicId: id, panelIndex: 0, accountId: bob),
      isNull,
    );
  });

  test('recordUpload on an UNCLAIMED panel is refused (claim guard)', () {
    final id = publish4();
    // No claim was ever taken on panel 0 — a raw recordUpload must not clobber a
    // pending slot into `uploaded`.
    expect(
      broker.recordUpload(
        mosaicId: id,
        panelIndex: 0,
        accountId: alice,
        masterId: 'm-0',
        path: '/tmp/m0.fits',
      ),
      isNull,
    );
    final panel = broker.panelStates(id).firstWhere((p) => p.panelIndex == 0);
    expect(panel.status, 'pending');
    expect(panel.uploadedMasterId, isNull);
  });

  test('recordUpload is refused after a mid-upload force-release (TOCTOU '
      'self-heal)', () {
    final id = publish4();
    final claim = broker.claimPanel(
      mosaicId: id,
      panelIndex: 0,
      accountId: alice,
      rigId: 'rig-a',
    )!;
    // Simulate the owner force-releasing the stuck panel WHILE Alice's master is
    // still streaming in (the `await _readBinary` window in the handler).
    expect(
      broker.forceReleasePanel(mosaicId: id, panelIndex: 0, accountId: owner),
      isTrue,
    );
    // Alice's late recordUpload (carrying the now-stale claim token) must NOT
    // resurrect the panel under her account — the claim guard matches 0 rows.
    expect(
      broker.recordUpload(
        mosaicId: id,
        panelIndex: 0,
        accountId: alice,
        masterId: 'm-0',
        path: '/tmp/m0.fits',
        claimToken: claim.claimToken,
      ),
      isNull,
    );
    final panel = broker.panelStates(id).firstWhere((p) => p.panelIndex == 0);
    expect(panel.status, 'pending');
    expect(panel.assignedAccountId, isNull);
    expect(panel.uploadedMasterId, isNull);
  });

  test('recordUpload is refused after a re-claimer takes over; the re-claimer '
      'still uploads', () {
    final id = publish4();
    final aliceClaim = broker.claimPanel(
      mosaicId: id,
      panelIndex: 0,
      accountId: alice,
    )!;
    // Alice's claim lapses; Bob re-claims and uploads first.
    db.db.execute(
      'UPDATE collaborative_mosaic_panels SET claim_expires_at = ? '
      'WHERE mosaic_id = ? AND panel_index = 0;',
      <Object?>['2000-01-01T00:00:00.000Z', id],
    );
    expect(
      broker.claimPanel(mosaicId: id, panelIndex: 0, accountId: bob),
      isNotNull,
    );
    final bobPanel = broker.recordUpload(
      mosaicId: id,
      panelIndex: 0,
      accountId: bob,
      masterId: 'm-bob',
      path: '/tmp/bob.fits',
    )!;
    expect(bobPanel.assignedAccountId, bob);
    // Alice's late write (stale token, terminal `uploaded` state) is refused and
    // never overwrites Bob's master.
    expect(
      broker.recordUpload(
        mosaicId: id,
        panelIndex: 0,
        accountId: alice,
        masterId: 'm-alice',
        path: '/tmp/alice.fits',
        claimToken: aliceClaim.claimToken,
      ),
      isNull,
    );
    expect(broker.panelMasterPath(id, 0), '/tmp/bob.fits');
  });

  test('partial-set gating: allPanelsUploaded only when EVERY panel is in', () {
    final id = publish4();
    for (var i = 0; i < 4; i++) {
      broker.claimPanel(mosaicId: id, panelIndex: i, accountId: alice);
    }
    for (var i = 0; i < 3; i++) {
      broker.recordUpload(
        mosaicId: id,
        panelIndex: i,
        accountId: alice,
        masterId: 'm-$i',
        path: '/tmp/m$i.fits',
      );
      // With < N uploaded the gate stays closed.
      expect(broker.allPanelsUploaded(id), isFalse);
      expect(broker.outputPathFor(id), isNull);
    }
    // The final panel closes the set.
    broker.recordUpload(
      mosaicId: id,
      panelIndex: 3,
      accountId: alice,
      masterId: 'm-3',
      path: '/tmp/m3.fits',
    );
    expect(broker.allPanelsUploaded(id), isTrue);
  });

  test(
    'assembly lifecycle: open -> assembling -> complete + output served',
    () {
      final id = publish4();
      for (var i = 0; i < 4; i++) {
        broker.claimPanel(mosaicId: id, panelIndex: i, accountId: alice);
        broker.recordUpload(
          mosaicId: id,
          panelIndex: i,
          accountId: alice,
          masterId: 'm-$i',
          path: '/tmp/m$i.fits',
        );
      }
      expect(broker.getMosaic(id)!.status, 'open');
      broker.markAssembling(id);
      expect(broker.getMosaic(id)!.status, 'assembling');
      // Output is refused (404 path) until complete — the partial-set gate.
      expect(broker.outputPathFor(id), isNull);

      final tmp = Directory.systemTemp.createTempSync('skhub_mosaic_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final store = MosaicMasterStore('${tmp.path}/atlas');
      final outPath = store.saveOutput(
        mosaicId: id,
        masterId: 'out',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(broker.markComplete(id, outputPath: outPath), isTrue);
      expect(broker.getMosaic(id)!.status, 'complete');
      expect(broker.outputPathFor(id), outPath);
      expect(store.load(outPath), Uint8List.fromList([1, 2, 3, 4]));
    },
  );

  test(
    'markComplete is a no-op (returns false) unless the mosaic is assembling',
    () {
      final id = publish4();
      // Still `open` — panels not all uploaded. A premature completion is refused.
      expect(broker.markComplete(id, outputPath: '/tmp/early.fits'), isFalse);
      expect(broker.getMosaic(id)!.status, 'open');
      expect(broker.outputPathFor(id), isNull);

      // Drive it to `assembling`, complete once, then a repeat completion is a
      // no-op (cannot overwrite an already-complete output).
      for (var i = 0; i < 4; i++) {
        broker.claimPanel(mosaicId: id, panelIndex: i, accountId: alice);
        broker.recordUpload(
          mosaicId: id,
          panelIndex: i,
          accountId: alice,
          masterId: 'm-$i',
          path: '/tmp/m$i.fits',
        );
      }
      broker.markAssembling(id);
      expect(broker.markComplete(id, outputPath: '/tmp/first.fits'), isTrue);
      expect(broker.markComplete(id, outputPath: '/tmp/second.fits'), isFalse);
      expect(broker.getMosaic(id)!.outputPath, '/tmp/first.fits');
    },
  );

  test(
    'isParticipant: owner + assigned rigs only, never an unrelated account',
    () {
      final id = publish4();
      broker.claimPanel(mosaicId: id, panelIndex: 0, accountId: alice);
      expect(broker.isParticipant(id, owner), isTrue, reason: 'owner');
      expect(broker.isParticipant(id, alice), isTrue, reason: 'assigned rig');
      expect(broker.isParticipant(id, bob), isFalse, reason: 'unrelated');
      expect(broker.isParticipant('no-such-mosaic', owner), isFalse);
    },
  );
}

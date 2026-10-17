import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

void main() {
  late HubDatabase db;
  late TokenService tokens;
  late AccountService accounts;
  late FollowTheNightScheduler scheduler;
  late HandoffService handoff;
  late CoImagingService coimaging;
  // Injectable wall clock so the anti-forgery contribution envelope (cumulative
  // tallies vs. wall-clock since join) is deterministic. Advance it to simulate
  // real imaging time passing between join and contribution.
  late DateTime fakeNow;

  setUp(() {
    db = HubDatabase.open(':memory:');
    tokens = TokenService(db);
    accounts = AccountService(
      db,
      tokens,
      hasher: PasswordHasher(iterations: 1000),
    );
    scheduler = FollowTheNightScheduler(db);
    handoff = HandoffService(db);
    fakeNow = DateTime.utc(2026, 6, 30, 0, 0, 0);
    coimaging = CoImagingService(
      db: db,
      scheduler: scheduler,
      handoff: handoff,
      healpixOrder: 9,
      clock: () => fakeNow,
    );
  });

  tearDown(() => db.dispose());

  String mkAccount(String key) =>
      accounts.signup(publicKey: key, displayName: key).account.id;

  group('session lifecycle + membership', () {
    test('createSession ensures a shared target and anchor participant', () {
      final owner = mkAccount('owner');
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'M31',
        centerRaDeg: 10.68,
        centerDecDeg: 41.27,
      );
      final session = coimaging.getSession(id)!;
      expect(session.ownerAccountId, owner);
      expect(session.status, 'active');
      expect(session.sharedTargetId, isNotNull);
      // The cone-merged shared target exists for the longitude baton + fusion.
      expect(scheduler.getTarget(session.sharedTargetId!), isNotNull);

      final ps = coimaging.participants(id);
      expect(ps, hasLength(1));
      expect(ps.single.accountId, owner);
      expect(ps.single.framingOffsetIndex, 0);
      expect(ps.single.framingOffsetRaArcsec, 0.0);
      expect(ps.single.framingOffsetDecArcsec, 0.0);
      expect(ps.single.membershipToken, isNotEmpty);
    });

    test(
      'join is idempotent for the same rig (renewal keeps slot + token)',
      () {
        final owner = mkAccount('owner');
        final id = coimaging.createSession(
          ownerAccountId: owner,
          targetName: 'M51',
          centerRaDeg: 202.5,
          centerDecDeg: 47.2,
        );
        final bob = mkAccount('bob');
        final first = coimaging.join(
          sessionId: id,
          accountId: bob,
          rigId: 'rig-1',
        );
        final again = coimaging.join(
          sessionId: id,
          accountId: bob,
          rigId: 'rig-1',
        );
        expect(again.framingOffsetIndex, first.framingOffsetIndex);
        expect(again.membershipToken, first.membershipToken);
        expect(coimaging.participants(id), hasLength(2)); // owner + bob
      },
    );

    test('join throws for unknown / closed sessions', () {
      final bob = mkAccount('bob');
      expect(
        () => coimaging.join(sessionId: 'nope', accountId: bob),
        throwsA(isA<CoImagingSessionNotFound>()),
      );
      final owner = mkAccount('owner');
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'NGC',
        centerRaDeg: 1,
        centerDecDeg: 2,
      );
      coimaging.closeSession(id);
      expect(
        () => coimaging.join(sessionId: id, accountId: bob),
        throwsA(isA<CoImagingSessionClosed>()),
      );
    });

    test('leave clears membership but keeps the row + tallies', () {
      final owner = mkAccount('owner');
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'M42',
        centerRaDeg: 83.8,
        centerDecDeg: -5.4,
      );
      final bob = mkAccount('bob');
      coimaging.join(sessionId: id, accountId: bob, rigId: 'r');
      expect(coimaging.isParticipant(id, bob), isTrue);
      expect(
        coimaging.leave(sessionId: id, accountId: bob, rigId: 'r'),
        isTrue,
      );
      expect(coimaging.isParticipant(id, bob), isFalse);
      // Row survives for attribution/history.
      expect(coimaging.participants(id), hasLength(2));
    });

    test('re-join after leave re-activates membership (fresh token)', () {
      final owner = mkAccount('owner');
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'Rejoin',
        centerRaDeg: 12,
        centerDecDeg: 34,
      );
      final bob = mkAccount('bob');
      final first = coimaging.join(sessionId: id, accountId: bob, rigId: 'r');
      expect(first.membershipToken, isNotEmpty);

      // Leave clears the token; the rig is locked out of contributing.
      expect(
        coimaging.leave(sessionId: id, accountId: bob, rigId: 'r'),
        isTrue,
      );
      expect(coimaging.isParticipant(id, bob), isFalse);
      expect(
        coimaging.holdsMembership(sessionId: id, accountId: bob, rigId: 'r'),
        isFalse,
      );

      // Re-join MUST re-activate: same slot, but a fresh non-empty token.
      final again = coimaging.join(sessionId: id, accountId: bob, rigId: 'r');
      expect(again.framingOffsetIndex, first.framingOffsetIndex);
      expect(again.membershipToken, isNotEmpty);
      expect(again.membershipToken, isNot(first.membershipToken));
      expect(coimaging.isParticipant(id, bob), isTrue);
      expect(
        coimaging.holdsMembership(
          sessionId: id,
          accountId: bob,
          rigId: 'r',
          membershipToken: again.membershipToken,
        ),
        isTrue,
      );

      // And the re-joined rig can contribute again (after real imaging time).
      fakeNow = fakeNow.add(const Duration(hours: 1));
      final acc = coimaging.recordContribution(
        sessionId: id,
        accountId: bob,
        rigId: 'r',
        framesDelta: 3,
        integrationSecondsDelta: 180,
      );
      expect(acc.combinedFrames, 3);
    });
  });

  group('framing offset assignment (uniqueness)', () {
    test('each joining rig gets a distinct framing offset', () {
      final owner = mkAccount('owner');
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'T',
        centerRaDeg: 0,
        centerDecDeg: 0,
      );
      // 11 more rigs across two accounts.
      for (var i = 0; i < 11; i++) {
        final acct = mkAccount('a$i');
        coimaging.join(sessionId: id, accountId: acct, rigId: 'rig$i');
      }
      final ps = coimaging.participants(id);
      expect(ps, hasLength(12));
      final slots = ps.map((p) => p.framingOffsetIndex).toSet();
      expect(slots, hasLength(12)); // all slots distinct
      // All (ra, dec) offsets distinct too.
      final offsets = ps.map(
        (p) => '${p.framingOffsetRaArcsec},${p.framingOffsetDecArcsec}',
      );
      expect(offsets.toSet(), hasLength(12));
      // Anchor is the only zero offset.
      final zeros = ps.where(
        (p) =>
            p.framingOffsetRaArcsec == 0.0 && p.framingOffsetDecArcsec == 0.0,
      );
      expect(zeros, hasLength(1));
    });

    test('a freed slot is re-assigned to the next joiner', () {
      final owner = mkAccount('owner'); // slot 0
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'T',
        centerRaDeg: 0,
        centerDecDeg: 0,
      );
      final a = mkAccount('a');
      final b = mkAccount('b');
      coimaging.join(sessionId: id, accountId: a, rigId: 'ra'); // slot 1
      coimaging.join(sessionId: id, accountId: b, rigId: 'rb'); // slot 2
      // Delete a's row entirely (simulate eviction) to free slot 1.
      db.db.execute(
        'DELETE FROM coimaging_participants WHERE account_id = ?;',
        <Object?>[a],
      );
      final c = mkAccount('c');
      final joined = coimaging.join(sessionId: id, accountId: c, rigId: 'rc');
      expect(joined.framingOffsetIndex, 1); // reused the freed slot
    });
  });

  group('combined accounting', () {
    test('combined totals equal the exact sum across participants', () {
      final owner = mkAccount('owner');
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'Faint',
        centerRaDeg: 150,
        centerDecDeg: 22,
      );
      final bob = mkAccount('bob');
      final carol = mkAccount('carol');
      coimaging.join(sessionId: id, accountId: bob, rigId: 'rb');
      coimaging.join(sessionId: id, accountId: carol, rigId: 'rc');

      // Several hours of real imaging elapse before the reports land.
      fakeNow = fakeNow.add(const Duration(hours: 6));
      coimaging.recordContribution(
        sessionId: id,
        accountId: owner,
        framesDelta: 10,
        integrationSecondsDelta: 600,
      );
      coimaging.recordContribution(
        sessionId: id,
        accountId: bob,
        rigId: 'rb',
        framesDelta: 20,
        integrationSecondsDelta: 1200,
      );
      final acc = coimaging.recordContribution(
        sessionId: id,
        accountId: carol,
        rigId: 'rc',
        framesDelta: 5,
        integrationSecondsDelta: 300,
      );
      expect(acc.combinedFrames, 35);
      expect(acc.combinedIntegrationSeconds, closeTo(2100, 1e-9));
      expect(acc.participantCount, 3);

      final session = coimaging.getSession(id)!;
      expect(session.combinedFrames, 35);
      expect(session.combinedIntegrationSeconds, closeTo(2100, 1e-9));

      // A repeat report adds, but the combined total stays the EXACT sum (no
      // drift) because it is re-aggregated, not incremented blindly.
      coimaging.recordContribution(
        sessionId: id,
        accountId: bob,
        rigId: 'rb',
        framesDelta: 4,
        integrationSecondsDelta: 240,
      );
      expect(coimaging.getSession(id)!.combinedFrames, 39);
    });

    test('a non-participant cannot record a contribution', () {
      final owner = mkAccount('owner');
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'X',
        centerRaDeg: 5,
        centerDecDeg: 5,
      );
      final stranger = mkAccount('stranger');
      expect(
        () => coimaging.recordContribution(
          sessionId: id,
          accountId: stranger,
          framesDelta: 1,
          integrationSecondsDelta: 1,
        ),
        throwsA(isA<CoImagingParticipantNotFound>()),
      );
    });
  });

  group('live combined preview channel', () {
    test(
      'a subscriber gets an immediate snapshot then per-contribution events',
      () async {
        final owner = mkAccount('owner');
        final id = coimaging.createSession(
          ownerAccountId: owner,
          targetName: 'Live',
          centerRaDeg: 60,
          centerDecDeg: 30,
        );
        final events = <CoImagingPreviewEvent>[];
        final sub = coimaging.subscribe(id).listen(events.add);
        await Future<void>.delayed(Duration.zero); // let onListen fire
        expect(events, hasLength(1));
        expect(events.first.kind, 'snapshot');
        expect(coimaging.subscriberCount(id), 1);

        fakeNow = fakeNow.add(const Duration(hours: 1));
        coimaging.recordContribution(
          sessionId: id,
          accountId: owner,
          framesDelta: 7,
          integrationSecondsDelta: 420,
        );
        await Future<void>.delayed(Duration.zero);
        expect(events, hasLength(2));
        expect(events.last.kind, 'combined-preview');
        expect(events.last.combinedFrames, 7);
        expect(events.last.activeTileId, greaterThanOrEqualTo(0));
        // The SSE frame is well-formed.
        final frame = events.last.toSseFrame();
        expect(frame, startsWith('event: combined-preview\ndata: '));
        expect(frame, endsWith('\n\n'));

        await sub.cancel();
        expect(coimaging.subscriberCount(id), 0);
      },
    );

    test(
      'a re-join after leaving broadcasts a participant-joined event',
      () async {
        final owner = mkAccount('owner');
        final id = coimaging.createSession(
          ownerAccountId: owner,
          targetName: 'Rejoin-live',
          centerRaDeg: 45,
          centerDecDeg: 15,
        );
        final bob = mkAccount('bob');
        // Establish + tear down bob's membership BEFORE subscribing, so the only
        // roster event the subscriber can observe is the re-join under test.
        coimaging.join(sessionId: id, accountId: bob, rigId: 'r');
        expect(
          coimaging.leave(sessionId: id, accountId: bob, rigId: 'r'),
          isTrue,
        );

        final events = <CoImagingPreviewEvent>[];
        final sub = coimaging.subscribe(id).listen(events.add);
        await Future<void>.delayed(Duration.zero); // let the snapshot fire
        expect(events, hasLength(1));
        expect(events.first.kind, 'snapshot');

        // Re-join re-activates the membership — subscribers must see it live, not
        // only on bob's next contribution.
        coimaging.join(sessionId: id, accountId: bob, rigId: 'r');
        await Future<void>.delayed(Duration.zero);
        expect(events, hasLength(2));
        expect(events.last.kind, 'participant-joined');

        await sub.cancel();
      },
    );
  });

  group('longitude hand-off baton', () {
    test('baton moves site->site via the shared-target handoff', () {
      final siteA = mkAccount('siteA');
      final id = coimaging.createSession(
        ownerAccountId: siteA,
        targetName: 'Baton',
        centerRaDeg: 200,
        centerDecDeg: 10,
      );
      final siteB = mkAccount('siteB');
      coimaging.join(sessionId: id, accountId: siteB, rigId: 'b');

      // Site A is imaging now.
      final claimA = coimaging.claimBaton(sessionId: id, accountId: siteA);
      expect(claimA, isNotNull);
      expect(coimaging.batonState(id).holder, siteA);

      // Site B cannot steal it while A holds it.
      expect(coimaging.claimBaton(sessionId: id, accountId: siteB), isNull);

      // The target sets at A; A releases, B picks it up (longitude hand-off).
      expect(coimaging.releaseBaton(sessionId: id, accountId: siteA), isTrue);
      expect(coimaging.batonState(id).holder, isNull);
      final claimB = coimaging.claimBaton(sessionId: id, accountId: siteB);
      expect(claimB, isNotNull);
      expect(coimaging.batonState(id).holder, siteB);
    });

    test('two distinct sessions on the SAME object have isolated batons', () {
      // Both sessions cone-merge onto one shared_targets row...
      final ownerA = mkAccount('ownerA');
      final ownerB = mkAccount('ownerB');
      final a = coimaging.createSession(
        ownerAccountId: ownerA,
        targetName: 'M101',
        centerRaDeg: 210.8,
        centerDecDeg: 54.35,
      );
      final b = coimaging.createSession(
        ownerAccountId: ownerB,
        targetName: 'M101',
        centerRaDeg: 210.8,
        centerDecDeg: 54.35,
      );
      // ...the same shared target (cone-merge), proving the collision precondition.
      expect(
        coimaging.getSession(a)!.sharedTargetId,
        coimaging.getSession(b)!.sharedTargetId,
      );

      // Session A's owner claims A's baton.
      expect(coimaging.claimBaton(sessionId: a, accountId: ownerA), isNotNull);
      expect(coimaging.batonState(a).holder, ownerA);

      // The attacker who owns the colliding session B can claim B's baton WITHOUT
      // disturbing A's: the batons are session-scoped, so no cross-session seizure
      // and A's hand-off attribution is intact.
      expect(coimaging.claimBaton(sessionId: b, accountId: ownerB), isNotNull);
      expect(coimaging.batonState(b).holder, ownerB);
      expect(coimaging.batonState(a).holder, ownerA);

      // Releasing B leaves A's baton untouched.
      expect(coimaging.releaseBaton(sessionId: b, accountId: ownerB), isTrue);
      expect(coimaging.batonState(b).holder, isNull);
      expect(coimaging.batonState(a).holder, ownerA);
    });
  });

  group('closed-session contract', () {
    test('a closed session refuses contributions and baton operations', () {
      final owner = mkAccount('owner');
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'Done',
        centerRaDeg: 80,
        centerDecDeg: 20,
      );
      final bob = mkAccount('bob');
      coimaging.join(sessionId: id, accountId: bob, rigId: 'rb');
      coimaging.closeSession(id);

      // Membership token survives close, but the closed session is dead:
      expect(
        coimaging.holdsMembership(sessionId: id, accountId: bob, rigId: 'rb'),
        isTrue,
      );
      fakeNow = fakeNow.add(const Duration(hours: 1));
      expect(
        () => coimaging.recordContribution(
          sessionId: id,
          accountId: bob,
          rigId: 'rb',
          framesDelta: 1,
          integrationSecondsDelta: 60,
        ),
        throwsA(isA<CoImagingSessionClosed>()),
      );
      expect(
        () => coimaging.claimBaton(sessionId: id, accountId: bob),
        throwsA(isA<CoImagingSessionClosed>()),
      );
      expect(
        () => coimaging.releaseBaton(sessionId: id, accountId: bob),
        throwsA(isA<CoImagingSessionClosed>()),
      );
      // Combined accounting did not drift.
      expect(coimaging.getSession(id)!.combinedFrames, 0);
    });
  });

  group('WS4 consent ledger (revocable share proof)', () {
    test('a rig streaming many subs leaves exactly one live consent row, and it '
        'is revoked when its report is overwritten', () {
      final consent = ConsentService(db);
      final co = CoImagingService(
        db: db,
        scheduler: scheduler,
        handoff: handoff,
        healpixOrder: 9,
        consent: consent,
        clock: () => fakeNow,
      );
      final owner = mkAccount('owner');
      final id = co.createSession(
        ownerAccountId: owner,
        targetName: 'Ledger',
        centerRaDeg: 30,
        centerDecDeg: 30,
      );
      // Five subs fold into the one session, each recording a fresh consent up
      // front (as the HTTP handler does) and riding it onto the report. Each
      // report revokes the one the previous report stored, so exactly one share
      // is ever live — no per-sub orphan pile-up.
      for (var i = 0; i < 5; i++) {
        fakeNow = fakeNow.add(const Duration(minutes: 5));
        final consentId = consent.record(
          accountId: owner,
          artifactType: 'coimaging',
          artifactRef: id,
          license: 'cc-by',
        );
        co.recordContribution(
          sessionId: id,
          accountId: owner,
          framesDelta: 1,
          integrationSecondsDelta: 60,
          consentId: consentId,
        );
        expect(consent.liveConsentCount('coimaging', id), 1);
      }
    });

    test('a rejected report revokes nothing already-live but its own share can '
        'be released by the caller', () {
      final consent = ConsentService(db);
      final co = CoImagingService(
        db: db,
        scheduler: scheduler,
        handoff: handoff,
        healpixOrder: 9,
        consent: consent,
        clock: () => fakeNow,
      );
      final owner = mkAccount('owner');
      final id = co.createSession(
        ownerAccountId: owner,
        targetName: 'RejectLedger',
        centerRaDeg: 30,
        centerDecDeg: 30,
      );
      fakeNow = fakeNow.add(const Duration(minutes: 10));
      final goodConsent = consent.record(
        accountId: owner,
        artifactType: 'coimaging',
        artifactRef: id,
        license: 'cc-by',
      );
      co.recordContribution(
        sessionId: id,
        accountId: owner,
        framesDelta: 1,
        integrationSecondsDelta: 60,
        consentId: goodConsent,
      );
      expect(consent.liveConsentCount('coimaging', id), 1);

      // A forged report is refused BEFORE the participant row is overwritten, so
      // the prior valid consent is untouched and the just-recorded (now-orphan)
      // consent is the caller's to revoke — mirroring the handler's reject leg.
      final rejectedConsent = consent.record(
        accountId: owner,
        artifactType: 'coimaging',
        artifactRef: id,
        license: 'cc-by',
      );
      expect(consent.liveConsentCount('coimaging', id), 2);
      expect(
        () => co.recordContribution(
          sessionId: id,
          accountId: owner,
          framesDelta: 1,
          integrationSecondsDelta: 1e30,
          consentId: rejectedConsent,
        ),
        throwsA(isA<CoImagingContributionRejected>()),
      );
      consent.revoke(rejectedConsent);
      // The good share is still live; the rejected one is gone.
      expect(consent.liveConsentCount('coimaging', id), 1);
    });
  });

  group('contribution provenance envelope', () {
    test('a single forged report is rejected outright', () {
      final owner = mkAccount('owner');
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'Forge',
        centerRaDeg: 40,
        centerDecDeg: 10,
      );
      fakeNow = fakeNow.add(const Duration(minutes: 10));
      // Absurd integration time (forged depth) is refused.
      expect(
        () => coimaging.recordContribution(
          sessionId: id,
          accountId: owner,
          framesDelta: 1,
          integrationSecondsDelta: 1e30,
        ),
        throwsA(isA<CoImagingContributionRejected>()),
      );
      // Absurd frame count (forged attribution) is refused.
      expect(
        () => coimaging.recordContribution(
          sessionId: id,
          accountId: owner,
          framesDelta: 2000000000,
          integrationSecondsDelta: 1,
        ),
        throwsA(isA<CoImagingContributionRejected>()),
      );
      // Nothing leaked into the combined accounting.
      expect(coimaging.getSession(id)!.combinedFrames, 0);
      expect(coimaging.getSession(id)!.combinedIntegrationSeconds, 0.0);
    });

    test('cumulative integration cannot out-run wall-clock since join', () {
      final owner = mkAccount('owner');
      final id = coimaging.createSession(
        ownerAccountId: owner,
        targetName: 'Pace',
        centerRaDeg: 40,
        centerDecDeg: 10,
      );
      // After 10 min of real time a plausible ~9.5 min report is accepted...
      fakeNow = fakeNow.add(const Duration(minutes: 10));
      final ok = coimaging.recordContribution(
        sessionId: id,
        accountId: owner,
        framesDelta: 2,
        integrationSecondsDelta: 570,
      );
      expect(ok.combinedIntegrationSeconds, closeTo(570, 1e-9));

      // ...but a second report claiming another full hour right away (no real
      // time elapsed) blows the envelope and is refused — a report flood cannot
      // out-run real time.
      expect(
        () => coimaging.recordContribution(
          sessionId: id,
          accountId: owner,
          framesDelta: 1,
          integrationSecondsDelta: 3600,
        ),
        throwsA(isA<CoImagingContributionRejected>()),
      );
      expect(
        coimaging.getSession(id)!.combinedIntegrationSeconds,
        closeTo(570, 1e-9),
      );

      // After another hour of real imaging the same delta now fits.
      fakeNow = fakeNow.add(const Duration(hours: 1));
      final ok2 = coimaging.recordContribution(
        sessionId: id,
        accountId: owner,
        framesDelta: 1,
        integrationSecondsDelta: 3600,
      );
      expect(ok2.combinedIntegrationSeconds, closeTo(4170, 1e-9));
    });
  });
}

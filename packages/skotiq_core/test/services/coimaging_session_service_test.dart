// Client-side live co-imaging orchestration.
//
// Exercises [CoImagingSessionService] over a `package:http/testing` MockClient
// (no network) + a real in-memory DB with the real [CoImagingSessionsDao]:
//
//   * createSession persists the owner membership (anchor framing offset +
//     membership token);
//   * joinSession persists the hub-assigned framing offset + token;
//   * recordContribution presents the stored membership token + advances the
//     local cumulative tally + returns the hub's combined accounting;
//   * leaveSession marks the local membership inactive;
//   * the longitude baton claim/release routes;
//   * the SSE combined-preview stream is consumed (MockClient.streaming) and the
//     pure data-line parser decodes a frame.

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late SkotiqDatabase db;
  late CoImagingSessionsDao sessionsDao;
  late ConstellationContributionsDao contributionsDao;
  final hub = Uri.parse('https://hub.example.org');
  const hubKey = 'https://hub.example.org';

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    sessionsDao = CoImagingSessionsDao(db);
    contributionsDao = ConstellationContributionsDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  CoImagingSessionService serviceWith(
    MockClient mock, {
    CoImagingTileFuser? fuser,
    CoImagingContributionConsentResolver? consentResolver,
  }) => CoImagingSessionService(
    credentialsResolver: () async =>
        ConstellationCredentials(hubBaseUrl: hub, bearerToken: 'tok'),
    sessionsDao: sessionsDao,
    contributionsDao: contributionsDao,
    logger: LoggingService(),
    fusionContributor: fuser,
    consentResolver: consentResolver,
    clientFactory: (c) => ConstellationClient(
      hubBaseUrl: c.hubBaseUrl,
      bearerToken: c.bearerToken,
      client: mock,
    ),
  );

  /// A fuser that reports it deepened [tiles] tiles carrying [frames] frames /
  /// [seconds] of true pushed delta, so the new honest-accounting path has a
  /// concrete delta to report (and tests can assert it).
  CoImagingTileFuser fuserPushing({
    required int tiles,
    int frames = 1,
    double seconds = 60.0,
    void Function(CoImagingFusionRequest request)? onCall,
  }) => (request) async {
    onCall?.call(request);
    return CoImagingFusionResult(
      framesPushed: frames,
      integrationSecondsPushed: seconds,
      acceptedTiles: tiles,
    );
  };

  Map<String, Object?> sessionJson({
    required String id,
    String status = 'active',
    int combinedFrames = 0,
    List<Map<String, Object?>> participants = const [],
  }) => <String, Object?>{
    'sessionId': id,
    'ownerAccountId': 'acct-1',
    'targetName': 'M81',
    'centerRaDeg': 148.9,
    'centerDecDeg': 69.1,
    'sharedTargetId': 7,
    'status': status,
    'combinedFrames': combinedFrames,
    'combinedIntegrationSeconds': combinedFrames * 60.0,
    'activeTileId': 12345,
    'createdAt': '2026-01-01T00:00:00Z',
    'updatedAt': '2026-01-01T00:00:00Z',
    'participants': participants,
  };

  Map<String, Object?> participantJson({
    required int slot,
    String? token,
    String rigId = 'owner-rig',
    String role = 'admin',
  }) => <String, Object?>{
    'sessionId': 's1',
    'rigId': rigId,
    'role': role,
    if (token != null) 'membershipToken': token,
    'framingOffsetIndex': slot,
    'framingOffsetRaArcsec': slot * 30.0,
    'framingOffsetDecArcsec': 0.0,
    'contributedFrames': 0,
    'contributedIntegrationSeconds': 0.0,
    'active': true,
  };

  test('createSession persists the owner membership offset + token', () async {
    final mock = MockClient((request) async {
      expect(request.url.path, endsWith('/v1/coimaging/sessions'));
      return http.Response(
        jsonEncode(
          sessionJson(
            id: 's1',
            participants: [participantJson(slot: 0, token: 'mtok-owner')],
          ),
        ),
        201,
      );
    });

    final session = await serviceWith(mock).createSession(
      targetName: 'M81',
      raDeg: 148.9,
      decDeg: 69.1,
      rigId: 'owner-rig',
    );
    expect(session.sessionId, 's1');
    expect(session.combinedFrames, 0);

    final row = await sessionsDao.getSession(hubKey, 's1');
    expect(row, isNotNull);
    expect(row!.claimToken, 'mtok-owner');
    expect(row.framingOffsetIndex, 0);
    expect(row.targetName, 'M81');
    expect(row.active, isTrue);
  });

  test(
    'joinSession persists the hub-assigned framing offset + token',
    () async {
      final mock = MockClient((request) async {
        // A coordinate-less join self-heals the centre from a single live
        // GET on the same client before persisting the membership.
        if (request.method == 'GET' &&
            request.url.path.endsWith('/coimaging/sessions/s1')) {
          return http.Response(jsonEncode(sessionJson(id: 's1')), 200);
        }
        expect(request.url.path, contains('/join'));
        return http.Response(
          jsonEncode(participantJson(slot: 3, token: 'mtok-bob', rigId: 'bob')),
          200,
        );
      });

      final participant = await serviceWith(
        mock,
      ).joinSession('s1', rigId: 'bob');
      expect(participant.framingOffsetIndex, 3);
      expect(participant.membershipToken, 'mtok-bob');

      final row = await sessionsDao.getSession(hubKey, 's1');
      expect(row!.claimToken, 'mtok-bob');
      expect(row.framingOffsetIndex, 3);
      expect(row.framingOffsetRaArcsec, 90.0);
      // The centre was backfilled from the live session (none was passed).
      expect(row.targetRaDeg, closeTo(148.9, 1e-9));
      expect(row.targetDecDeg, closeTo(69.1, 1e-9));
    },
  );

  test(
    'recordContribution presents the stored token + advances local tally',
    () async {
      // Seed a stored membership with a token + a prior tally.
      await sessionsDao.upsertMembership(
        hubKey,
        's1',
        claimToken: 'mtok-1',
        framingOffsetIndex: 2,
        active: true,
      );
      await sessionsDao.updateProgress(
        hubKey,
        's1',
        contributedFrames: 4,
        contributedIntegrationSeconds: 240,
      );

      String? sentToken;
      Map<String, String>? sentQuery;
      final mock = MockClient((request) async {
        sentToken = request.headers['x-membership-token'];
        sentQuery = request.url.queryParameters;
        return http.Response(
          jsonEncode(<String, Object?>{
            'sessionId': 's1',
            'combinedFrames': 30,
            'combinedIntegrationSeconds': 1800.0,
            'participantCount': 2,
          }),
          200,
        );
      });

      final acc = await serviceWith(mock).recordContribution(
        's1',
        framesDelta: 6,
        integrationSecondsDelta: 360,
        rigId: 'bob',
      );
      expect(acc.combinedFrames, 30);
      expect(acc.participantCount, 2);
      // The stored membership token rode the request.
      expect(sentToken, 'mtok-1');
      expect(sentQuery!['framesDelta'], '6');
      expect(sentQuery!['rigId'], 'bob');

      // Local cumulative tally advanced by the delta (4 -> 10).
      final row = await sessionsDao.getSession(hubKey, 's1');
      expect(row!.contributedFrames, 10);
      expect(row.contributedIntegrationSeconds, 600);
    },
  );

  test('leaveSession marks the local membership inactive', () async {
    await sessionsDao.upsertMembership(hubKey, 's1', active: true);
    final mock = MockClient((request) async {
      expect(request.url.path, contains('/leave'));
      return http.Response(jsonEncode({'left': true}), 200);
    });
    final left = await serviceWith(mock).leaveSession('s1');
    expect(left, isTrue);
    final row = await sessionsDao.getSession(hubKey, 's1');
    expect(row!.active, isFalse);
  });

  test(
    'closeSession closes on the hub and marks membership inactive',
    () async {
      await sessionsDao.upsertMembership(hubKey, 's1', active: true);
      final mock = MockClient((request) async {
        expect(request.url.path, endsWith('/v1/coimaging/sessions/s1/close'));
        expect(request.method, 'POST');
        return http.Response(
          jsonEncode(sessionJson(id: 's1', status: 'closed')),
          200,
        );
      });
      final session = await serviceWith(mock).closeSession('s1');
      expect(session.status, 'closed');
      final row = await sessionsDao.getSession(hubKey, 's1');
      expect(row!.active, isFalse);
    },
  );

  test('baton claim returns null on 409, then a claim on 200', () async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls++;
      if (calls == 1) {
        return http.Response(jsonEncode({'error': 'held'}), 409);
      }
      return http.Response(
        jsonEncode({
          'targetId': 7,
          'claimToken': 'baton-1',
          'expiresAt': '2026-01-01T01:00:00Z',
        }),
        200,
      );
    });
    final svc = serviceWith(mock);
    expect(await svc.claimBaton('s1'), isNull); // another site holds it
    final claim = await svc.claimBaton('s1');
    expect(claim, isNotNull);
    expect(claim!.claimToken, 'baton-1');
  });

  test('listSessions decodes the active-session listing', () async {
    final mock = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'sessions': [
            sessionJson(id: 's1', combinedFrames: 12),
            sessionJson(id: 's2', combinedFrames: 0),
          ],
        }),
        200,
      );
    });
    final sessions = await serviceWith(mock).listSessions();
    expect(sessions, hasLength(2));
    expect(sessions.first.combinedFrames, 12);
  });

  test('the SSE combined-preview stream is consumed frame by frame', () async {
    final body = StringBuffer()
      ..write('event: snapshot\n')
      ..write(
        'data: ${jsonEncode({'type': 'snapshot', 'sessionId': 's1', 'combinedFrames': 0, 'combinedIntegrationSeconds': 0, 'participantCount': 1, 'activeTileId': 99})}\n\n',
      )
      ..write('event: combined-preview\n')
      ..write(
        'data: ${jsonEncode({'type': 'combined-preview', 'sessionId': 's1', 'combinedFrames': 7, 'combinedIntegrationSeconds': 420, 'participantCount': 2, 'activeTileId': 99, 'actorRigId': 'bob'})}\n\n',
      );
    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable([utf8.encode(body.toString())]),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    final events = <CoImagingPreview>[];
    await for (final e in serviceWith(mock).watchPreview('s1')) {
      events.add(e);
    }
    expect(events, hasLength(2));
    expect(events.first.type, 'snapshot');
    expect(events.last.type, 'combined-preview');
    expect(events.last.combinedFrames, 7);
    expect(events.last.actorRigId, 'bob');
  });

  test('parseSseDataLine ignores framing lines and decodes data frames', () {
    expect(ConstellationClient.parseSseDataLine('event: snapshot'), isNull);
    expect(ConstellationClient.parseSseDataLine(''), isNull);
    final p = ConstellationClient.parseSseDataLine(
      'data: ${jsonEncode({'type': 'combined-preview', 'sessionId': 'z', 'combinedFrames': 3})}',
    );
    expect(p, isNotNull);
    expect(p!.combinedFrames, 3);
    expect(p.sessionId, 'z');
  });

  // Framing-offset pointing

  MockClient throwingMock() => MockClient(
    (request) async => throw StateError(
      'no network expected for an offline framing-offset read: '
      '${request.url}',
    ),
  );

  test(
    'framingOffsetFor scales the RA arcsec by 1/cos(dec); slot 0 is zero',
    () async {
      // Non-anchor slot 3 (90" RA, 0" Dec) on a +60deg target.
      await sessionsDao.upsertMembership(
        hubKey,
        's1',
        targetName: 'M81',
        targetRaDeg: 148.9,
        targetDecDeg: 60.0,
        framingOffsetIndex: 3,
        framingOffsetRaArcsec: 90.0,
        framingOffsetDecArcsec: 0.0,
        active: true,
      );
      // Offline: the throwing mock proves no live round-trip is needed.
      final svc = serviceWith(throwingMock());
      final offset = await svc.framingOffsetFor('s1');
      expect(offset, isNotNull);
      // 90"/3600 = 0.025 deg, divided by cos(60deg)=0.5 -> 0.05 deg RA.
      expect(offset!.raDeg, closeTo(0.05, 1e-9));
      expect(offset.decDeg, closeTo(0.0, 1e-12));

      // Stable across "subs" (repeated reads return the same fixed tile).
      final again = await svc.framingOffsetFor('s1');
      expect(again!.raDeg, closeTo(0.05, 1e-9));

      // Anchor slot 0 -> no nudge.
      await sessionsDao.upsertMembership(
        hubKey,
        's2',
        targetDecDeg: 60.0,
        framingOffsetIndex: 0,
        framingOffsetRaArcsec: 0.0,
        framingOffsetDecArcsec: 0.0,
        active: true,
      );
      final anchor = await svc.framingOffsetFor('s2');
      expect(anchor!.raDeg, 0.0);
      expect(anchor.decDeg, 0.0);
    },
  );

  test(
    'framedCenterFor = session centre + this rig\'s framing offset',
    () async {
      await sessionsDao.upsertMembership(
        hubKey,
        's1',
        targetRaDeg: 148.9,
        targetDecDeg: 60.0,
        framingOffsetIndex: 3,
        framingOffsetRaArcsec: 90.0,
        framingOffsetDecArcsec: 36.0, // 0.01 deg Dec
        active: true,
      );
      final framed = await serviceWith(
        throwingMock(),
      ).framedCenterFor('s1', centerRaDeg: 148.9, centerDecDeg: 60.0);
      expect(framed!.raDeg, closeTo(148.9 + 0.05, 1e-9));
      expect(framed.decDeg, closeTo(60.0 + 0.01, 1e-9));
    },
  );

  test('framingOffsetFor returns null when not an active member', () async {
    expect(await serviceWith(throwingMock()).framingOffsetFor('nope'), isNull);
  });

  test('offsetDeltaDegrees is a pure cos(dec)-scaled conversion', () {
    final o = CoImagingSessionService.offsetDeltaDegrees(
      raArcsec: 90.0,
      decArcsec: 36.0,
      decDeg: 60.0,
    );
    expect(o.raDeg, closeTo(0.05, 1e-9));
    expect(o.decDeg, closeTo(0.01, 1e-9));
  });

  // Capture-loop auto-contribute

  test(
    'recordCompletedSub fuses, THEN reports accounting, THEN tags the tile',
    () async {
      final order = <String>[];
      String? sentFrames;
      String? sentSeconds;
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' &&
            path.endsWith('/coimaging/sessions/s1')) {
          order.add('getSession');
          return http.Response(
            jsonEncode(
              sessionJson(
                id: 's1',
                participants: [participantJson(slot: 0, token: 'mtok-owner')],
              ),
            ),
            200,
          );
        }
        if (request.method == 'POST' && path.endsWith('/contributions')) {
          order.add('record');
          sentFrames = request.url.queryParameters['framesDelta'];
          sentSeconds = request.url.queryParameters['integrationSecondsDelta'];
          return http.Response(
            jsonEncode(<String, Object?>{
              'sessionId': 's1',
              'combinedFrames': 11,
              'combinedIntegrationSeconds': 660.0,
              'participantCount': 2,
            }),
            200,
          );
        }
        return http.Response('unexpected ${request.method} $path', 500);
      });

      // Seed a stored membership token so the contribution gate is satisfied.
      await sessionsDao.upsertMembership(
        hubKey,
        's1',
        claimToken: 'mtok-owner',
        active: true,
      );

      var fuserCalls = 0;
      final svc = serviceWith(
        mock,
        fuser: fuserPushing(
          tiles: 2,
          frames: 3,
          seconds: 180.0,
          onCall: (request) {
            fuserCalls++;
            order.add('fuse');
            // The fuser sees the live session's shared-target + active tile.
            expect(request.sharedTargetId, 7);
            expect(request.activeTileId, 12345);
          },
        ),
      );

      final acc = await svc.recordCompletedSub(
        's1',
        exposureSeconds: 60.0,
        rigId: 'owner-rig',
      );
      expect(acc, isNotNull);
      expect(acc!.combinedFrames, 11);
      expect(fuserCalls, 1);
      // Honest accounting: the COMBINED report carries the TRUE delta the fuser
      // pushed (3 frames / 180 s), NOT the +1 / exposureSeconds the caller passed.
      expect(sentFrames, '3');
      expect(sentSeconds, '180.0');
      // Ordering: fuse BEFORE accounting (never claim depth not yet fused).
      expect(order.indexOf('fuse'), lessThan(order.indexOf('record')));
      // (c) the active tile was tagged with the session id.
      final row = await contributionsDao.getContribution(
        hubKey,
        12345,
        healpixOrder: ConstellationService.defaultHealpixOrder,
      );
      expect(row, isNotNull);
      expect(row!.sessionId, 's1');
    },
  );

  test(
    'recordCompletedSub does NOT advance accounting when fusion is empty',
    () async {
      var recorded = false;
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' &&
            path.endsWith('/coimaging/sessions/s1')) {
          return http.Response(jsonEncode(sessionJson(id: 's1')), 200);
        }
        if (request.method == 'POST' && path.endsWith('/contributions')) {
          recorded = true;
          return http.Response('{}', 200);
        }
        return http.Response('unexpected', 500);
      });
      await sessionsDao.upsertMembership(
        hubKey,
        's1',
        claimToken: 'mtok-owner',
        active: true,
      );

      final acc = await serviceWith(
        mock,
        fuser: fuserPushing(tiles: 0),
      ).recordCompletedSub('s1', exposureSeconds: 60.0);
      expect(acc, isNull); // guard tripped
      expect(recorded, isFalse); // no phantom depth reported
      final row = await sessionsDao.getSession(hubKey, 's1');
      expect(row!.contributedFrames, 0); // local tally not advanced either
    },
  );

  test('recordCompletedSub refuses a closed session', () async {
    final mock = MockClient((request) async {
      return http.Response(
        jsonEncode(sessionJson(id: 's1', status: 'closed')),
        200,
      );
    });
    expect(
      () => serviceWith(
        mock,
        fuser: fuserPushing(tiles: 1),
      ).recordCompletedSub('s1', exposureSeconds: 60.0),
      throwsA(isA<ConstellationException>()),
    );
  });

  // Altitude-driven longitude baton

  test(
    'observerAltitudeDegrees puts the celestial pole at altitude == lat',
    () {
      // A star at Dec +90 sits at altitude == observer latitude, for ALL times
      // and longitudes — a clean invariant for the altitude maths.
      final alt = CoImagingSessionService.observerAltitudeDegrees(
        latitudeDeg: 47.0,
        longitudeDeg: -122.0,
        raDeg: 0.0,
        decDeg: 90.0,
        atUtc: DateTime.utc(2026, 6, 30, 8),
      );
      expect(alt, closeTo(47.0, 1e-6));
    },
  );

  test(
    'evaluateBaton claims when the target is up, releases when it sets',
    () async {
      // A near-pole target (+89) is circumpolar above floor at lat +80; a
      // near-south target (-89) is always below — geometry, not clock.
      var claimed = false;
      var released = false;
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/baton/claim')) {
          claimed = true;
          return http.Response(
            jsonEncode({'targetId': 7, 'claimToken': 'baton-A'}),
            200,
          );
        }
        if (path.endsWith('/baton/release')) {
          released = true;
          return http.Response(jsonEncode({'released': true}), 200);
        }
        return http.Response('unexpected $path', 500);
      });

      // Up: persisted centre near the north pole.
      await sessionsDao.upsertMembership(
        hubKey,
        'up',
        targetRaDeg: 0.0,
        targetDecDeg: 89.0,
        active: true,
      );
      final upDec = await serviceWith(mock).evaluateBaton(
        'up',
        latitudeDeg: 80.0,
        longitudeDeg: 0.0,
        atUtc: DateTime.utc(2026, 6, 30, 6),
      );
      expect(upDec.aboveFloor, isTrue);
      expect(upDec.holdsBaton, isTrue);
      expect(claimed, isTrue);

      // Down: persisted centre near the south pole — never up at lat +80.
      await sessionsDao.upsertMembership(
        hubKey,
        'down',
        targetRaDeg: 0.0,
        targetDecDeg: -89.0,
        active: true,
      );
      final downDec = await serviceWith(mock).evaluateBaton(
        'down',
        latitudeDeg: 80.0,
        longitudeDeg: 0.0,
        atUtc: DateTime.utc(2026, 6, 30, 6),
      );
      expect(downDec.aboveFloor, isFalse);
      expect(released, isTrue);
    },
  );

  test('two sites hand the baton east exactly once; the combined stack keeps '
      'growing across the hand-off', () async {
    // One simulated hub baton holder + one combined frame tally shared by both
    // sites' fusers, proving the depth survives the longitude hand-off.
    String? holder; // null == free
    var combinedFrames = 0;

    MockClient hubFor(String site) => MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path.endsWith('/coimaging/sessions/s1')) {
        return http.Response(
          jsonEncode(sessionJson(id: 's1', combinedFrames: combinedFrames)),
          200,
        );
      }
      if (path.endsWith('/baton/claim')) {
        if (holder == null || holder == site) {
          holder = site;
          return http.Response(
            jsonEncode({'targetId': 7, 'claimToken': 'baton-$site'}),
            200,
          );
        }
        return http.Response(jsonEncode({'error': 'held'}), 409);
      }
      if (path.endsWith('/baton/release')) {
        if (holder == site) holder = null;
        return http.Response(jsonEncode({'released': true}), 200);
      }
      if (request.method == 'POST' && path.endsWith('/contributions')) {
        combinedFrames += 1;
        return http.Response(
          jsonEncode(<String, Object?>{
            'sessionId': 's1',
            'combinedFrames': combinedFrames,
            'combinedIntegrationSeconds': combinedFrames * 60.0,
            'participantCount': 2,
          }),
          200,
        );
      }
      return http.Response('unexpected $path', 500);
    });

    // Shared persisted centre + token for both sites (same hubKey/session).
    await sessionsDao.upsertMembership(
      hubKey,
      's1',
      targetRaDeg: 0.0,
      targetDecDeg: 89.0,
      claimToken: 'mtok',
      active: true,
    );

    final siteA = serviceWith(hubFor('A'), fuser: fuserPushing(tiles: 1));
    final siteB = serviceWith(hubFor('B'), fuser: fuserPushing(tiles: 1));

    // Site A is up first and claims; it images one sub into the shared stack.
    final aUp = await siteA.evaluateBaton(
      's1',
      latitudeDeg: 80.0,
      longitudeDeg: 0.0,
      atUtc: DateTime.utc(2026, 6, 30),
    );
    expect(aUp.holdsBaton, isTrue);
    expect(holder, 'A');
    await siteA.recordCompletedSub('s1', exposureSeconds: 60.0);
    expect(combinedFrames, 1);

    // Target sets at A (south-pole geometry forces release), baton frees.
    await sessionsDao.upsertMembership(hubKey, 's1', targetDecDeg: -89.0);
    final aDown = await siteA.evaluateBaton(
      's1',
      latitudeDeg: 80.0,
      longitudeDeg: 0.0,
      atUtc: DateTime.utc(2026, 6, 30),
    );
    expect(aDown.aboveFloor, isFalse);
    expect(holder, isNull);

    // Site B (east) is now up, claims exactly once, and DEEPENS THE SAME stack.
    await sessionsDao.upsertMembership(hubKey, 's1', targetDecDeg: 89.0);
    final bUp = await siteB.evaluateBaton(
      's1',
      latitudeDeg: 80.0,
      longitudeDeg: 0.0,
      atUtc: DateTime.utc(2026, 6, 30),
    );
    expect(bUp.holdsBaton, isTrue);
    expect(holder, 'B');
    await siteB.recordCompletedSub('s1', exposureSeconds: 60.0);
    expect(combinedFrames, 2); // the combined stack kept growing east
  });

  // Consent gate (fail closed)

  test('recordCompletedSub fails CLOSED with no consent on record', () async {
    var touchedHub = false;
    final mock = MockClient((request) async {
      touchedHub = true;
      return http.Response('unexpected ${request.url}', 500);
    });
    await sessionsDao.upsertMembership(
      hubKey,
      's1',
      claimToken: 'mtok-owner',
      active: true,
    );
    var fuserCalls = 0;
    final acc = await serviceWith(
      mock,
      fuser: fuserPushing(tiles: 2, onCall: (_) => fuserCalls++),
      // A wired resolver that returns null == "no consent on record".
      consentResolver: () async => null,
    ).recordCompletedSub('s1', exposureSeconds: 60.0);
    expect(acc, isNull); // refused
    expect(fuserCalls, 0); // nothing fused — nothing left the device
    expect(touchedHub, isFalse); // no hub round-trip at all
  });

  test('recordCompletedSub threads the persisted consent license + '
      'attribution into the fuser AND the combined report', () async {
    ContributionLicense? fuserLicense;
    bool? fuserAttribution;
    String? sentLicense;
    String? sentAttribution;
    final mock = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path.endsWith('/coimaging/sessions/s1')) {
        return http.Response(jsonEncode(sessionJson(id: 's1')), 200);
      }
      if (request.method == 'POST' && path.endsWith('/contributions')) {
        sentLicense = request.headers['license'];
        sentAttribution = request.headers['attributionconsent'];
        return http.Response(
          jsonEncode(<String, Object?>{
            'sessionId': 's1',
            'combinedFrames': 1,
            'combinedIntegrationSeconds': 60.0,
            'participantCount': 1,
          }),
          200,
        );
      }
      return http.Response('unexpected $path', 500);
    });
    await sessionsDao.upsertMembership(
      hubKey,
      's1',
      claimToken: 'mtok-owner',
      active: true,
    );
    final acc = await serviceWith(
      mock,
      fuser: (request) async {
        fuserLicense = request.license;
        fuserAttribution = request.attributionConsent;
        return const CoImagingFusionResult(
          framesPushed: 1,
          integrationSecondsPushed: 60.0,
          acceptedTiles: 1,
        );
      },
      // Operator chose a non-default license + anonymous attribution.
      consentResolver: () async =>
          (license: ContributionLicense.cc0, attributionConsent: false),
    ).recordCompletedSub('s1', exposureSeconds: 60.0);
    expect(acc, isNotNull);
    // The operator's actual choice rode the fuse AND the attribution ledger —
    // never a silent ccBy + public default.
    expect(fuserLicense, ContributionLicense.cc0);
    expect(fuserAttribution, isFalse);
    expect(sentLicense, ContributionLicense.cc0.wireName);
    expect(sentAttribution, 'false');
  });

  test('recordContribution fails CLOSED when a wired resolver has no '
      'consent record', () async {
    final mock = MockClient(
      (request) async =>
          throw StateError('no hub call expected: ${request.url}'),
    );
    await sessionsDao.upsertMembership(hubKey, 's1', active: true);
    await expectLater(
      () => serviceWith(
        mock,
        consentResolver: () async => null,
      ).recordContribution('s1', framesDelta: 1, integrationSecondsDelta: 60.0),
      throwsA(
        isA<ConstellationException>().having(
          (e) => e.kind,
          'kind',
          // A missing LOCAL consent is a device precondition, NOT a hub auth
          // failure: reported as `auth` the headless endpoint answers 401 and
          // the operator re-checks a bearer token that was never the problem.
          ConstellationErrorKind.conflict,
        ),
      ),
    );
  });

  test('recordContribution accepts an EXPLICIT consent with no record on '
      'file', () async {
    // The headless `/contribute` endpoint has no sheet to present and no way to
    // persist a consent, so a per-request license + attribution pair has to be
    // enough on its own — otherwise an unattended rig can never contribute.
    String? sentLicense;
    String? sentAttribution;
    final mock = MockClient((request) async {
      sentLicense = request.headers['license'];
      sentAttribution = request.headers['attributionConsent'];
      return http.Response(
        jsonEncode({
          'sessionId': 's1',
          'combinedFrames': 7,
          'combinedIntegrationSeconds': 2100.0,
          'participantCount': 2,
        }),
        200,
      );
    });
    await sessionsDao.upsertMembership(hubKey, 's1', active: true);

    final acc = await serviceWith(mock, consentResolver: () async => null)
        .recordContribution(
          's1',
          framesDelta: 1,
          integrationSecondsDelta: 60.0,
          license: ContributionLicense.ccBy,
          attributionConsent: false,
        );

    expect(acc.combinedFrames, 7);
    expect(sentLicense, 'cc-by');
    expect(sentAttribution, 'false');
  });

  // Point-matched framing for the centring/slew path

  test('framedCenterForPoint applies the offset for a covering session, '
      'null otherwise', () async {
    await sessionsDao.upsertMembership(
      hubKey,
      's1',
      targetName: 'M81',
      targetRaDeg: 148.9,
      targetDecDeg: 60.0,
      framingOffsetIndex: 3,
      framingOffsetRaArcsec: 90.0,
      framingOffsetDecArcsec: 36.0,
      active: true,
    );
    final svc = serviceWith(throwingMock());
    // A slew target on the session centre resolves to centre + offset.
    final framed = await svc.framedCenterForPoint(
      centerRaDeg: 148.9,
      centerDecDeg: 60.0,
    );
    expect(framed, isNotNull);
    expect(framed!.raDeg, closeTo(148.9 + 0.05, 1e-9));
    expect(framed.decDeg, closeTo(60.0 + 0.01, 1e-9));
    // A point far from any joined session leaves pointing untouched.
    final none = await svc.framedCenterForPoint(
      centerRaDeg: 10.0,
      centerDecDeg: -20.0,
    );
    expect(none, isNull);
  });

  test('angularSeparationDegrees is symmetric and zero on identity', () {
    expect(
      CoImagingSessionService.angularSeparationDegrees(10, 20, 10, 20),
      closeTo(0.0, 1e-9),
    );
    expect(
      CoImagingSessionService.angularSeparationDegrees(0, 0, 0, 90),
      closeTo(90.0, 1e-6),
    );
  });

  // The longitude-baton scheduler tick

  test('CoImagingBatonScheduler claims an up target and reconciles it as HELD, '
      'releases + reconciles it as RELEASED when it sets', () async {
    String? holder;
    final mock = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path.endsWith('/coimaging/sessions/s1')) {
        return http.Response(jsonEncode(sessionJson(id: 's1')), 200);
      }
      if (path.endsWith('/baton/claim')) {
        holder = 'me';
        return http.Response(
          jsonEncode({'targetId': 7, 'claimToken': 'baton-1'}),
          200,
        );
      }
      if (path.endsWith('/baton/release')) {
        holder = null;
        return http.Response(jsonEncode({'released': true}), 200);
      }
      return http.Response('unexpected $path', 500);
    });
    final svc = serviceWith(mock);
    await sessionsDao.upsertMembership(
      hubKey,
      's1',
      targetRaDeg: 0.0,
      targetDecDeg: 89.0, // near north pole — up at lat +80
      claimToken: 'mtok',
      active: true,
    );

    CoImagingBatonReconciliation? last;
    final scheduler = CoImagingBatonScheduler(
      service: svc,
      logger: LoggingService(),
      siteResolver: () async => (latitudeDeg: 80.0, longitudeDeg: 0.0),
      onReconcile: (r) async => last = r,
    );

    // Target up -> claim + reconciled as held.
    await scheduler.tickOnce();
    expect(holder, 'me');
    expect(last!.held.map((r) => r.sessionId), ['s1']);
    expect(last!.released, isEmpty);
    expect(last!.anyHeld, isTrue);

    // Target sets -> release + reconciled as released.
    await sessionsDao.upsertMembership(hubKey, 's1', targetDecDeg: -89.0);
    await scheduler.tickOnce();
    expect(holder, isNull);
    expect(last!.held, isEmpty);
    expect(last!.released.map((r) => r.sessionId), ['s1']);
    expect(last!.anyHeld, isFalse);

    scheduler.stop();
  });

  test('two memberships reconcile into ONE held + ONE released split per tick, '
      'never per-membership callbacks', () async {
    final mock = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path.endsWith('/coimaging/sessions/up')) {
        return http.Response(jsonEncode(sessionJson(id: 'up')), 200);
      }
      if (request.method == 'GET' &&
          path.endsWith('/coimaging/sessions/down')) {
        return http.Response(jsonEncode(sessionJson(id: 'down')), 200);
      }
      if (path.contains('/up/baton/claim')) {
        return http.Response(
          jsonEncode({'targetId': 7, 'claimToken': 'baton-up'}),
          200,
        );
      }
      // 'down' claims fail (target set) / releases succeed; 'up' releases n/a.
      if (path.endsWith('/baton/claim')) {
        return http.Response(jsonEncode({'detail': 'held'}), 409);
      }
      if (path.endsWith('/baton/release')) {
        return http.Response(jsonEncode({'released': true}), 200);
      }
      return http.Response('unexpected $path', 500);
    });
    final svc = serviceWith(mock);
    // 'up' is near the pole (up at lat +80); 'down' is the far south pole.
    await sessionsDao.upsertMembership(
      hubKey,
      'up',
      targetRaDeg: 0.0,
      targetDecDeg: 89.0,
      claimToken: 'mtok-up',
      active: true,
    );
    await sessionsDao.upsertMembership(
      hubKey,
      'down',
      targetRaDeg: 0.0,
      targetDecDeg: -89.0,
      claimToken: 'mtok-down',
      active: true,
    );

    CoImagingBatonReconciliation? last;
    final scheduler = CoImagingBatonScheduler(
      service: svc,
      logger: LoggingService(),
      siteResolver: () async => (latitudeDeg: 80.0, longitudeDeg: 0.0),
      onReconcile: (r) async => last = r,
    );

    await scheduler.tickOnce();
    // A single reconciliation carries both: 'up' held, 'down' released — the
    // engine layer sees one deterministic decision, not two fighting callbacks.
    expect(last!.held.map((r) => r.sessionId), ['up']);
    expect(last!.released.map((r) => r.sessionId), ['down']);
    expect(last!.anyHeld, isTrue);

    scheduler.stop();
  });

  test(
    'headless coordinate-less join self-heals the centre so the in-process '
    'auto-contribute (membershipsForPoint) matches the folded frame',
    () async {
      // Mirrors the headless REST join path: joinSession is called with ONLY the
      // session id (no target coordinates). The membership must still carry the
      // centre so membershipsForPoint — the Gap-2 auto-contribute filter — can
      // attribute a folded sub to the session.
      final mock = MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path.endsWith('/coimaging/sessions/s1')) {
          return http.Response(jsonEncode(sessionJson(id: 's1')), 200);
        }
        if (request.url.path.endsWith('/join')) {
          return http.Response(
            jsonEncode(participantJson(slot: 2, token: 'mtok-headless')),
            200,
          );
        }
        return http.Response('unexpected ${request.url.path}', 500);
      });
      final svc = serviceWith(mock);

      // Coordinate-less join (the headless handler passes no centre).
      await svc.joinSession('s1');

      // The durable row carries the backfilled centre.
      final row = await sessionsDao.getSession(hubKey, 's1');
      expect(row!.targetRaDeg, closeTo(148.9, 1e-9));
      expect(row.targetDecDeg, closeTo(69.1, 1e-9));

      // A frame folded at (near) the session centre matches the membership; a
      // null-coordinate row would be silently excluded.
      final matches = await svc.membershipsForPoint(
        raDeg: 148.95,
        decDeg: 69.05,
      );
      expect(matches.map((r) => r.sessionId), ['s1']);
    },
  );
}

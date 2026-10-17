// Pillar C ("Constellation") — Wave 0 substrate keystone: contribution
// high-water / true-delta export + repeat-contribute idempotency, and the
// pull-side high-water (re-pull does not re-inflate community depth).
//
// These pin the three Pillar-C data-corruption bugs the overlay split + the
// constellation_contributions receipt table fix:
//   * repeat-contribute with no new imaging ships an EMPTY delta (no push),
//   * contribute after one new night ships only that night's frames (true delta),
//   * a pulled community tile is never re-shipped as the user's own (overlay),
//   * re-pulling the same field leaves the overlay at exactly one community copy.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';

/// Recording seam. `coverage` reports one own-light tile in the cone;
/// `exportDelta` returns a configurable post-anchor own-light tally so the test
/// can drive the empty-delta and true-delta branches; `mergeDelta` reports the
/// pulled community depth (REPLACE-not-add, so the overlay total is stable).
class _RecordingSeam implements SkyAtlasSeam {
  _RecordingSeam({
    required this.ownFrames,
    required this.ownSeconds,
    this.exportFrames = 0,
    this.exportSeconds = 0,
    this.mergeFrames = 7,
  });

  int ownFrames;
  double ownSeconds;
  int exportFrames;
  double exportSeconds;
  int mergeFrames;

  final List<Map<String, dynamic>> exports = [];
  final List<Map<String, dynamic>> merged = [];

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    switch (args['action']) {
      case 'coverage':
        return {
          'ok': true,
          'tiles': [
            {
              'tileId': 1234,
              'centerRa': 83.6,
              'centerDec': -5.4,
              'coverageMean': 0.8,
              'totalFrames': ownFrames,
              'integrationSeconds': ownSeconds,
              'channels': 1,
            },
          ],
        };
      case 'exportDelta':
        exports.add(args);
        // The push path reads the delta file off disk, so materialize a stub.
        final outPath = args['outPath'] as String;
        final f = File(outPath);
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(const [1, 2, 3, 4]);
        return {
          'ok': true,
          'outPath': outPath,
          'framesInDelta': exportFrames,
          'integrationSeconds': exportSeconds,
        };
      case 'info':
        return {
          'ok': true,
          'centerRa': 83.6,
          'centerDec': -5.4,
          'channels': 1,
          'coverageMean': 0.9,
          'provenance': {'totalFrames': mergeFrames, 'contributors': []},
        };
      default:
        return {'ok': true};
    }
  }

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async {
    merged.add(args);
    return {
      'ok': true,
      'totalFramesAfter': mergeFrames,
      'integrationSecondsAfter': 1500.0,
      'contributorsAfter': 2,
    };
  }

  @override
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) async => {
    'ok': true,
  };
}

void main() {
  late SkotiqDatabase db;
  late SkyAtlasDao atlasDao;
  late ConstellationContributionsDao contributionsDao;

  const target = SharedTarget(
    targetId: 7,
    name: 'Orion',
    raDeg: 83.6,
    decDeg: -5.4,
    contributors: 3,
    integrationSeconds: 7200.0,
    activeTileId: 1234,
  );

  // Records every push body so the test can assert the wire framesDelta.
  late List<int> pushedFramesDelta;
  late int pushCount;

  ConstellationService buildService(_RecordingSeam seam) {
    final atlas = SkyAtlasService(
      dao: atlasDao,
      seam: seam,
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/constellation_highwater_test',
      order: ConstellationService.defaultHealpixOrder,
    );
    return ConstellationService(
      atlas: atlas,
      logger: LoggingService(),
      contributionsDao: contributionsDao,
      credentialsResolver: () async => ConstellationCredentials(
        hubBaseUrl: Uri.parse('https://hub.example.org/'),
        bearerToken: 'tok',
      ),
      localTargetsResolver: () async => const [],
      clientFactory: (creds) {
        final mock = MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.contains('/contributions')) {
            pushCount++;
            pushedFramesDelta.add(
              int.parse(request.headers['framesDelta'] ?? '0'),
            );
            // Model what the hub actually returns: it answers 200 for BOTH
            // outcomes and distinguishes them with an `accepted` flag
            // (hub_server.dart `_contributeHandler`). Omitting the flag
            // describes a hub that does not exist, and
            // `ContributionReceipt.fromJson` defaults a missing `accepted` to
            // false — a fixture that models a REJECTION while the test asserts
            // acceptance.
            return http.Response(
              jsonEncode({
                'contributionId': 'ctr-$pushCount',
                'tileId': 1234,
                'order': 9,
                'accepted': true,
                'totalFramesAfter': 100 + pushCount,
              }),
              200,
            );
          }
          // pullTile GET: a tiny accumulator blob.
          return http.Response.bytes([1, 2, 3, 4], 200);
        });
        return ConstellationClient(
          hubBaseUrl: creds.hubBaseUrl,
          bearerToken: creds.bearerToken,
          client: mock,
        );
      },
    );
  }

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    atlasDao = SkyAtlasDao(db);
    contributionsDao = ConstellationContributionsDao(db);
    pushedFramesDelta = [];
    pushCount = 0;
  });

  tearDown(() => db.close());

  test(
    'contribute-after-new-night ships the TRUE delta, not the whole tile total',
    () async {
      // Own-light tile total is 10 frames, but only 4 are post-anchor (new
      // night). The wire framesDelta must be 4, never 10.
      final seam = _RecordingSeam(
        ownFrames: 10,
        ownSeconds: 3000,
        exportFrames: 4,
        exportSeconds: 1200,
      );
      final service = buildService(seam)..joinSharedTarget(target);

      final outcome = await service.contributeTarget(target.targetId);

      expect(outcome.acceptedCount, 1);
      expect(pushedFramesDelta, [4]); // true delta, not 10
      // The high-water receipt was stamped with the remote id + the new anchor.
      final receipt = await contributionsDao.getContribution(
        'https://hub.example.org',
        1234,
        healpixOrder: 9,
      );
      expect(receipt, isNotNull);
      expect(receipt!.contributionId, 'ctr-1');
      expect(receipt.lastContributedAt, isNotNull);
      expect(receipt.contributedFrames, 4);
    },
  );

  test(
    'repeat-contribute with no new imaging ships an EMPTY delta (no push)',
    () async {
      // First contribute ships 4 new frames.
      final seam = _RecordingSeam(
        ownFrames: 10,
        ownSeconds: 3000,
        exportFrames: 4,
        exportSeconds: 1200,
      );
      final service = buildService(seam)..joinSharedTarget(target);
      await service.contributeTarget(target.targetId);
      expect(pushCount, 1);

      // Nothing new imaged since: the native export now reports 0 post-anchor
      // frames. The service must skip the push (no hub mutation).
      seam.exportFrames = 0;
      seam.exportSeconds = 0;
      final outcome = await service.contributeTarget(target.targetId);

      expect(pushCount, 1); // unchanged — no second push
      expect(outcome.acceptedCount, 0);
      expect(outcome.rejectedCount, 0);
    },
  );

  test(
    'pull writes the overlay only — contribute never ships community frames',
    () async {
      // The user has NOT imaged this tile (own-light total 0). A pull blends the
      // community depth into the overlay; a subsequent contribute exports the
      // base (0 own frames) and must therefore push nothing.
      final seam = _RecordingSeam(
        ownFrames: 0,
        ownSeconds: 0,
        exportFrames: 0,
        exportSeconds: 0,
        mergeFrames: 7,
      );
      final service = buildService(seam)..joinSharedTarget(target);

      await service.pullTarget(target.targetId, finalized: false);
      // The blend went to the swarm overlay tree, never the own-light base.
      expect(seam.merged, hasLength(1));
      expect(
        seam.merged.single['basePath'],
        contains('swarm_overlay/tiles/9/1234.skt'),
      );

      final outcome = await service.contributeTarget(target.targetId);
      // No own-light frames -> empty export -> no push (community photons stay
      // on the hub, never re-shipped as ours).
      expect(pushCount, 0);
      expect(outcome.acceptedCount, 0);
    },
  );

  test(
    'C-base-index-unchanged-by-pull: own-light total survives a pull',
    () async {
      // The user HAS imaged this tile (own-light total 6); the contribution bar
      // reads own-light frames. A pull blends community depth into the OVERLAY
      // columns and must leave the own-light total — the contribution figure —
      // unchanged, so the bar does not lie after a pull.
      final seam = _RecordingSeam(
        ownFrames: 6,
        ownSeconds: 1800,
        exportFrames: 0,
        exportSeconds: 0,
        mergeFrames: 7,
      );
      final service = buildService(seam)..joinSharedTarget(target);

      // Seed the base index row with own-light depth (what contribute would see).
      await atlasDao.upsertTile(
        tileId: 1234,
        healpixOrder: 9,
        channels: 1,
        centerRaDeg: 83.6,
        centerDecDeg: -5.4,
        coverageMean: 0.8,
        totalFrames: 6,
        integrationSeconds: 1800,
        sidecarPath: '/tmp/constellation_highwater_test/tiles/9/1234.skt',
      );

      await service.pullTarget(target.targetId, finalized: false);

      final tile = await atlasDao.getTile(1234, healpixOrder: 9);
      // Own-light totals (the contribution-bar figure) are UNCHANGED.
      expect(tile!.totalFrames, 6);
      expect(tile.integrationSeconds, 1800);
      // The community depth landed only in the overlay columns.
      expect(tile.swarmOverlayFrames, 7);
    },
  );

  test('re-pull is idempotent: overlay frames stable across two pulls', () async {
    final seam = _RecordingSeam(ownFrames: 0, ownSeconds: 0, mergeFrames: 7);
    final service = buildService(seam)..joinSharedTarget(target);

    final first = await service.pullTarget(target.targetId, finalized: false);
    final second = await service.pullTarget(target.targetId, finalized: false);

    // Replace-not-add: both pulls leave exactly one copy of the community depth.
    expect(first.single.totalFrames, 7);
    expect(second.single.totalFrames, 7);
    final tile = await atlasDao.getTile(1234, healpixOrder: 9);
    expect(tile!.swarmOverlayFrames, 7);
    // Own-light totals stay zero — the pull never inflates the contribution bar.
    expect(tile.totalFrames, 0);
    // The pulled high-water was recorded.
    final receipt = await contributionsDao.getPulledHighWater(
      'https://hub.example.org',
      1234,
      healpixOrder: 9,
    );
    expect(receipt!.lastPulledFrames, 7);
  });
}

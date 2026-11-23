// The live stack's engine settings and tally against the FRB types: built
// with named arguments (a required field Rust adds or drops stops this
// compiling) and compared with the generated field lists, so an engine field
// reaches the model, the bridge and the host's wire body together.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/models/imaging/live_stacking_models.dart';

import '../../harness/frb_contract.dart';

const _config = LiveStackingConfig(
  sigmaClipEnabled: false,
  sigmaClipThreshold: 3.25,
  maxMatchStars: 150,
  matchRadiusPx: 42.5,
  matchFluxTolerance: 0.55,
  minMatchedPairs: 7,
  maxAlignmentResidualPx: 1.25,
  starDetectionSigma: 3.5,
  starDetectionMinSnr: 6.5,
  separateByFilter: false,
  autoFeedEnabled: false,
  maxHfrPx: 4.5,
  minStarCount: 30,
  sensorMode: 'osc',
  bayerPattern: 'GRBG',
  demosaicQuality: 'vng',
);

void main() {
  test('every engine setting reaches the bridge config', () {
    expect(
      _config.toBridge(),
      const bridge.ApiLiveStackingConfig(
        sigmaClipEnabled: false,
        sigmaClipThreshold: 3.25,
        maxMatchStars: 150,
        matchRadiusPx: 42.5,
        matchFluxTolerance: 0.55,
        minMatchedPairs: 7,
        maxAlignmentResidualPx: 1.25,
        starDetectionSigma: 3.5,
        starDetectionMinSnr: 6.5,
        sensorMode: 'osc',
        bayerPattern: 'GRBG',
        demosaicQuality: 'vng',
      ),
    );
  });

  // The engine's settings, and the feeder's gates the host applies to the
  // frames of its run.
  test('the host wire body carries the engine settings and the feeder '
      'gates', () {
    expect(_config.toWireJson().keys.toSet(), {
      ...frbFields('api/live_stacking.dart', 'ApiLiveStackingConfig'),
      'separateByFilter',
      'autoFeedEnabled',
      'maxHfrPx',
      'minStarCount',
    });
  });

  test('the engine tally reaches the model and its JSON', () {
    final stats = LiveStackingStats.fromBridge(
      bridge.ApiLiveStackingStats(
        stackedFrameCount: 12,
        totalFramesAttempted: 15,
        rejectedAlignmentFailures: 2,
        avgMatchedPairs: 31.5,
        avgAlignmentResidual: 0.42,
        totalSigmaRejectedPixels: BigInt.from(98765),
        totalIntegrationSecs: 3600.5,
        filter: 'Ha',
        otherFilterFrames: 1,
        lastOtherFilter: 'OIII',
      ),
    );
    final json = {
      'stackedFrameCount': 12,
      'totalFramesAttempted': 15,
      'rejectedAlignmentFailures': 2,
      'avgMatchedPairs': 31.5,
      'avgAlignmentResidual': 0.42,
      'totalSigmaRejectedPixels': 98765,
      'totalIntegrationSecs': 3600.5,
      'filter': 'Ha',
      'otherFilterFrames': 1,
      'lastOtherFilter': 'OIII',
    };
    expect(stats.toJson(), json);
    expect(LiveStackingStats.fromJson(json).toJson(), json);
    expect(
      frbFields('api/live_stacking.dart', 'ApiLiveStackingStats'),
      json.keys.toSet(),
    );
  });
}

// Moving-object linking on real star lists: eight consecutive dithered NGC 891
// subs (L/R/G/B rotation, 2026-10-24) with Skotiq's own detections, placed on
// the sky through each frame's plate solve. Linking by pixel read the dither
// between subs as motion and flagged the whole field (40 candidates per frame,
// 94-99% of them static stars); on the sky the field stands still.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/science/science_models.dart';
import 'package:skotiq_core/src/services/science/moving_object_linker.dart';
import 'package:skotiq_core/src/services/science/mpc_export_service.dart';

List<MovingObjectFrameDetections> _loadFixture() {
  final file = File('test/fixtures/moving_objects_ngc891_dithered.csv');
  final byFrame = <String, (DateTime, List<MovingObjectDetection>)>{};
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('#') || line.startsWith('frame,')) continue;
    final f = line.split(',');
    final entry = byFrame.putIfAbsent(
      f[0],
      () => (DateTime.parse(f[1]), <MovingObjectDetection>[]),
    );
    entry.$2.add(
      MovingObjectDetection(
        raDegrees: double.parse(f[2]),
        decDegrees: double.parse(f[3]),
        x: double.parse(f[4]),
        y: double.parse(f[5]),
        flux: double.parse(f[6]),
        snr: double.parse(f[7]),
      ),
    );
  }
  return [
    for (final e in byFrame.values)
      MovingObjectFrameDetections(midExposureUtc: e.$1, detections: e.$2),
  ]..sort((a, b) => a.midExposureUtc.compareTo(b.midExposureUtc));
}

/// Copy of [frames] with one extra detection per frame on a straight line:
/// [rate] arcsec/min toward position angle [paDeg] from ([ra0], [dec0]) at the
/// first frame's time. Pixel positions follow the sky so the mover is not a
/// sensor defect.
List<MovingObjectFrameDetections> _withMover(
  List<MovingObjectFrameDetections> frames, {
  required double ra0,
  required double dec0,
  required double rate,
  required double paDeg,
  Set<int> skipFrames = const {},
}) {
  final t0 = frames.first.midExposureUtc;
  final pa = paDeg * math.pi / 180;
  return [
    for (var i = 0; i < frames.length; i++)
      MovingObjectFrameDetections(
        midExposureUtc: frames[i].midExposureUtc,
        detections: [
          ...frames[i].detections,
          if (!skipFrames.contains(i))
            () {
              final minutes =
                  frames[i].midExposureUtc.difference(t0).inMilliseconds /
                  60000.0;
              final d = rate * minutes / 3600.0;
              return MovingObjectDetection(
                raDegrees:
                    ra0 + d * math.sin(pa) / math.cos(dec0 * math.pi / 180),
                decDegrees: dec0 + d * math.cos(pa),
                x: 2000 + minutes * 3,
                y: 1500 + minutes * 2,
                flux: 9000,
                snr: 12,
              );
            }(),
        ],
      ),
  ];
}

void main() {
  final frames = _loadFixture();
  final center = frames.first.detections[frames.first.detections.length ~/ 2];

  test('the fixture holds eight dithered subs over about 20 minutes', () {
    expect(frames, hasLength(8));
    final span = frames.last.midExposureUtc.difference(
      frames.first.midExposureUtc,
    );
    expect(span.inMinutes, greaterThan(10));
  });

  test('a dithered static field yields no moving objects', () {
    expect(linkMovingObjects(frames, const MovingObjectOptions()), isEmpty);
  });

  test('a slow main-belt mover across the real field is found', () {
    final withMover = _withMover(
      frames,
      ra0: center.raDegrees + 0.004,
      dec0: center.decDegrees + 0.003,
      rate: 0.6,
      paDeg: 250,
    );
    final found = linkMovingObjects(withMover, const MovingObjectOptions());
    expect(found, hasLength(1));
    expect(found.single.motionArcsecPerMinute, closeTo(0.6, 0.08));
    expect(found.single.positionAngleDegrees, closeTo(250, 5));
    expect(found.single.epochUtc, frames.last.midExposureUtc);
    expect(found.single.frameCount, 8);
  });

  test('a mover missed in two frames is still linked', () {
    final withMover = _withMover(
      frames,
      ra0: center.raDegrees - 0.003,
      dec0: center.decDegrees + 0.002,
      rate: 2.0,
      paDeg: 40,
      skipFrames: {1, 4},
    );
    final found = linkMovingObjects(withMover, const MovingObjectOptions());
    expect(found, hasLength(1));
    expect(found.single.motionArcsecPerMinute, closeTo(2.0, 0.15));
  });

  test('a hot pixel carried along by the dithers is not a mover', () {
    // Fixed detector pixel, so its sky position steps with the dither.
    final first = frames.first.detections.first;
    final hot = [
      for (final f in frames)
        MovingObjectFrameDetections(
          midExposureUtc: f.midExposureUtc,
          detections: [
            ...f.detections,
            MovingObjectDetection(
              // A sky track that is linear in time, the worst case for a
              // defect: only its fixed pixel gives it away.
              raDegrees:
                  first.raDegrees +
                  0.0003 *
                      f.midExposureUtc
                          .difference(frames.first.midExposureUtc)
                          .inMilliseconds /
                      60000.0,
              decDegrees: first.decDegrees + 0.01,
              x: 3000,
              y: 1100,
              flux: 5000,
              snr: 15,
            ),
          ],
        ),
    ];
    expect(linkMovingObjects(hot, const MovingObjectOptions()), isEmpty);
    // The pixel guard is what rejects it: its sky track alone is linear.
    expect(
      linkMovingObjects(
        hot,
        const MovingObjectOptions(pixelStaticTolerance: 0),
      ),
      hasLength(1),
    );
  });

  test('fewer than three frames never produce a candidate', () {
    final two = frames.take(2).toList();
    expect(linkMovingObjects(two, const MovingObjectOptions()), isEmpty);
  });

  test('a later frame of the same object keeps its candidate id', () {
    final epoch = DateTime.utc(2026, 10, 24, 1, 30);
    final earlier = (
      candidateId: 'mo_first',
      raDegrees: 35.6,
      decDegrees: 42.3,
      rateArcsecPerMinute: 1.0,
      positionAngleDegrees: 90.0,
      timestamp: epoch,
    );
    final tenMinLater = MovingObjectMatch(
      candidateId: 'mo_new',
      // 10" east of the earlier position.
      raDegrees: 35.6 + 10 / 3600 / math.cos(42.3 * math.pi / 180),
      decDegrees: 42.3,
      motionArcsecPerMinute: 1.05,
      positionAngleDegrees: 91,
      confidence: 0.8,
      epochUtc: epoch.add(const Duration(minutes: 10)),
    );
    expect(continuedCandidateId(tenMinLater, [earlier]), 'mo_first');
    final elsewhere = MovingObjectMatch(
      candidateId: 'mo_other',
      raDegrees: 35.7,
      decDegrees: 42.3,
      motionArcsecPerMinute: 1.0,
      positionAngleDegrees: 90,
      confidence: 0.8,
      epochUtc: epoch.add(const Duration(minutes: 10)),
    );
    expect(continuedCandidateId(elsewhere, [earlier]), 'mo_other');
  });

  test('the reported band follows the filter', () {
    expect(mpcBandForFilter('L'), 'C');
    expect(mpcBandForFilter('R'), 'R');
    expect(mpcBandForFilter('G'), 'V');
    expect(mpcBandForFilter('B'), 'B');
    expect(mpcBandForFilter('Ha'), isNull);
    expect(mpcBandForFilter(null), 'C');
  });
}

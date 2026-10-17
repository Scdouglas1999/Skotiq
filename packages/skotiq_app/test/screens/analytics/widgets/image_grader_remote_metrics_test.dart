import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/image_grader_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('companion grader loads and groups PSF metrics from the host', () async {
    final frame = _frame(7);
    final backend = _PsfBackend([
      _tile(id: 1, imageId: 7, fwhm: 2.0, eccentricity: 0.4),
      _tile(id: 2, imageId: 7, fwhm: 4.0, eccentricity: 0.6),
      _tile(id: 3, imageId: 99, fwhm: 20.0, eccentricity: 0.9),
    ]);

    final metrics = await loadImageGraderPsfMetrics(
      backend: backend,
      localScienceDao: null,
      frames: [frame],
      sessionId: 42,
    );

    expect(backend.requestedSessionId, 42);
    expect(metrics.keys, [7]);
    expect(metrics[7]?.fwhm, 3.0);
    expect(metrics[7]?.eccentricity, 0.5);
    expect(
      const FrameGradeRules(maxFwhm: 2.5, maxEccentricity: 0.45).gradeFrame(
        frame,
        fwhm: metrics[7]?.fwhm,
        eccentricity: metrics[7]?.eccentricity,
      ),
      contains('FWHM 3.00 > 2.50'),
    );
  });

  test('saved rules win and empty settings consistently use suggestions', () {
    final frame = _frame(7);
    final saved = resolveImageGraderRules(
      ScienceSettings(
        frameGradeRulesJson: const FrameGradeRules(
          maxFwhm: 2.4,
        ).toJsonString(),
      ),
      [frame],
    );
    final suggested = resolveImageGraderRules(
      const ScienceSettings(),
      [frame],
    );

    expect(saved.maxFwhm, 2.4);
    expect(suggested.maxHfr, frame.hfr);
    expect(suggested.minStars, frame.starCount);
    expect(suggested.maxGuidingRmsTotalArcsec, frame.guidingRmsTotal);
  });
}

DbCapturedImage _frame(int id) => DbCapturedImage(
      id: id,
      filePath: '/tmp/light-$id.fits',
      fileName: 'light-$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 13),
      createdAt: DateTime.utc(2026, 7, 13),
      isAccepted: true,
      isPlateSolved: false,
      hfr: 2.5,
      starCount: 50,
      guidingRmsTotal: 0.8,
    );

PsfFieldTileRow _tile({
  required int id,
  required int imageId,
  required double fwhm,
  required double eccentricity,
}) =>
    PsfFieldTileRow(
      id: id,
      capturedImageId: imageId,
      sessionId: 42,
      tileRow: 0,
      tileCol: id,
      starCount: 20,
      medianFwhm: fwhm,
      medianHfr: fwhm / 2,
      medianEccentricity: eccentricity,
      roundness: 1 - eccentricity,
      timestamp: DateTime.utc(2026, 7, 13),
    );

class _PsfBackend extends NetworkBackend {
  final List<PsfFieldTileRow> tiles;
  int? requestedSessionId;

  _PsfBackend(this.tiles)
      : super(serverHost: '127.0.0.1', autoConnectWebSocket: false);

  @override
  Future<List<PsfFieldTileRow>> getSessionPsfTiles(int sessionId) async {
    requestedSessionId = sessionId;
    return tiles;
  }
}

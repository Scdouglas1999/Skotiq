// Science writeback contract test.
//
// The science processing pipeline's writeback builds a list of
// `FitsKeywordWrite` from a `FramePhotometricCalibration` and a
// `TransparencySample` (`ScienceProcessingService.buildScienceWritebackKeywords`)
// and hands it to the native frame header writer, which external tools
// (PixInsight, AstroPixelProcessor, Siril) read the frame through. Renaming a
// keyword, swapping a unit or dropping the SKHA_VER provenance stamp fails
// this test loudly.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

FitsKeywordWrite _card(List<FitsKeywordWrite> updates, String keyword) =>
    updates.singleWhere((u) => u.keyword == keyword);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'full pipeline contract: calibration + transparency round-trip',
    () async {
      final cal = FramePhotometricCalibration(
        capturedImageId: 42,
        sessionId: 7,
        timestamp: DateTime.utc(2026, 1, 1, 22, 30),
        isCalibrated: true,
        zeroPoint: 24.317,
        limitingMag5Sigma: 20.85,
        matchedStarCount: 142,
        calibrationRms: 0.039,
        zeroPointError: 0.0041,
        photometricBand: 'V',
        bandIsStandard: true,
        solverId: 'skotiq',
        catalogSource: PhotometricCatalogSource.localGaia,
        exposureSeconds: 120.0,
      );
      final transparency = TransparencySample(
        capturedImageId: 42,
        sessionId: 7,
        timestamp: DateTime.utc(2026, 1, 1, 22, 30),
        transparencyPercent: 87.4,
        extinctionCoefficient: 0.215,
        qualityBucket: 'good',
        confidence: 0.78,
        // EXTINCT is unit-bearing (mag/airmass) and only stamped when the
        // value came from a real ZP-vs-airmass regression.
        extinctionFromAirmassFit: true,
      );

      final updates = ScienceProcessingService.buildScienceWritebackKeywords(
        calibration: cal,
        transparency: transparency,
        buildTag: 'Skotiq 2.5.0',
      );

      // Pre-write expectations: every keyword the science contract promises
      // must be present in the build set.
      expect(updates.map((u) => u.keyword).toList(), [
        'MAGZP',
        'MAGZPERR',
        'MAGZPRMS',
        'MAGZPBND',
        'MAGZPSRC',
        'MAGZPNST',
        'MAGLIM5',
        'TRANSPAR',
        'EXTINCT',
        'SKHA_VER',
      ]);

      final magzp = _card(updates, 'MAGZP');
      expect(magzp.doubleValue, closeTo(24.317, 1e-6));
      expect(magzp.comment, contains('Photometric zero point'));
      // MAGZPERR is the zero point's standard error; the per-star scatter
      // is MAGZPRMS.
      expect(_card(updates, 'MAGZPERR').doubleValue, closeTo(0.0041, 1e-6));
      expect(_card(updates, 'MAGZPRMS').doubleValue, closeTo(0.039, 1e-6));
      expect(_card(updates, 'MAGZPBND').stringValue, 'V');
      expect(_card(updates, 'MAGZPSRC').stringValue, 'LOCALGAIA');
      expect(_card(updates, 'MAGZPNST').intValue, 142);
      expect(_card(updates, 'MAGLIM5').doubleValue, closeTo(20.85, 1e-6));
      expect(_card(updates, 'TRANSPAR').doubleValue, closeTo(87.4, 1e-6));
      expect(_card(updates, 'EXTINCT').doubleValue, closeTo(0.215, 1e-6));
      expect(_card(updates, 'SKHA_VER').stringValue, 'Skotiq 2.5.0');
    },
  );

  test(
    'empty contract: no calibration and no transparency means no writes',
    () async {
      final updates = ScienceProcessingService.buildScienceWritebackKeywords(
        calibration: null,
        transparency: null,
      );
      expect(
        updates,
        isEmpty,
        reason: 'writeback must short-circuit when nothing useful was produced',
      );
    },
  );

  test('partial contract: transparency-only still stamps SKHA_VER', () async {
    final updates = ScienceProcessingService.buildScienceWritebackKeywords(
      calibration: null,
      transparency: TransparencySample(
        capturedImageId: null,
        sessionId: null,
        timestamp: DateTime.utc(2026, 1, 1),
        transparencyPercent: 64.0,
        extinctionCoefficient: 0.41,
        qualityBucket: 'fair',
        confidence: 0.55,
        extinctionFromAirmassFit: true,
      ),
    );
    expect(updates.map((u) => u.keyword).toList(), [
      'TRANSPAR',
      'EXTINCT',
      'SKHA_VER',
    ]);
  });

  test(
    'warm-up transparency (no airmass fit) must NOT stamp EXTINCT — the '
    'fallback value is a baseline ZP depression in mag, not mag/airmass',
    () async {
      final updates = ScienceProcessingService.buildScienceWritebackKeywords(
        calibration: null,
        transparency: TransparencySample(
          capturedImageId: null,
          sessionId: null,
          timestamp: DateTime.utc(2026, 1, 1),
          transparencyPercent: 64.0,
          extinctionCoefficient: 0.41,
          qualityBucket: 'fair',
          confidence: 0.55,
        ),
      );
      expect(updates.map((u) => u.keyword).toList(), ['TRANSPAR', 'SKHA_VER']);
    },
  );

  test('infinite values are silently dropped, never written', () async {
    final updates = ScienceProcessingService.buildScienceWritebackKeywords(
      calibration: FramePhotometricCalibration(
        capturedImageId: 1,
        sessionId: 1,
        timestamp: DateTime.utc(2026, 1, 1),
        isCalibrated: true,
        zeroPoint: double.infinity,
        limitingMag5Sigma: double.nan,
        matchedStarCount: 10,
        calibrationRms: 0.1,
        solverId: 'skotiq',
        catalogSource: PhotometricCatalogSource.localApass,
      ),
      transparency: null,
    );
    // Non-finite MAGZP and MAGLIM5 are dropped — but MAGZPSRC/MAGZPNST/MAGZPRMS
    // remain since they ARE finite. We still stamp provenance.
    final keywords = updates.map((u) => u.keyword).toList();
    expect(keywords, contains('MAGZPSRC'));
    expect(keywords, contains('MAGZPNST'));
    expect(keywords, contains('MAGZPRMS'));
    expect(keywords, contains('SKHA_VER'));
    expect(keywords, isNot(contains('MAGZP')));
    expect(keywords, isNot(contains('MAGLIM5')));
  });

  test('a refused calibration writes no zero point keywords', () {
    final updates = ScienceProcessingService.buildScienceWritebackKeywords(
      calibration: FramePhotometricCalibration(
        capturedImageId: 1,
        sessionId: 1,
        timestamp: DateTime.utc(2026, 10, 26, 9),
        isCalibrated: false,
        matchedStarCount: 14,
        calibrationRms: 1.4,
        solverId: 'astap',
        catalogSource: PhotometricCatalogSource.localApass,
        rejectionReason: 'catalog stars do not line up',
      ),
      transparency: null,
    );
    expect(updates, isEmpty);
  });
}

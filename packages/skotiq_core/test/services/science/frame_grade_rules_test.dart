import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart'
    as drift
    show CapturedImage;

drift.CapturedImage _light({
  int id = 1,
  double? hfr,
  int? starCount,
  double? guidingRmsTotal,
}) {
  final ts = DateTime(2026, 1, 1);
  return drift.CapturedImage(
    id: id,
    filePath: '/tmp/$id.fits',
    fileName: '$id.fits',
    fileFormat: 'fits',
    frameType: 'light',
    exposureDuration: 60,
    binX: 1,
    binY: 1,
    isPlateSolved: true,
    capturedAt: ts,
    createdAt: ts,
    isAccepted: true,
    hfr: hfr,
    starCount: starCount,
    guidingRmsTotal: guidingRmsTotal,
  );
}

/// Tests for [FrameGradeRules.gradeStats] — the in-memory grading overload that
/// powers the live per-sub badge. It must enforce the *identical* thresholds
/// and produce the *identical* reason-string format as the persisted
/// [FrameGradeRules.gradeFrame] path so the two graders can never disagree.
void main() {
  group('FrameGradeRules.gradeFrame eccentricity/FWHM are out-of-band', () {
    // The generated CapturedImage data class carries neither eccentricity nor
    // FWHM, so the caller supplies them, exactly like gradeStats. Reading them
    // off the row would leave both rules unable to fire.

    const eccRule = FrameGradeRules(maxEccentricity: 0.6);
    const fwhmRule = FrameGradeRules(maxFwhm: 4.0);

    test('eccentricity arg over threshold now actually rejects', () {
      final reason = eccRule.gradeFrame(_light(), eccentricity: 0.9);
      expect(reason, isNotNull);
      expect(reason, contains('Eccentricity'));
      expect(reason, contains('0.90'));
      expect(reason, contains('0.60'));
    });

    test('eccentricity arg at/under threshold passes', () {
      expect(eccRule.gradeFrame(_light(), eccentricity: 0.6), isNull);
      expect(eccRule.gradeFrame(_light(), eccentricity: 0.3), isNull);
    });

    test('FWHM arg over threshold now actually rejects', () {
      final reason = fwhmRule.gradeFrame(_light(), fwhm: 5.0);
      expect(reason, isNotNull);
      expect(reason, contains('FWHM'));
      expect(reason, contains('5.00'));
      expect(reason, contains('4.00'));
    });

    test('configuring an eccentricity rule with no metric available skips the '
        'rule (no no-evidence reject)', () {
      // Both production callers (FrameAutoGrader, Image Grader dialog) now
      // source these metrics from the frame's PSF tiles when available. A
      // frame whose pipeline produced no PSF data is legitimately
      // ungradeable on this dimension and must pass, not assert or reject.
      expect(eccRule.gradeFrame(_light()), isNull);
    });

    test('configuring a FWHM rule with no metric available skips the rule', () {
      expect(fwhmRule.gradeFrame(_light()), isNull);
    });

    test('rules without ecc/FWHM thresholds grade fine with no extra args', () {
      const rules = FrameGradeRules(maxHfr: 2.5, minStars: 30);
      expect(rules.gradeFrame(_light(hfr: 1.8, starCount: 50)), isNull);
      expect(
        rules.gradeFrame(_light(hfr: 3.2, starCount: 50)),
        contains('HFR'),
      );
      expect(
        rules.gradeFrame(_light(hfr: 1.8, starCount: 10)),
        contains('Stars 10 < 30'),
      );
    });
  });

  group('FrameGradeRules.gradeStats', () {
    const rules = FrameGradeRules(
      maxHfr: 3.0,
      maxFwhm: 4.0,
      maxEccentricity: 0.6,
      minStars: 50,
      maxGuidingRmsTotalArcsec: 1.0,
    );

    test('(a) all metrics within thresholds returns null', () {
      const stats = ImageStats(hfr: 2.0, fwhm: 3.0, starCount: 120);
      final reason = rules.gradeStats(
        stats,
        guidingRmsTotal: 0.5,
        eccentricity: 0.3,
      );
      expect(reason, isNull);
    });

    test('(b) HFR over threshold returns a reason containing HFR', () {
      const stats = ImageStats(hfr: 3.5, fwhm: 3.0, starCount: 120);
      final reason = rules.gradeStats(
        stats,
        guidingRmsTotal: 0.5,
        eccentricity: 0.3,
      );
      expect(reason, isNotNull);
      expect(reason, startsWith('Auto-grade: '));
      expect(reason, contains('HFR'));
      expect(reason, contains('3.50'));
      expect(reason, contains('3.00'));
    });

    test('(c) starCount under minStars returns a Stars reason', () {
      const stats = ImageStats(hfr: 2.0, fwhm: 3.0, starCount: 20);
      final reason = rules.gradeStats(
        stats,
        guidingRmsTotal: 0.5,
        eccentricity: 0.3,
      );
      expect(reason, isNotNull);
      expect(reason, contains('Stars 20 < 50'));
    });

    test('(d) guiding over threshold returns the arcsec reason', () {
      const stats = ImageStats(hfr: 2.0, fwhm: 3.0, starCount: 120);
      final reason = rules.gradeStats(
        stats,
        guidingRmsTotal: 1.5,
        eccentricity: 0.3,
      );
      expect(reason, isNotNull);
      expect(reason, contains('Guiding'));
      // The arcsec format mirrors gradeFrame: `1.50" > 1.00"`.
      expect(reason, contains('1.50"'));
      expect(reason, contains('1.00"'));
    });

    test('(e) eccentricity arg over maxEccentricity returns an '
        'Eccentricity reason', () {
      const stats = ImageStats(hfr: 2.0, fwhm: 3.0, starCount: 120);
      final reason = rules.gradeStats(
        stats,
        guidingRmsTotal: 0.5,
        eccentricity: 0.9,
      );
      expect(reason, isNotNull);
      expect(reason, contains('Eccentricity'));
      expect(reason, contains('0.90'));
      expect(reason, contains('0.60'));
    });

    test('(e2) FWHM over threshold returns an FWHM reason', () {
      const stats = ImageStats(hfr: 2.0, fwhm: 5.0, starCount: 120);
      final reason = rules.gradeStats(stats);
      expect(reason, isNotNull);
      expect(reason, contains('FWHM'));
      expect(reason, contains('5.00'));
      expect(reason, contains('4.00'));
    });

    test('(f) null metrics skip their respective rule', () {
      // No HFR/FWHM/starCount on the stats, and no guiding/eccentricity args:
      // every active rule has a null metric, so nothing can be graded and the
      // frame passes.
      const stats = ImageStats();
      final reason = rules.gradeStats(stats);
      expect(reason, isNull);
    });

    test('(f2) null guiding/eccentricity args skip only those rules', () {
      // HFR is gradeable and bad; guiding + eccentricity args are null so those
      // two rules are skipped even though thresholds are configured.
      const stats = ImageStats(hfr: 3.5, fwhm: 3.0, starCount: 120);
      final reason = rules.gradeStats(stats);
      expect(reason, isNotNull);
      expect(reason, contains('HFR'));
      expect(reason, isNot(contains('Guiding')));
      expect(reason, isNot(contains('Eccentricity')));
    });

    test('(g) live ImageStats.eccentricity rejects when no arg supplied', () {
      // The native detector now measures per-frame eccentricity and it rides
      // on ImageStats. With no out-of-band eccentricity arg, the gate must read
      // the live measured value and reject a trailed frame.
      const trailed = ImageStats(
        hfr: 2.0,
        fwhm: 3.0,
        eccentricity: 0.9,
        starCount: 120,
      );
      final reason = rules.gradeStats(trailed, guidingRmsTotal: 0.5);
      expect(reason, isNotNull);
      expect(reason, contains('Eccentricity'));
      expect(reason, contains('0.90'));
    });

    test('(g2) round live ImageStats.eccentricity passes the gate', () {
      const round = ImageStats(
        hfr: 2.0,
        fwhm: 3.0,
        eccentricity: 0.18,
        starCount: 120,
      );
      expect(rules.gradeStats(round, guidingRmsTotal: 0.5), isNull);
    });

    test('(g3) explicit eccentricity arg overrides the live stats value', () {
      // The science-row override (e.g. a more authoritative offline measure)
      // takes precedence over the live ImageStats value.
      const liveRound = ImageStats(
        hfr: 2.0,
        fwhm: 3.0,
        eccentricity: 0.1,
        starCount: 120,
      );
      final reason = rules.gradeStats(
        liveRound,
        guidingRmsTotal: 0.5,
        eccentricity: 0.9,
      );
      expect(
        reason,
        isNotNull,
        reason: 'explicit arg 0.9 must override live 0.1 and reject',
      );
      expect(reason, contains('Eccentricity'));
    });

    test('multiple failures are joined with "; " in stable rule order', () {
      const stats = ImageStats(hfr: 3.5, fwhm: 5.0, starCount: 20);
      final reason = rules.gradeStats(
        stats,
        guidingRmsTotal: 1.5,
        eccentricity: 0.9,
      );
      expect(reason, isNotNull);
      // Order mirrors gradeFrame: HFR, FWHM, Eccentricity, Stars, Guiding.
      final body = reason!.substring('Auto-grade: '.length);
      final parts = body.split('; ');
      expect(parts, hasLength(5));
      expect(parts[0], startsWith('HFR'));
      expect(parts[1], startsWith('FWHM'));
      expect(parts[2], startsWith('Eccentricity'));
      expect(parts[3], startsWith('Stars'));
      expect(parts[4], startsWith('Guiding'));
    });

    test('(g) empty rules (all-null) returns null even for a bad frame', () {
      const empty = FrameGradeRules();
      expect(empty.isEmpty, isTrue);
      expect(empty.hasActiveRules, isFalse);
      const stats = ImageStats(hfr: 99.0, fwhm: 99.0, starCount: 0);
      final reason = empty.gradeStats(
        stats,
        guidingRmsTotal: 99.0,
        eccentricity: 0.99,
      );
      expect(reason, isNull);
    });

    test('boundary: value exactly at the threshold is not rejected', () {
      // gradeFrame uses strict > / < comparisons; gradeStats must match.
      const stats = ImageStats(hfr: 3.0, fwhm: 4.0, starCount: 50);
      final reason = rules.gradeStats(
        stats,
        guidingRmsTotal: 1.0,
        eccentricity: 0.6,
      );
      expect(reason, isNull);
    });

    test('conservativeDefaults grades HFR/stars/guiding from stats + arg', () {
      // conservativeDefaults = maxHfr 3.2, minStars 25, guiding 1.2; no FWHM or
      // eccentricity rule. A clean frame passes; a bloated one fails on HFR.
      const clean = ImageStats(hfr: 2.0, starCount: 80);
      expect(
        FrameGradeRules.conservativeDefaults.gradeStats(
          clean,
          guidingRmsTotal: 0.6,
        ),
        isNull,
      );

      const bloated = ImageStats(hfr: 4.0, starCount: 80);
      final reason = FrameGradeRules.conservativeDefaults.gradeStats(
        bloated,
        guidingRmsTotal: 0.6,
      );
      expect(reason, isNotNull);
      expect(reason, contains('HFR'));
      // Eccentricity arg supplied but no rule configured -> never reported.
      final neverEcc = FrameGradeRules.conservativeDefaults.gradeStats(
        clean,
        guidingRmsTotal: 0.6,
        eccentricity: 0.95,
      );
      expect(neverEcc, isNull);
    });

    test('hasActiveRules reflects whether any threshold is set', () {
      expect(const FrameGradeRules().hasActiveRules, isFalse);
      expect(const FrameGradeRules(maxHfr: 3.0).hasActiveRules, isTrue);
      expect(FrameGradeRules.conservativeDefaults.hasActiveRules, isTrue);
    });
  });
}

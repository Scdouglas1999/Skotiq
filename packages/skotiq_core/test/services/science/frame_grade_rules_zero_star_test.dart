import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart'
    as drift
    show CapturedImage, SkotiqDatabase;

/// A light row exactly as `FrameAutoGrader.gradeCapturedFrame` hands it to
/// [FrameGradeRules.gradeFrame] after capture.
drift.CapturedImage _light({int? starCount, double? hfr}) {
  final ts = DateTime(2026, 1, 1);
  return drift.CapturedImage(
    id: 1,
    filePath: '/tmp/1.fits',
    fileName: '1.fits',
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
  );
}

/// The two graders must reach the same verdict on the same frame. The native
/// grader (`image_grading.rs::grade_frame`) rejects a light frame with a
/// measured zero star count before it consults any threshold, because every
/// other metric is `null` by construction in that case. The Dart engine had no
/// such rule, so with an eccentricity-only ruleset it accepted the very frame
/// the native side had already filed under `Reject/`.
void main() {
  // Only an eccentricity threshold: no star floor to accidentally catch this.
  const eccentricityOnly = FrameGradeRules(maxEccentricity: 0.8);

  group('measured zero stars', () {
    test('gradeFrame rejects with the native grader\'s reason', () {
      final reason = eccentricityOnly.gradeFrame(_light(starCount: 0));
      expect(reason, isNotNull);
      expect(reason, contains('no stars detected'));
      expect(reason, contains('unmeasurable'));
    });

    test('gradeStats reaches the identical verdict', () {
      final reason = eccentricityOnly.gradeStats(
        const ImageStats(starCount: 0),
      );
      expect(reason, isNotNull);
      expect(
        reason,
        equals(eccentricityOnly.gradeFrame(_light(starCount: 0))),
        reason: 'the persisted grade and the live badge must read the same',
      );
    });

    test('fires under every ruleset, including a star floor of zero', () {
      // `minStars: 0` is satisfiable by a starless frame (0 < 0 is false), so
      // the star-floor rule cannot stand in for this one.
      const zeroFloor = FrameGradeRules(minStars: 0);
      expect(zeroFloor.gradeFrame(_light(starCount: 0)), isNotNull);
      expect(zeroFloor.gradeStats(const ImageStats(starCount: 0)), isNotNull);
    });
  });

  group('honest absence is preserved', () {
    test('a null star count is not graded on', () {
      expect(eccentricityOnly.gradeFrame(_light(hfr: 2.0)), isNull);
      expect(
        eccentricityOnly.gradeStats(const ImageStats(hfr: 2.0)),
        isNull,
        reason: 'null means no detector ran — that is ignorance, not evidence',
      );
    });

    test('an empty ruleset grades nothing at all, not even zero stars', () {
      // Mirrors the native `check.is_active()` early-out: auto-grading off
      // must never flip a frame to rejected.
      const noRules = FrameGradeRules();
      expect(noRules.gradeFrame(_light(starCount: 0)), isNull);
      expect(noRules.gradeStats(const ImageStats(starCount: 0)), isNull);
    });

    test('a real frame with stars still passes', () {
      expect(eccentricityOnly.gradeFrame(_light(starCount: 180)), isNull);
      expect(
        eccentricityOnly.gradeStats(
          const ImageStats(starCount: 180, eccentricity: 0.3),
        ),
        isNull,
      );
    });
  });

  // Everything above calls the rule engine directly. These drive the real
  // production caller — `FrameAutoGrader.gradeCapturedFrame`, which the
  // science pipeline invokes on every captured light — against a real
  // database, so the assertion is on what is PERSISTED for the frame rather
  // than on what a helper returned. Cutting the rule out of
  // `FrameGradeRules.gradeFrame` has to fail here too, or the wiring was
  // never covered.
  group('FrameAutoGrader end-to-end', () {
    late drift.SkotiqDatabase db;
    late ImagesDao images;
    late ProviderContainer container;

    Future<void> boot(ScienceSettings settings) async {
      db = drift.SkotiqDatabase.forTesting(NativeDatabase.memory());
      images = ImagesDao(db);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          scienceSettingsProvider.overrideWith(
            () => _FixedScienceSettings(settings),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);
    }

    Future<int> insertLight({required int? starCount}) =>
        images.insertSequenceFrame(
          filePath: '/captures/m31/L_0001.fits',
          fileName: 'L_0001.fits',
          fileFormat: 'fits',
          exposureDuration: 300,
          capturedAt: DateTime.utc(2026, 1, 1, 23),
          isAccepted: true,
          producingNodeId: 'node-zero-star',
          filter: 'L',
          starCount: starCount,
        );

    test('a starless light is persisted as rejected, not accepted', () async {
      await boot(
        const ScienceSettings(
          autoFrameGradingEnabled: true,
          frameGradeRulesJson: '{"maxEccentricity":0.8}',
        ),
      );
      final id = await insertLight(starCount: 0);

      final rejected = await container
          .read(frameAutoGraderProvider)
          .gradeCapturedFrame(image: (await images.getImageById(id))!);

      expect(rejected, isTrue);
      final row = await images.getImageById(id);
      expect(
        row!.isAccepted,
        isFalse,
        reason:
            'the native grader already filed this frame under Reject/; the '
            'persisted row must not say it was kept',
      );
      expect(row.rejectionReason, contains('no stars detected'));
    });

    test('an unmeasured star count is left accepted', () async {
      await boot(
        const ScienceSettings(
          autoFrameGradingEnabled: true,
          frameGradeRulesJson: '{"maxEccentricity":0.8}',
        ),
      );
      final id = await insertLight(starCount: null);

      final rejected = await container
          .read(frameAutoGraderProvider)
          .gradeCapturedFrame(image: (await images.getImageById(id))!);

      expect(rejected, isFalse);
      expect((await images.getImageById(id))!.isAccepted, isTrue);
    });
  });
}

/// Serves fixed [ScienceSettings] so the grader reads real rules without a
/// settings table behind it.
class _FixedScienceSettings extends ScienceSettingsNotifier {
  _FixedScienceSettings(this._settings);

  final ScienceSettings _settings;

  @override
  Future<ScienceSettings> build() async => _settings;
}

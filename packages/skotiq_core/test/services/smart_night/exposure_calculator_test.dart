import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/smart_night/exposure_calculator.dart';

void main() {
  group('SmartNightExposureCalculator', () {
    const calculator = SmartNightExposureCalculator();

    ExposureCalculatorInput asi2600({
      int bortleClass = 5,
      double readNoiseE = 1.5,
      FilterExposureSpec filter = const FilterExposureSpec.narrowbandHa(),
      double? guideRmsArcsec,
      int guideSampleCount = 0,
      double userCapSeconds = 300,
      double floorSeconds = 60,
      double fullWellE = 18000,
      double targetSnr = 30,
    }) {
      return ExposureCalculatorInput(
        camera: CameraExposureSpec(
          readNoiseE: readNoiseE,
          fullWellE: fullWellE,
          qePeak: 0.8,
        ),
        filter: filter,
        bortleClass: bortleClass,
        focalLengthMm: 480,
        apertureMm: 80,
        pixelSizeMicrons: 3.76,
        guideRmsArcsec: guideRmsArcsec,
        guideSampleCount: guideSampleCount,
        userCapSeconds: userCapSeconds,
        floorSeconds: floorSeconds,
        targetSnr: targetSnr,
      );
    }

    test('caps Bortle 5 3nm Ha subs at the user ceiling', () {
      final recommendation = calculator.recommend(asi2600());

      expect(recommendation.seconds, equals(300));
      expect(recommendation.limitingFactor, ExposureLimitingFactor.userCap);
      expect(
        recommendation.allCeilings[ExposureLimitingFactor.glover],
        inInclusiveRange(280, 600),
      );
      expect(recommendation.rationale, contains('user cap'));
    });

    test('recommends short broadband subs under Bortle 8 skies', () {
      final recommendation = calculator.recommend(
        asi2600(bortleClass: 8, filter: const FilterExposureSpec.luminance()),
      );

      expect(recommendation.seconds, lessThanOrEqualTo(90));
      expect(recommendation.seconds, greaterThanOrEqualTo(60));
      expect(
        recommendation.limitingFactor,
        anyOf(ExposureLimitingFactor.glover, ExposureLimitingFactor.floor),
      );
    });

    test('treats OSC multi-band nebula filters as narrowband', () {
      final luminance = calculator.recommend(
        asi2600(
          bortleClass: 8,
          filter: const FilterExposureSpec.luminance(),
          fullWellE: 50000,
        ),
      );
      final lExtreme = calculator.recommend(
        asi2600(
          bortleClass: 8,
          filter: FilterExposureSpec.fromName('L-eXtreme'),
          fullWellE: 50000,
        ),
      );

      expect(FilterExposureSpec.fromName('L-eXtreme').bandwidthNm, 7);
      expect(
        lExtreme.allCeilings[ExposureLimitingFactor.glover],
        greaterThan(luminance.allCeilings[ExposureLimitingFactor.glover]!),
      );
    });

    test('lighter sky never increases the exposure recommendation', () {
      var previous = double.infinity;
      for (var bortle = 1; bortle <= 9; bortle++) {
        final recommendation = calculator.recommend(
          asi2600(
            bortleClass: bortle,
            filter: const FilterExposureSpec.luminance(),
          ),
        );
        expect(
          recommendation.seconds,
          lessThanOrEqualTo(previous),
          reason: 'Bortle $bortle should not recommend longer subs.',
        );
        previous = recommendation.seconds;
      }
    });

    test('higher read noise never decreases the Glover recommendation', () {
      var previousGlover = 0.0;
      for (final readNoise in [1.0, 1.5, 2.0, 3.0, 4.0]) {
        final recommendation = calculator.recommend(
          asi2600(readNoiseE: readNoise, userCapSeconds: 3600),
        );
        final glover =
            recommendation.allCeilings[ExposureLimitingFactor.glover]!;
        expect(
          glover,
          greaterThanOrEqualTo(previousGlover),
          reason: 'Read noise $readNoise should not reduce Glover seconds.',
        );
        previousGlover = glover;
      }
    });

    test('mount ceiling only applies after enough guide history exists', () {
      final withoutHistory = calculator.recommend(
        asi2600(
          guideRmsArcsec: 1.5,
          guideSampleCount: 2,
          floorSeconds: 30,
          userCapSeconds: 3600,
        ),
      );
      final withHistory = calculator.recommend(
        asi2600(
          guideRmsArcsec: 1.5,
          guideSampleCount: 3,
          floorSeconds: 30,
          userCapSeconds: 3600,
        ),
      );

      expect(withoutHistory.allCeilings[ExposureLimitingFactor.mount], isNull);
      expect(withHistory.limitingFactor, ExposureLimitingFactor.mount);
      expect(withHistory.seconds, lessThan(withoutHistory.seconds));
      expect(
        withHistory.caveats,
        isNot(contains(contains('Mount limit not applied'))),
      );
    });

    test('produces distinct, correctly-ordered subs per filter category', () {
      // Dark sky + small fast scope so broadband sky-limited lengths rise above
      // the floor and the per-channel ordering is observable end-to-end.
      ExposureRecommendation forFilter(String name) => calculator.recommend(
        asi2600(
          bortleClass: 3,
          filter: FilterExposureSpec.fromName(name),
          floorSeconds: 30,
          userCapSeconds: 600,
          fullWellE: 50000,
        ),
      );

      final l = forFilter('L').seconds;
      final r = forFilter('R').seconds;
      final g = forFilter('G').seconds;
      final b = forFilter('B').seconds;
      final ha = forFilter('Ha').seconds;
      final oiii = forFilter('OIII').seconds;
      final sii = forFilter('SII').seconds;

      // Luminance sees the most sky flux, so it is the shortest broadband sub.
      expect(l, lessThan(r), reason: 'L should be shorter than R');
      expect(l, lessThan(g), reason: 'L should be shorter than G');
      expect(l, lessThan(b), reason: 'L should be shorter than B');

      // Green sees the brightest color-band sky (Na/Hg LP + airglow), blue the
      // darkest, so the canonical LRGB ordering is G <= R < B.
      expect(g, lessThanOrEqualTo(r), reason: 'G sky brighter than R');
      expect(r, lessThan(b), reason: 'Blue sees darkest sky -> longest sub');

      // Narrowband is darker still than any broadband channel.
      expect(ha, greaterThan(b), reason: 'Narrowband Ha longer than blue');
      // Same narrow bandwidth -> same recommendation across Ha/OIII/SII.
      expect(oiii, equals(ha));
      expect(sii, equals(ha));

      // Broadband channels are NOT all identical.
      expect(
        {l, r, g, b}.length,
        greaterThan(1),
        reason: 'broadband channels must not collapse to one value',
      );
    });

    test('target SNR scales sky-limited recommendations', () {
      final lowerTarget = calculator.recommend(
        asi2600(
          filter: const FilterExposureSpec.luminance(),
          bortleClass: 4,
          floorSeconds: 5,
          userCapSeconds: 3600,
          fullWellE: 50000,
          targetSnr: 20,
        ),
      );
      final defaultTarget = calculator.recommend(
        asi2600(
          filter: const FilterExposureSpec.luminance(),
          bortleClass: 4,
          floorSeconds: 5,
          userCapSeconds: 3600,
          fullWellE: 50000,
        ),
      );
      final higherTarget = calculator.recommend(
        asi2600(
          filter: const FilterExposureSpec.luminance(),
          bortleClass: 4,
          floorSeconds: 5,
          userCapSeconds: 3600,
          fullWellE: 50000,
          targetSnr: 45,
        ),
      );

      expect(lowerTarget.seconds, lessThan(defaultTarget.seconds));
      expect(higherTarget.seconds, greaterThan(defaultTarget.seconds));
      expect(higherTarget.rationale, contains('SNR 45'));
    });
  });
}

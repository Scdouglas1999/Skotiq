import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/constellation/constellation_format.dart';

void main() {
  group('formatYourContribution', () {
    test('frames your local depth against the swarm total with a percentage',
        () {
      expect(
        formatYourContribution(
          yourSeconds: 3600 * 2.0,
          swarmSeconds: 3600 * 10.0,
        ),
        '2.0h available to contribute (20% of swarm)',
      );
    });

    test('clamps the percentage to 100 when you exceed the reported total', () {
      expect(
        formatYourContribution(yourSeconds: 7200, swarmSeconds: 3600),
        '2.0h available to contribute (100% of swarm)',
      );
    });

    test('drops the swarm comparison when the total is unknown', () {
      expect(
        formatYourContribution(yourSeconds: 3600, swarmSeconds: 0),
        '1.0h available to contribute',
      );
      expect(
        formatYourContribution(yourSeconds: 0, swarmSeconds: 0),
        'Nothing local yet',
      );
    });
  });

  group('yourContributionFraction', () {
    test('is the clamped ratio of your depth to the swarm total', () {
      expect(
        yourContributionFraction(yourSeconds: 1, swarmSeconds: 4),
        closeTo(0.25, 1e-9),
      );
      expect(
        yourContributionFraction(yourSeconds: 8, swarmSeconds: 4),
        1.0,
      );
    });

    test('is zero on missing / non-finite inputs', () {
      expect(yourContributionFraction(yourSeconds: 0, swarmSeconds: 4), 0.0);
      expect(yourContributionFraction(yourSeconds: 4, swarmSeconds: 0), 0.0);
      expect(
        yourContributionFraction(
          yourSeconds: double.nan,
          swarmSeconds: 4,
        ),
        0.0,
      );
    });
  });

  group('formatFollowHint', () {
    test('ready-now phrasing names the swarm-needs nudge', () {
      final hint = formatFollowHint(
        targetName: 'M31',
        isReadyNow: true,
        altitudeOk: true,
        swarmSeconds: 3600 * 12.0,
      );
      expect(hint, contains('M31 is dark for you now'));
      expect(hint, contains('12h'));
    });

    test('first-light phrasing when the swarm has no light yet', () {
      final hint = formatFollowHint(
        targetName: 'NGC 7000',
        isReadyNow: true,
        altitudeOk: true,
        swarmSeconds: 0,
      );
      expect(hint, contains('first photons'));
    });

    test('below-horizon phrasing when the target is not up', () {
      final hint = formatFollowHint(
        targetName: 'M51',
        isReadyNow: false,
        altitudeOk: false,
        swarmSeconds: 100,
      );
      expect(hint, contains('below your horizon'));
    });

    test('already-held phrasing when up but taken', () {
      final hint = formatFollowHint(
        targetName: 'M81',
        isReadyNow: false,
        altitudeOk: true,
        swarmSeconds: 100,
      );
      expect(hint, contains('another imager'));
    });
  });

  group('formatHubLabel', () {
    test('joins name and short fingerprint', () {
      expect(
        formatHubLabel('skotiq.local', 'abcdef0123456789'),
        'skotiq.local · abcdef01',
      );
    });

    test('falls back to the fingerprint when unnamed', () {
      expect(formatHubLabel('', 'abcdef0123456789'), 'abcdef01');
    });
  });

  group('describeConstellationError', () {
    test('strips the ConstellationException envelope', () {
      expect(
        describeConstellationError(
          'ConstellationException(auth): No hub configured.',
        ),
        'No hub configured.',
      );
    });

    test('strips a bare Exception prefix', () {
      expect(
        describeConstellationError('Exception: boom'),
        'boom',
      );
    });
  });
}

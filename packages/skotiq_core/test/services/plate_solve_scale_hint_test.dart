// The solver must be TOLD the scale the app already knows.
//
// A position hint alone is not enough: an invocation can land
// `-ra 0.000000 -spd 90.000000 -r 30.00` and carry no `-fov` at all, leaving
// `grep -i fov` over a whole session log empty while onboarding has already
// computed and stored `1.29"/px` for the train and the profile card prints it.
// Determining the scale unaided is the slow half of a solve and the half that
// fails on a sparse field.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/plate_solve_service.dart';

PlateSolverConfig _config({double? fieldHeightDegrees}) => PlateSolverConfig(
  type: PlateSolverType.astap,
  executablePath: '/usr/bin/astap',
  catalogPath: '/usr/share/astap',
  searchRadius: 30,
  hintRa: 5.5,
  hintDec: 22,
  fieldHeightDegrees: fieldHeightDegrees,
);

void main() {
  test('the field-height hint reaches ASTAP as -fov', () {
    // 1080 rows at 1.29"/px = 0.387 degrees of sky.
    final args = PlateSolveService.astapArguments(
      '/tmp/frame.fits',
      _config(fieldHeightDegrees: 1.29 * 1080 / 3600),
    );

    final fovIndex = args.indexOf('-fov');
    expect(fovIndex, isNot(-1), reason: 'no scale hint was passed at all');
    expect(double.parse(args[fovIndex + 1]), closeTo(0.387, 0.001));

    // The position hint the audit confirmed still lands, unchanged.
    expect(args, containsAllInOrder(<String>['-ra', '5.5']));
    expect(args, containsAllInOrder(<String>['-spd', '112.0']));
    expect(args, containsAllInOrder(<String>['-r', '30.0']));
    expect(args.last, '-wcs');
  });

  test('no profile scale means no hint, not a guessed one', () {
    final args = PlateSolveService.astapArguments('/tmp/frame.fits', _config());

    expect(
      args.contains('-fov'),
      isFalse,
      reason:
          'a wrong scale hint is worse than none — ASTAP treats a missing '
          '-fov as "work it out", which is the honest state here',
    );
  });

  test('a zero or non-finite field height is not sent', () {
    for (final bad in <double>[0, -1, double.nan, double.infinity]) {
      final args = PlateSolveService.astapArguments(
        '/tmp/frame.fits',
        _config(fieldHeightDegrees: bad),
      );
      expect(args.contains('-fov'), isFalse, reason: 'sent -fov $bad');
    }
  });
}

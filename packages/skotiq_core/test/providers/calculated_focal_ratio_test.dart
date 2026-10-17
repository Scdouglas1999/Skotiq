import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';

/// A stored profile can still hold optics that cannot describe a real system —
/// rows written before optical-train validation existed, or restored from a
/// backup, which deliberately reproduces prior state verbatim rather than
/// failing a whole restore over one bad field.
///
/// Reporting `f/9999999990000.00` as a derived fact is the same defect class as
/// the write-side gap that has just been closed: the app stating something
/// untrue. Every caller already handles null (Settings renders a dash), so
/// declining to compute beats computing nonsense.
void main() {
  EquipmentProfileModel profile({
    double focalLength = 600,
    double aperture = 120,
    double? focalRatio,
  }) => EquipmentProfileModel(
    name: 'probe',
    focalLength: focalLength,
    aperture: aperture,
    focalRatio: focalRatio,
  );

  test('a real rig computes its ratio', () {
    expect(profile().calculatedFocalRatio, closeTo(5.0, 0.001));
  });

  test('an explicit stored ratio wins when plausible', () {
    expect(profile(focalRatio: 2.2).calculatedFocalRatio, closeTo(2.2, 0.001));
  });

  test('the legacy absurd pair no longer renders a ratio', () {
    // The literal values observed persisted on the live instance.
    final legacy = profile(focalLength: 999999999, aperture: 0.0001);
    expect(legacy.calculatedFocalRatio, isNull);
  });

  test('an absurd STORED ratio is refused too', () {
    expect(profile(focalRatio: 9999999990000.0).calculatedFocalRatio, isNull);
    expect(profile(focalRatio: 0.01).calculatedFocalRatio, isNull);
  });

  test('unspecified optics stay null rather than dividing by zero', () {
    expect(profile(focalLength: 0, aperture: 0).calculatedFocalRatio, isNull);
  });

  test('non-finite values cannot escape', () {
    expect(profile(focalRatio: double.infinity).calculatedFocalRatio, isNull);
    expect(profile(focalRatio: double.nan).calculatedFocalRatio, isNull);
  });

  test('fast and slow real systems both survive', () {
    // RASA 11 at f/2.2 and a long-focus solar refractor at f/30.
    expect(
      profile(focalLength: 620, aperture: 279).calculatedFocalRatio,
      closeTo(2.22, 0.01),
    );
    expect(
      profile(focalLength: 3000, aperture: 100).calculatedFocalRatio,
      closeTo(30.0, 0.01),
    );
  });
}

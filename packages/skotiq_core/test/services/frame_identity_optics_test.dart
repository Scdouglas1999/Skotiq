import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/services/frame_identity.dart';

// FOCALLEN and APTDIA name the train the rig images through: behind a 0.8x
// reducer that is the profile's 440 mm, not the telescope's native 550 mm.
void main() {
  test('the header names the effective train, not the native telescope', () {
    const reduced = EquipmentProfileModel(
      name: 'reduced',
      focalLength: 440,
      aperture: 100,
      telescopeFocalLength: 550,
      telescopeAperture: 102,
    );
    final identity = FrameIdentity.of(null, reduced);
    expect(identity.focalLengthMm, 440);
    expect(identity.apertureMm, 100);
  });

  test('a profile with only the telescope optics names those', () {
    const telescopeOnly = EquipmentProfileModel(
      name: 'telescope only',
      telescopeFocalLength: 550,
      telescopeAperture: 102,
    );
    final identity = FrameIdentity.of(null, telescopeOnly);
    expect(identity.focalLengthMm, 550);
    expect(identity.apertureMm, 102);
  });

  test('no optics at all leave the cards out', () {
    final identity = FrameIdentity.of(
      null,
      const EquipmentProfileModel(name: 'bare'),
    );
    expect(identity.focalLengthMm, isNull);
    expect(identity.apertureMm, isNull);
  });
}

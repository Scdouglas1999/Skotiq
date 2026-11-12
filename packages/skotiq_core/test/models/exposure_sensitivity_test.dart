import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  group('ExposureSensitivity', () {
    test('a camera that lists ISO speeds reads as ISO, any other as gain', () {
      const astro = CameraCapabilities(
        maxWidth: 6248,
        maxHeight: 4176,
        bitDepth: 16,
        canSetGain: true,
        gainMin: 0,
        gainMax: 600,
      );
      const dslr = CameraCapabilities(
        maxWidth: 6000,
        maxHeight: 4000,
        bitDepth: 14,
        canSetGain: true,
        gainMin: 100,
        gainMax: 25600,
        isoSpeeds: [100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600],
      );
      expect(astro.sensitivity, const GainSensitivity(min: 0, max: 600));
      expect(dslr.sensitivity, isA<IsoSensitivity>());
      expect(ExposureSensitivity.of(null), const GainSensitivity());
      expect(astro.sensitivity.label, 'Gain');
      expect(dslr.sensitivity.label, 'ISO');
      expect(astro.sensitivity.describe(100), 'gain 100');
      expect(dslr.sensitivity.describe(800), 'ISO 800');
      expect(astro.sensitivity.hasOffset, isTrue);
      expect(dslr.sensitivity.hasOffset, isFalse);
      expect(dslr.sensitivity.gainKind, GainKind.iso);
    });

    test('an ISO request goes to the nearest offered speed by ratio', () {
      final iso = IsoSensitivity(const [100, 200, 400, 800, 1600]);
      expect(iso.accept(800), 800);
      expect(iso.accept(850), 800);
      expect(iso.accept(1300), 1600);
      expect(iso.accept(3), 100);
      expect(iso.accept(0), 100);
      expect(const GainSensitivity(min: 0, max: 600).accept(900), 600);
    });

    test('ISO speeds survive the linked-client JSON round trip', () {
      const caps = CameraCapabilities(
        maxWidth: 1,
        maxHeight: 1,
        bitDepth: 14,
        isoSpeeds: [100, 6400],
      );
      final back = CameraCapabilities.fromJson(caps.toJson());
      expect(back.isoSpeeds, [100, 6400]);
      expect(back.sensitivity, IsoSensitivity(const [100, 6400]));
    });
  });

  group('GainKind', () {
    test('words a recorded gain the way the frame recorded it', () {
      expect(GainKind.fromRecord(null), GainKind.gain);
      expect(GainKind.fromRecord('iso').describe(800), 'ISO 800');
      expect(
        GainKind.fromRecord('isoListPosition').describe(3),
        'unknown ISO (ISO-list position 3)',
      );
      expect(GainKind.isoListPosition.isKnown, isFalse);
      expect(GainKind.iso.label, 'ISO');
      expect(GainKind.gain.label, 'Gain');
    });
  });
}

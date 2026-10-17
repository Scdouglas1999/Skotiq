import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/sensor_specs/camera_sensor_database.dart';
import 'package:skotiq_core/src/services/sensor_specs/camera_sensor_entry.dart';
import 'package:skotiq_core/src/services/sensor_specs/curated_camera_sensors.dart';
import 'package:skotiq_core/src/services/sensor_specs/published_figure.dart';

void main() {
  final db = CameraSensorDatabase.curated;

  group('model matching', () {
    test('the owner\'s ASI1600MM-Cool resolves to the MN34230 mono row', () {
      final entry = db.lookup('ASI1600MM-Cool');
      expect(entry, isNotNull);
      expect(entry!.model, 'ZWO ASI1600MM');
      expect(entry.sensor, 'Panasonic MN34230ALJ');
      expect(entry.widthPx, 4656);
      expect(entry.heightPx, 3520);
      expect(entry.pixelSizeMicrons, 3.8);
    });

    test('case, spacing and separators do not change the answer', () {
      for (final name in [
        'ASI1600MM-Cool',
        'asi1600mm-cool',
        'ASI1600MM COOL',
        'ASI1600MM_Cool',
        'ZWO ASI1600MM-Cool',
        'zwo asi1600mm cool',
      ]) {
        expect(db.lookup(name)?.model, 'ZWO ASI1600MM', reason: name);
      }
    });

    test('a QHY serial suffix is stripped, a model suffix is not', () {
      expect(db.lookup('QHY268M-6c1d4a8e9f01')?.model, 'QHY268M');
      expect(db.lookup('QHY268M-PH')?.model, 'QHY268M');
      // "Cool" is four characters with no digit, so it survives the serial
      // rule and has to be claimed by the row itself.
      expect(db.lookup('ASI1600MC-Cool')?.model, 'ZWO ASI1600MC');
    });

    test('mono and colour never cross over', () {
      expect(db.lookup('ASI1600MM')?.model, 'ZWO ASI1600MM');
      expect(db.lookup('ASI1600MC')?.model, 'ZWO ASI1600MC');
      expect(db.lookup('ASI2600MM Pro')?.model, 'ZWO ASI2600MM Pro');
      expect(db.lookup('ASI2600MC Pro')?.model, 'ZWO ASI2600MC Pro');
      expect(db.lookup('QHY600M')?.model, 'QHY600M');
      expect(db.lookup('QHY600C')?.model, 'QHY600C');
    });

    test('vendors with the same sensor keep their own crop', () {
      // ZWO and QHY crop the IMX571 and the IMX183 differently. Aliasing them
      // onto one row would misreport the field of view by the difference.
      expect(db.lookup('ASI2600MM Pro')!.widthPx, 6248);
      expect(db.lookup('QHY268M')!.widthPx, 6252);
      expect(db.lookup('ASI183MM')!.widthPx, 5496);
      expect(db.lookup('QHY183M')!.widthPx, 5544);
    });

    group('a near-miss model is a MISS, never a guess', () {
      // Each of these matched the WRONG sensor under the previous
      // edit-distance matcher, silently. The pitch each one really has is in
      // the reason string; none of them is in this database, so the honest
      // answer is null.
      const nearMisses = {
        'ASI2400MC Pro': 'IMX410 at 5.94 um, not the ASI2600MC at 3.76',
        'ASI585MC Pro': 'IMX585 at 2.9 um, not the ASI533MC at 3.76',
        'ASI676MC': 'IMX678 at 2.0 um',
        'ASI2600MM-P25': 'the 2025 revision, whose full well differs',
        'ASI1601MM': 'not a camera at all',
        'QHY533': 'neither the M nor the C variant',
        'QHY600': 'neither the M nor the C variant',
        'ASI294MM': 'claimed, but check it is the MM row below',
      };
      for (final entry in nearMisses.entries) {
        if (entry.key == 'ASI294MM') continue;
        test('${entry.key} does not match (${entry.value})', () {
          expect(db.lookup(entry.key), isNull);
        });
      }

      test('a bare family name only matches when a row claims it', () {
        // ZWO never shipped a non-Pro ASI294MM, so the row claims the bare
        // name; it has not been inferred.
        expect(db.lookup('ASI294MM')?.model, 'ZWO ASI294MM Pro');
        expect(db.lookup('ASI294MM')!.driverNames, contains('ASI294MM'));
      });
    });

    test('a null or blank model is a miss', () {
      expect(db.lookup(null), isNull);
      expect(db.lookup(''), isNull);
      expect(db.lookup('   '), isNull);
    });

    test('lookupAny tries the friendly name before the device id', () {
      // A ZWO ASCOM ProgID names the driver, not the camera; the friendly
      // name has to win.
      expect(
        db.lookupAny(['ASI533MM Pro', 'ASI1600MM'])?.model,
        'ZWO ASI533MM Pro',
      );
      expect(db.lookupAny([null, 'ASI1600MM-Cool'])?.model, 'ZWO ASI1600MM');
    });
  });

  group('data integrity', () {
    test('every row is sourced and self-consistent', () {
      for (final entry in kCuratedCameraSensors) {
        expect(entry.source, isNotEmpty, reason: entry.model);
        expect(
          entry.source,
          contains('http'),
          reason: '${entry.model} must cite a retrievable document',
        );
        expect(entry.driverNames, isNotEmpty, reason: entry.model);
        expect(entry.widthPx, greaterThan(0), reason: entry.model);
        expect(entry.heightPx, greaterThan(0), reason: entry.model);
        expect(entry.pixelSizeMicrons, greaterThan(0), reason: entry.model);
        final qe = entry.qePeakFraction;
        if (qe != null) {
          expect(qe, greaterThan(0), reason: entry.model);
          expect(qe, lessThanOrEqualTo(1.0), reason: entry.model);
        }
      }
    });

    test('a published pitch agrees with the published image area', () {
      // Both are published for the ZWO rows, so they are a cross-check on the
      // transcription: a typo in either shows up as a mismatch.
      for (final entry in kCuratedCameraSensors) {
        if (entry.publishedPixelSizeMicrons == null) continue;
        if (entry.publishedImageAreaWidthMm == null) continue;
        final derived = entry.publishedImageAreaWidthMm! * 1000 / entry.widthPx;
        expect(
          derived,
          closeTo(entry.publishedPixelSizeMicrons!, 0.05),
          reason:
              '${entry.model}: published pitch '
              '${entry.publishedPixelSizeMicrons} vs '
              '${derived.toStringAsFixed(3)} from the published area',
        );
      }
    });

    test('a DSLR row publishes geometry only', () {
      // Canon and Nikon publish no read noise, full well or QE. A row that
      // grew one would mean a figure came from somewhere other than the
      // manufacturer.
      for (final entry in kCuratedCameraSensors) {
        final isDslr =
            entry.model.startsWith('Canon') || entry.model.startsWith('Nikon');
        if (!isDslr) continue;
        expect(entry.readNoiseE, isEmpty, reason: entry.model);
        expect(entry.fullWellE, isEmpty, reason: entry.model);
        expect(entry.qePeakFraction, isNull, reason: entry.model);
        expect(entry.pixelSizeIsDerived, isTrue, reason: entry.model);
      }
    });

    test('a gain-dependent figure always carries its operating point', () {
      for (final entry in kCuratedCameraSensors) {
        for (final figure in [...entry.readNoiseE, ...entry.fullWellE]) {
          expect(figure.low, greaterThan(0), reason: entry.model);
          expect(
            figure.high,
            greaterThanOrEqualTo(figure.low),
            reason: entry.model,
          );
          switch (figure.kind) {
            case PublishedFigureKind.atDriverGain:
              expect(figure.driverGain, isNotNull, reason: entry.model);
            case PublishedFigureKind.atQuotedLabel:
              expect(figure.quotedLabel, isNotEmpty, reason: entry.model);
            case PublishedFigureKind.range:
              expect(
                figure.high,
                greaterThan(figure.low),
                reason: '${entry.model}: a range with equal ends is a point',
              );
            case PublishedFigureKind.unattributed:
              break;
          }
          expect(figure.operatingPointPhrase, isNotEmpty);
        }
      }
    });

    test('no two rows claim the same driver name', () {
      final seen = <String, String>{};
      for (final entry in kCuratedCameraSensors) {
        for (final name in entry.driverNames) {
          final key = CameraSensorDatabase.normalize(name);
          expect(
            seen[key],
            anyOf(isNull, entry.model),
            reason: '"$name" is claimed twice',
          );
          seen[key] = entry.model;
        }
      }
    });

    test('a duplicate claim is rejected at construction, not tolerated', () {
      expect(
        () => CameraSensorDatabase(
          entries: const [
            CameraSensorEntry(
              model: 'A',
              driverNames: ['CAM-1'],
              sensor: 'x',
              widthPx: 100,
              heightPx: 100,
              publishedPixelSizeMicrons: 1,
              source: 'http://example.test/a',
            ),
            CameraSensorEntry(
              model: 'B',
              driverNames: ['cam 1'],
              sensor: 'y',
              widthPx: 200,
              heightPx: 200,
              publishedPixelSizeMicrons: 2,
              source: 'http://example.test/b',
            ),
          ],
        ),
        throwsStateError,
      );
    });

    test('the families the brief names are all present', () {
      for (final name in [
        'ASI1600MM-Cool',
        'ASI2600MM Pro',
        'ASI2600MC Pro',
        'ASI6200MM Pro',
        'ASI6200MC Pro',
        'ASI533MM Pro',
        'ASI533MC Pro',
        'ASI294MM Pro',
        'ASI294MC Pro',
        'ASI183MM',
        'ASI183MC',
        'QHY600M',
        'QHY268M',
        'QHY533M',
        'QHY183M',
        'Canon EOS 6D',
        'Canon EOS Ra',
        'Canon EOS 60Da',
        'Nikon D5300',
        'Nikon D810A',
      ]) {
        expect(db.lookup(name), isNotNull, reason: name);
      }
    });
  });

  group('derived geometry', () {
    test('a DSLR pitch comes out of the published area and pixel count', () {
      // Canon publishes 36 x 24 mm and 5472 x 3648 for the EOS 6D.
      final sixD = db.lookup('Canon EOS 6D')!;
      expect(sixD.pixelSizeMicrons, closeTo(36000 / 5472, 1e-9));
      expect(sixD.pixelSizeIsDerived, isTrue);
      expect(sixD.sensorWidthMm, 36.0);

      // Nikon publishes 23.5 x 15.6 mm and 6000 x 4000 for the D5300.
      final d5300 = db.lookup('Nikon D5300')!;
      expect(d5300.pixelSizeMicrons, closeTo(23500 / 6000, 1e-9));
    });
  });
}

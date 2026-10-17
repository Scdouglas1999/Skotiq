import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/sensor_specs/camera_sensor_database.dart';
import 'package:skotiq_core/src/services/sensor_specs/camera_sensor_entry.dart';
import 'package:skotiq_core/src/services/sensor_specs/camera_sensor_spec_resolver.dart';
import 'package:skotiq_core/src/services/sensor_specs/camera_sensor_specs.dart';
import 'package:skotiq_core/src/services/sensor_specs/published_figure.dart';

void main() {
  final resolver = CameraSensorSpecResolver();

  SensorGeometryReading reading({
    int width = 1000,
    int height = 800,
    double pitch = 5.0,
    DateTime? readAt,
  }) => SensorGeometryReading(
    widthPx: width,
    heightPx: height,
    pixelSizeXMicrons: pitch,
    pixelSizeYMicrons: pitch,
    readAt: readAt,
  );

  group('the chain, tier by tier', () {
    test('(a) the user\'s value beats everything below it', () {
      final specs = resolver.resolve(
        CameraSensorSpecInputs(
          cameraName: 'ASI1600MM-Cool',
          gain: 100,
          overrides: const UserSensorSpecOverrides(
            pixelSizeMicrons: 3.9,
            readNoiseE: 2.1,
          ),
          liveReading: reading(pitch: 3.81),
        ),
      );
      expect(specs.pixelSizeMicrons!.value, 3.9);
      expect(specs.pixelSizeMicrons!.origin, SensorSpecOrigin.userOverride);
      expect(specs.pixelSizeMicrons!.provenance, 'the value you entered');
      expect(specs.readNoiseE!.value, 2.1);
      expect(specs.readNoiseE!.origin, SensorSpecOrigin.userOverride);
      // Fields the user did not set still come from the tiers below.
      expect(specs.fullWellE!.origin, SensorSpecOrigin.modelDatabase);
    });

    test('(b) the connected camera beats the remembered reading', () {
      final specs = resolver.resolve(
        CameraSensorSpecInputs(
          cameraName: 'ASI1600MM-Cool',
          liveReading: reading(width: 4656, height: 3520, pitch: 3.81),
          rememberedReading: reading(
            width: 1,
            height: 1,
            pitch: 9.9,
            readAt: DateTime(2026, 9, 1),
          ),
        ),
      );
      expect(specs.pixelSizeMicrons!.value, 3.81);
      expect(specs.pixelSizeMicrons!.origin, SensorSpecOrigin.connectedCamera);
      expect(
        specs.pixelSizeMicrons!.provenance,
        'read from the connected ZWO ASI1600MM',
      );
      expect(specs.sensorWidthPx!.value, 4656);
    });

    test('(c) the remembered reading beats the published specification', () {
      // This is the defect the owner reported: the app had already read the
      // camera and written it to disk, and the planner still said "not
      // configured". The remembered reading must be preferred to the
      // manufacturer's figure because it describes the crop actually in use.
      final specs = resolver.resolve(
        CameraSensorSpecInputs(
          cameraName: 'ASI1600MM-Cool',
          rememberedReading: reading(
            width: 4656,
            height: 3520,
            pitch: 3.81,
            readAt: DateTime(2026, 9, 12),
          ),
        ),
      );
      expect(specs.pixelSizeMicrons!.value, 3.81);
      expect(specs.pixelSizeMicrons!.origin, SensorSpecOrigin.rememberedCamera);
      expect(
        specs.pixelSizeMicrons!.provenance,
        'remembered from ZWO ASI1600MM on 2026-09-12',
      );
      // Read noise is not something a driver reports, so it still comes from
      // the published specification even here.
      expect(specs.readNoiseE!.origin, SensorSpecOrigin.modelDatabase);
    });

    test('(d) the published specification answers with no camera present', () {
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'ASI1600MM-Cool'),
      );
      expect(specs.pixelSizeMicrons!.value, 3.8);
      expect(specs.pixelSizeMicrons!.origin, SensorSpecOrigin.modelDatabase);
      expect(
        specs.pixelSizeMicrons!.provenance,
        'the published pixel pitch for ZWO ASI1600MM',
      );
      expect(specs.sensorWidthPx!.value, 4656);
      expect(specs.sensorHeightPx!.value, 3520);
      expect(specs.readNoiseE!.value, 1.2);
      expect(specs.fullWellE!.value, 20000);
      expect(specs.qePeakFraction!.value, 0.60);
      expect(specs.unresolvedFields, isEmpty);
    });

    test('(e) an unidentified camera resolves nothing and names itself', () {
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'Acme SkyCam 9000'),
      );
      expect(specs.databaseEntry, isNull);
      expect(specs.reportedModel, 'Acme SkyCam 9000');
      expect(specs.isEmpty, isTrue);
      expect(specs.unresolvedFields, SensorSpecField.values);
      expect(specs.hasGeometry, isFalse);
      expect(specs.originLabel, isNull);
    });

    test('an unidentified camera still uses a live reading', () {
      final specs = resolver.resolve(
        CameraSensorSpecInputs(
          cameraName: 'Acme SkyCam 9000',
          liveReading: reading(width: 640, height: 480, pitch: 5.6),
        ),
      );
      expect(specs.pixelSizeMicrons!.value, 5.6);
      expect(
        specs.pixelSizeMicrons!.provenance,
        'read from the connected Acme SkyCam 9000',
      );
      // Nothing publishes this camera's noise figures, so they stay unknown.
      expect(specs.readNoiseE, isNull);
      expect(specs.unresolvedFields, [
        SensorSpecField.readNoise,
        SensorSpecField.fullWell,
        SensorSpecField.qePeak,
      ]);
    });

    test('nothing at all resolves nothing', () {
      final specs = resolver.resolve(const CameraSensorSpecInputs());
      expect(specs.reportedModel, isNull);
      expect(specs.isEmpty, isTrue);
    });

    test('a zeroed driver reading is ignored, not believed', () {
      // Drivers report zeroes before a camera finishes initialising.
      final specs = resolver.resolve(
        CameraSensorSpecInputs(
          cameraName: 'ASI1600MM-Cool',
          liveReading: reading(width: 0, height: 0, pitch: 0),
        ),
      );
      expect(specs.pixelSizeMicrons!.origin, SensorSpecOrigin.modelDatabase);
    });

    test('a non-square pixel reading is averaged, not truncated', () {
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(
          cameraName: 'ASI1600MM-Cool',
          liveReading: SensorGeometryReading(
            widthPx: 100,
            heightPx: 100,
            pixelSizeXMicrons: 4.0,
            pixelSizeYMicrons: 5.0,
          ),
        ),
      );
      expect(specs.pixelSizeMicrons!.value, 4.5);
    });
  });

  group('gain-dependent figures are never flattened', () {
    test('a figure published at a driver gain is used at that gain', () {
      // ZWO's ASI6200 manual: HCG turns on at gain 100 and read noise is
      // 1.5e there.
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'ASI6200MM Pro', gain: 100),
      );
      expect(specs.readNoiseE!.value, 1.5);
      expect(
        specs.readNoiseE!.provenance,
        'the published figure for ZWO ASI6200MM Pro at your gain of 100',
      );
    });

    test('off that gain, the conservative end of the range is used', () {
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'ASI6200MM Pro', gain: 0),
      );
      expect(specs.readNoiseE!.value, 3.5);
      expect(
        specs.readNoiseE!.provenance,
        contains('the high end of the published 1.5–3.5 e⁻ range'),
      );
      expect(
        specs.readNoiseE!.provenance,
        contains('does not publish it per gain'),
      );
    });

    test('a range with no attribution takes the unflattering end', () {
      // ASI2600: read noise 1.0-3.3e, full well 50ke. The high read noise and
      // the low full well are the ends that do not flatter the camera.
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'ASI2600MM Pro', gain: 100),
      );
      expect(specs.readNoiseE!.value, 3.3);
      expect(specs.fullWellE!.value, 50000);
      expect(specs.fullWellE!.provenance, contains('with no gain stated'));
    });

    test('a dB-quoted figure keeps the manufacturer\'s own label', () {
      // ZWO quotes the ASI1600's read noise only "@30db gain" and does not
      // publish the dB-to-driver-gain mapping, so the label is carried
      // verbatim rather than converted into a gain number.
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'ASI1600MM-Cool', gain: 139),
      );
      expect(specs.readNoiseE!.value, 1.2);
      expect(
        specs.readNoiseE!.provenance,
        'the published figure for ZWO ASI1600MM, which the manufacturer '
        'quotes only at 30 dB gain',
      );
    });

    test('a field the manufacturer will not publish stays unknown', () {
      // ZWO publishes only a best-case read noise for the ASI533MM Pro, with
      // no gain, so the row omits it rather than presenting the best case as
      // the value.
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'ASI533MM Pro', gain: 100),
      );
      expect(specs.readNoiseE, isNull);
      expect(specs.unresolvedFields, [SensorSpecField.readNoise]);
      expect(specs.fullWellE!.value, 50000);
      expect(specs.qePeakFraction!.value, 0.91);
    });

    test('QHY rows have no QE because QHY publishes no peak figure', () {
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'QHY600M'),
      );
      expect(specs.qePeakFraction, isNull);
      expect(specs.unresolvedFields, [SensorSpecField.qePeak]);
    });

    test('two published points bracket the gain and get interpolated', () {
      final db = CameraSensorSpecResolver(database: _twoPointDatabase);
      final specs = db.resolve(
        const CameraSensorSpecInputs(cameraName: 'TestCam', gain: 50),
      );
      expect(specs.readNoiseE!.value, closeTo(2.5, 1e-9));
      expect(
        specs.readNoiseE!.provenance,
        'interpolated between the published figures for TestCam at gain 0 '
        'and gain 100',
      );
    });
  });

  group('provenance for display', () {
    test('the summary lists only what resolved', () {
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'ASI1600MM-Cool'),
      );
      expect(
        specs.valueSummary,
        '3.8 µm · 4656 × 3520 · 1.2 e⁻ read noise · 20,000 e⁻ well · 60% QE',
      );
      expect(specs.originLabel, 'Published specs');
    });

    test('a mixed set says every source in play', () {
      final specs = resolver.resolve(
        CameraSensorSpecInputs(
          cameraName: 'ASI1600MM-Cool',
          rememberedReading: reading(
            width: 4656,
            height: 3520,
            pitch: 3.8,
            readAt: DateTime(2026, 9, 12),
          ),
        ),
      );
      expect(specs.originLabel, 'Remembered');
      // One clause per distinct source phrase, labelled with the fields it
      // covers — collapsing by tier hid the read noise's operating point,
      // which is the clause a reader can be misled by.
      expect(
        specs.provenanceSentence,
        'Pixel size, sensor width and sensor height: remembered from '
        'ZWO ASI1600MM on 2026-09-12. '
        'Read noise: the published figure for ZWO ASI1600MM, which the '
        'manufacturer quotes only at 30 dB gain. '
        'Full well: the published figure for ZWO ASI1600MM, which the '
        'manufacturer quotes with no gain stated. '
        'QE: the published peak QE for ZWO ASI1600MM.',
      );
    });

    test('nothing resolved produces no provenance sentence', () {
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'Acme SkyCam 9000'),
      );
      expect(specs.provenanceSentence, isEmpty);
    });

    test('a derived DSLR pitch says it was derived', () {
      final specs = resolver.resolve(
        const CameraSensorSpecInputs(cameraName: 'Canon EOS 60Da'),
      );
      expect(
        specs.pixelSizeMicrons!.provenance,
        'derived from the published sensor size and pixel count for '
        'Canon EOS 60Da',
      );
      expect(specs.pixelSizeMicrons!.value, closeTo(4.301, 0.001));
    });
  });

  group('UserSensorSpecOverrides round trip', () {
    test('json survives a round trip', () {
      const overrides = UserSensorSpecOverrides(
        pixelSizeMicrons: 3.8,
        sensorWidthPx: 4656,
        sensorHeightPx: 3520,
        readNoiseE: 1.7,
        fullWellE: 20100,
        qePeakFraction: 0.58,
      );
      final restored = UserSensorSpecOverrides.fromJson(overrides.toJson());
      expect(restored.pixelSizeMicrons, 3.8);
      expect(restored.sensorWidthPx, 4656);
      expect(restored.sensorHeightPx, 3520);
      expect(restored.readNoiseE, 1.7);
      expect(restored.fullWellE, 20100);
      expect(restored.qePeakFraction, 0.58);
    });

    test('a nonsense entry is treated as absent, not as a fact', () {
      final restored = UserSensorSpecOverrides.fromJson({
        'pixelSizeUm': -1,
        'widthPx': 'wide',
        'readNoiseE': 0,
        'fullWellE': double.nan,
        'qePeak': '0.42',
      });
      expect(restored.pixelSizeMicrons, isNull);
      expect(restored.sensorWidthPx, isNull);
      expect(restored.readNoiseE, isNull);
      expect(restored.fullWellE, isNull);
      expect(restored.qePeakFraction, 0.42);
    });

    test('a non-map is empty', () {
      expect(UserSensorSpecOverrides.fromJson('nope').isEmpty, isTrue);
      expect(UserSensorSpecOverrides.fromJson(null).isEmpty, isTrue);
    });
  });
}

/// A two-gain-point camera, to exercise interpolation along a curve the
/// manufacturer actually published at both ends. No real row in the curated
/// database has two attributed read-noise points.
final _twoPointDatabase = CameraSensorDatabase(
  entries: const [
    CameraSensorEntry(
      model: 'TestCam',
      driverNames: ['TestCam'],
      sensor: 'Test IMX000',
      widthPx: 1000,
      heightPx: 1000,
      publishedPixelSizeMicrons: 4.0,
      readNoiseE: [
        PublishedFigure.atGain(4.0, gain: 0),
        PublishedFigure.atGain(1.0, gain: 100),
      ],
      source: 'http://example.test/testcam',
    ),
  ],
);

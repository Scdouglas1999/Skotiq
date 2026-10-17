import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('ProfileValidator.parseName', () {
    test('rejects blank and whitespace-only names', () {
      expect(ProfileValidator.parseName('').isValid, isFalse);
      expect(ProfileValidator.parseName('   ').isValid, isFalse);
      expect(ProfileValidator.parseName('\t\n').isValid, isFalse);
    });

    test('trims and accepts a normal name', () {
      final r = ProfileValidator.parseName('  Main Rig  ');
      expect(r.isValid, isTrue);
      expect(r.value, 'Main Rig');
    });

    test('rejects a name longer than the 100-char schema bound', () {
      final tooLong = 'x' * (EquipmentProfileLimits.nameMaxLength + 1);
      expect(ProfileValidator.parseName(tooLong).isValid, isFalse);
      final atLimit = 'x' * EquipmentProfileLimits.nameMaxLength;
      expect(ProfileValidator.parseName(atLimit).isValid, isTrue);
    });
  });

  group('ProfileValidator optics field parsing', () {
    test('blank maps to the 0 "unspecified" sentinel', () {
      final focal = ProfileValidator.parseFocalLength('');
      expect(focal.isValid, isTrue);
      expect(focal.value, 0.0);
      final aperture = ProfileValidator.parseAperture('');
      expect(aperture.isValid, isTrue);
      expect(aperture.value, 0.0);
    });

    test('accepts a finite positive value (int or decimal)', () {
      expect(ProfileValidator.parseFocalLength('550').value, 550.0);
      expect(ProfileValidator.parseFocalLength('714.5').value, 714.5);
      expect(ProfileValidator.parseAperture('61').value, 61.0);
    });

    test('rejects malformed, NaN, infinite, zero, and negative input', () {
      for (final raw in ['abc', 'NaN', 'Infinity', '0', '-5']) {
        expect(
          ProfileValidator.parseFocalLength(raw).isValid,
          isFalse,
          reason: 'focal length "$raw"',
        );
        expect(
          ProfileValidator.parseAperture(raw).isValid,
          isFalse,
          reason: 'aperture "$raw"',
        );
      }
    });

    // The live defect: a fat-fingered focal length paired with a near-zero
    // aperture was accepted and rendered as f/9999999990000.00.
    test('rejects a focal length outside the shared plausibility bound', () {
      final absurd = ProfileValidator.parseFocalLength('999999999');
      expect(absurd.isValid, isFalse);
      expect(absurd.error, contains('50000'));
      expect(
        ProfileValidator.parseFocalLength(
          '${OpticalTrainLimits.maxFocalLengthMm}',
        ).isValid,
        isTrue,
        reason: 'the bound itself must remain valid',
      );
    });

    test('rejects an aperture outside the shared plausibility bound', () {
      expect(ProfileValidator.parseAperture('0.0001').isValid, isFalse);
      expect(ProfileValidator.parseAperture('99999').isValid, isFalse);
      expect(
        ProfileValidator.parseAperture(
          '${OpticalTrainLimits.maxApertureMm}',
        ).isValid,
        isTrue,
      );
    });

    test('the bound reads without a trailing .0', () {
      expect(
        ProfileValidator.parseFocalLength('999999999').error,
        'Focal length must be between 1 and 50000 mm',
      );
    });
  });

  group('ProfileValidator.validateOpticalTrain', () {
    test('an entirely unspecified train is accepted', () {
      expect(
        ProfileValidator.validateOpticalTrain(focalLengthMm: 0, apertureMm: 0),
        isNull,
      );
    });

    test('real rigs validate', () {
      // focal mm, aperture mm, pixel µm
      const rigs = <List<double?>>[
        [135, 67.5, 3.76], // Samyang 135 f/2 + IMX571
        [250, 51, 2.9], // RedCat 51 (petzval, f/4.9)
        [2032, 203.2, 3.76], // EdgeHD 8 at native f/10
        [620, 279, 4.63], // RASA 11 f/2.2
        [7800, 355.6, 3.76], // C14 + 2x barlow
        [12, 8, 5.86], // all-sky lens
        [8000, 1000, 9.0], // 1 m professional f/8
      ];
      for (final rig in rigs) {
        expect(
          ProfileValidator.validateOpticalTrain(
            focalLengthMm: rig[0]!,
            apertureMm: rig[1]!,
            pixelSizeMicrons: rig[2],
          ),
          isNull,
          reason: 'rig $rig must stay valid',
        );
      }
    });

    test('rejects the live defect pair', () {
      final error = ProfileValidator.validateOpticalTrain(
        focalLengthMm: 999999999,
        apertureMm: 0.0001,
      );
      expect(error, isNotNull);
    });

    test('rejects an impossible f-ratio built from in-range fields', () {
      // Both numbers are individually inside their own bounds; only the ratio
      // they imply is impossible.
      final error = ProfileValidator.validateOpticalTrain(
        focalLengthMm: 40000,
        apertureMm: 2,
      );
      expect(error, isNotNull);
      expect(error, contains('f/'));
    });

    test('a half-specified train judges only the field that was supplied', () {
      // Focal length known, aperture left unspecified: accepted.
      expect(
        ProfileValidator.validateOpticalTrain(
          focalLengthMm: 600,
          apertureMm: 0,
        ),
        isNull,
      );
      // ...and still rejected when the supplied side is itself absurd.
      expect(
        ProfileValidator.validateOpticalTrain(
          focalLengthMm: 999999999,
          apertureMm: 0,
        ),
        isNotNull,
      );
      // Aperture known, focal length unspecified: accepted, including at both
      // ends of the aperture range, where the substituted focal length must
      // not itself trip a bound.
      for (final aperture in <double>[
        OpticalTrainLimits.minApertureMm,
        61,
        OpticalTrainLimits.maxApertureMm,
      ]) {
        expect(
          ProfileValidator.validateOpticalTrain(
            focalLengthMm: 0,
            apertureMm: aperture,
          ),
          isNull,
          reason: 'aperture-only $aperture mm',
        );
      }
      expect(
        ProfileValidator.validateOpticalTrain(
          focalLengthMm: 0,
          apertureMm: 0.0001,
        ),
        isNotNull,
      );
      // Likewise the smallest legal focal length on its own: the substituted
      // aperture is clamped up into range, so it cannot cause a false reject.
      expect(
        ProfileValidator.validateOpticalTrain(
          focalLengthMm: OpticalTrainLimits.minFocalLengthMm,
          apertureMm: 0,
        ),
        isNull,
      );
    });

    test('an absurd pixel size is caught even with optics unspecified', () {
      expect(
        ProfileValidator.validateOpticalTrain(
          focalLengthMm: 0,
          apertureMm: 0,
          pixelSizeMicrons: 99999,
        ),
        isNotNull,
      );
    });

    // Anti-drift lock: the profile path must not grow its own wording or its
    // own numbers. If someone edits either side, this fails.
    test('delegates verbatim to OpticalTrainLimits', () {
      expect(
        ProfileValidator.validateOpticalTrain(
          focalLengthMm: 999999999,
          apertureMm: 120,
          pixelSizeMicrons: 3.76,
        ),
        OpticalTrainLimits.validate(
          focalLengthMm: 999999999,
          apertureMm: 120,
          pixelSizeMicrons: 3.76,
          reducerFactor: 1.0,
        ),
      );
      expect(
        ProfileValidator.validateOpticalTrain(
          focalLengthMm: 40000,
          apertureMm: 2,
          pixelSizeMicrons: 3.76,
        ),
        OpticalTrainLimits.validate(
          focalLengthMm: 40000,
          apertureMm: 2,
          pixelSizeMicrons: 3.76,
          reducerFactor: 1.0,
        ),
      );
    });
  });

  group('ProfileValidator.parseOptionalWholeNonNegative', () {
    test('blank maps to null', () {
      final r = ProfileValidator.parseOptionalWholeNonNegative(
        '',
        label: 'Gain',
      );
      expect(r.isValid, isTrue);
      expect(r.value, isNull);
    });

    test('accepts a whole non-negative integer', () {
      expect(
        ProfileValidator.parseOptionalWholeNonNegative('100', label: 'x').value,
        100,
      );
      expect(
        ProfileValidator.parseOptionalWholeNonNegative('0', label: 'x').value,
        0,
      );
    });

    test('rejects negative, fractional, and malformed input', () {
      expect(
        ProfileValidator.parseOptionalWholeNonNegative(
          '-1',
          label: 'x',
        ).isValid,
        isFalse,
      );
      expect(
        ProfileValidator.parseOptionalWholeNonNegative(
          '3.5',
          label: 'x',
        ).isValid,
        isFalse,
      );
      expect(
        ProfileValidator.parseOptionalWholeNonNegative(
          'abc',
          label: 'x',
        ).isValid,
        isFalse,
      );
    });
  });

  group('ProfileValidator.parseCoolingTarget', () {
    test('blank maps to null; negative finite is accepted', () {
      expect(ProfileValidator.parseCoolingTarget('').value, isNull);
      final r = ProfileValidator.parseCoolingTarget('-10');
      expect(r.isValid, isTrue);
      expect(r.value, -10.0);
    });

    test('rejects malformed and non-finite input', () {
      expect(ProfileValidator.parseCoolingTarget('abc').isValid, isFalse);
      expect(ProfileValidator.parseCoolingTarget('NaN').isValid, isFalse);
      expect(ProfileValidator.parseCoolingTarget('Infinity').isValid, isFalse);
    });
  });

  group('ProfileValidator.parseCenteringExposure', () {
    test('blank maps to null', () {
      expect(ProfileValidator.parseCenteringExposure('').value, isNull);
    });

    test('accepts values inside the canonical 0.001..86400 window', () {
      expect(ProfileValidator.parseCenteringExposure('5').value, 5.0);
      expect(ProfileValidator.parseCenteringExposure('0.001').isValid, isTrue);
      expect(ProfileValidator.parseCenteringExposure('86400').isValid, isTrue);
    });

    test('rejects out-of-range, malformed, and non-finite input', () {
      expect(ProfileValidator.parseCenteringExposure('0').isValid, isFalse);
      expect(
        ProfileValidator.parseCenteringExposure('0.0005').isValid,
        isFalse,
      );
      expect(ProfileValidator.parseCenteringExposure('90000').isValid, isFalse);
      expect(ProfileValidator.parseCenteringExposure('abc').isValid, isFalse);
      expect(
        ProfileValidator.parseCenteringExposure('Infinity').isValid,
        isFalse,
      );
    });
  });

  group('ProfileValidator.parseBinning', () {
    test('accepts 1..4, rejects outside the offered range', () {
      expect(ProfileValidator.parseBinning(1).isValid, isTrue);
      expect(ProfileValidator.parseBinning(4).isValid, isTrue);
      expect(ProfileValidator.parseBinning(0).isValid, isFalse);
      expect(ProfileValidator.parseBinning(5).isValid, isFalse);
    });
  });

  group('ProfileValidator.parseFilterRows', () {
    ProfileFilterRowInput row(String name, String offset) =>
        ProfileFilterRowInput(name: name, offset: offset);

    test('empty input yields an empty, valid config', () {
      final r = ProfileValidator.parseFilterRows([]);
      expect(r.isValid, isTrue);
      expect(r.config!.names, isEmpty);
      expect(r.config!.offsets, isEmpty);
    });

    test('a blank row with a blank/default offset is dropped', () {
      expect(
        ProfileValidator.parseFilterRows([row('', '')]).config!.names,
        isEmpty,
      );
      expect(
        ProfileValidator.parseFilterRows([row('', '0')]).config!.names,
        isEmpty,
      );
    });

    test('a blank name with a non-blank/non-zero offset is rejected', () {
      expect(ProfileValidator.parseFilterRows([row('', '5')]).isValid, isFalse);
      expect(
        ProfileValidator.parseFilterRows([row('', 'abc')]).isValid,
        isFalse,
      );
    });

    test('duplicate names are rejected case-insensitively', () {
      final r = ProfileValidator.parseFilterRows([
        row('Ha', '0'),
        row('ha', '0'),
      ]);
      expect(r.isValid, isFalse);
    });

    test('a malformed non-blank offset is rejected, never coerced to 0', () {
      expect(
        ProfileValidator.parseFilterRows([row('R', 'x')]).isValid,
        isFalse,
      );
    });

    test('legitimate negative focus offsets are preserved', () {
      final r = ProfileValidator.parseFilterRows([row('R', '-30')]);
      expect(r.isValid, isTrue);
      expect(r.config!.offsets['R'], -30);
    });

    test(
      'trims names, drops zero offsets, keeps order and non-zero offsets',
      () {
        final r = ProfileValidator.parseFilterRows([
          row('  L  ', '10'),
          row('R', '0'),
          row('G', '15'),
          row('B', ''),
        ]);
        expect(r.isValid, isTrue);
        expect(r.config!.names, ['L', 'R', 'G', 'B']);
        expect(r.config!.offsets, {'L': 10, 'G': 15});
      },
    );
  });

  group('ProfileValidator.validateWireProfile', () {
    EquipmentProfile base({
      String name = 'Valid',
      double focalLength = 0.0,
      double aperture = 0.0,
      int? defaultGain,
      int? defaultOffset,
      double? defaultCoolingTemp,
      double? defaultCenteringExposure,
      int defaultBinX = 1,
      int defaultBinY = 1,
      String? filterNames,
      String? filterFocusOffsets,
      String? meridianFlipOverrides,
      double? focalRatio,
      double? pixelSize,
      double telescopeFocalLength = 0.0,
      double telescopeAperture = 0.0,
      int sortOrder = 0,
    }) {
      return EquipmentProfile(
        id: '1',
        name: name,
        focalLength: focalLength,
        aperture: aperture,
        telescopeFocalLength: telescopeFocalLength,
        telescopeAperture: telescopeAperture,
        defaultGain: defaultGain,
        defaultOffset: defaultOffset,
        defaultCoolingTemp: defaultCoolingTemp,
        defaultCenteringExposure: defaultCenteringExposure,
        defaultBinX: defaultBinX,
        defaultBinY: defaultBinY,
        filterNames: filterNames,
        filterFocusOffsets: filterFocusOffsets,
        meridianFlipOverrides: meridianFlipOverrides,
        focalRatio: focalRatio,
        pixelSize: pixelSize,
        sortOrder: sortOrder,
      );
    }

    test('a well-formed profile passes', () {
      expect(
        ProfileValidator.validateWireProfile(
          base(
            focalLength: 550,
            aperture: 100,
            defaultGain: 100,
            defaultCenteringExposure: 5,
            filterNames: '["R","G","B"]',
          ),
        ),
        isNull,
      );
    });

    test('blank / overlong name is rejected', () {
      expect(
        ProfileValidator.validateWireProfile(base(name: '   ')),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(
          base(name: 'x' * (EquipmentProfileLimits.nameMaxLength + 1)),
        ),
        isNotNull,
      );
    });

    test('non-finite / negative optics are rejected', () {
      expect(
        ProfileValidator.validateWireProfile(base(focalLength: -1)),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(base(aperture: double.nan)),
        isNotNull,
      );
    });

    // Unvalidated, `POST /api/profiles` answers 200 and persists focalLength
    // 999999999 with aperture 0.0001, which reads back as f/9999999990000.00
    // and lands in the FITS FOCALLEN card.
    test('implausible optics are rejected on the wire', () {
      expect(
        ProfileValidator.validateWireProfile(
          base(focalLength: 999999999, aperture: 0.0001),
        ),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(base(focalLength: 999999999)),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(base(aperture: 0.0001)),
        isNotNull,
      );
      // In-range fields whose ratio is impossible.
      expect(
        ProfileValidator.validateWireProfile(
          base(focalLength: 40000, aperture: 2),
        ),
        isNotNull,
      );
    });

    test('an implausible stored focal ratio is rejected', () {
      expect(
        ProfileValidator.validateWireProfile(
          base(focalLength: 550, aperture: 100, focalRatio: 9999999990000.0),
        ),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(
          base(focalLength: 550, aperture: 100, focalRatio: 5.5),
        ),
        isNull,
      );
    });

    test('an implausible pixel size is rejected', () {
      expect(
        ProfileValidator.validateWireProfile(
          base(focalLength: 550, aperture: 100, pixelSize: 99999),
        ),
        isNotNull,
      );
    });

    // The editor prefers `telescopeFocalLength` when repopulating the form, so
    // an unbounded value there comes back as the profile's focal length.
    test('implausible legacy telescope optics are rejected', () {
      expect(
        ProfileValidator.validateWireProfile(
          base(telescopeFocalLength: 999999999),
        ),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(base(telescopeAperture: 0.0001)),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(
          base(telescopeFocalLength: 2032, telescopeAperture: 203.2),
        ),
        isNull,
      );
    });

    test('negative gain/offset and non-finite cooling are rejected', () {
      expect(
        ProfileValidator.validateWireProfile(base(defaultGain: -1)),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(base(defaultOffset: -5)),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(
          base(defaultCoolingTemp: double.infinity),
        ),
        isNotNull,
      );
    });

    test('out-of-range centering exposure and binning are rejected', () {
      expect(
        ProfileValidator.validateWireProfile(
          base(defaultCenteringExposure: 90000),
        ),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(base(defaultBinX: 5)),
        isNotNull,
      );
    });

    test('malformed or duplicate filterNames JSON is rejected', () {
      expect(
        ProfileValidator.validateWireProfile(base(filterNames: 'not json[')),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(base(filterNames: '["Ha","ha"]')),
        isNotNull,
      );
    });

    test('focal ratio, pixel size, and sort order must be physical', () {
      expect(
        ProfileValidator.validateWireProfile(base(focalRatio: 0)),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(base(pixelSize: -1)),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(base(sortOrder: -1)),
        isNotNull,
      );
    });

    test(
      'filter focus offsets must be an integer map for configured filters',
      () {
        expect(
          ProfileValidator.validateWireProfile(
            base(filterNames: '["L"]', filterFocusOffsets: '{'),
          ),
          isNotNull,
        );
        expect(
          ProfileValidator.validateWireProfile(
            base(filterNames: '["L"]', filterFocusOffsets: '{"L":1.5}'),
          ),
          isNotNull,
        );
        expect(
          ProfileValidator.validateWireProfile(
            base(filterNames: '["L"]', filterFocusOffsets: '{"R":10}'),
          ),
          isNotNull,
        );
        expect(
          ProfileValidator.validateWireProfile(
            base(filterNames: '["L"]', filterFocusOffsets: '{"L":-10}'),
          ),
          isNull,
        );
      },
    );

    test('meridian flip overrides must be a valid bounded partial object', () {
      expect(
        ProfileValidator.validateWireProfile(base(meridianFlipOverrides: '[]')),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(
          base(meridianFlipOverrides: '{"maxRetries":11}'),
        ),
        isNotNull,
      );
      expect(
        ProfileValidator.validateWireProfile(
          base(meridianFlipOverrides: '{"maxRetries":4}'),
        ),
        isNull,
      );
    });
  });
}

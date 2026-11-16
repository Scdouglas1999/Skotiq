import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

/// The owner's wheel (profile "10\" Newt", ZWO EFW, 8 slots).
const _ownerWheel = ['L', 'R', 'G', 'B', 'Ha', 'SII', 'OIII', 'DARK'];

const _darkMoon = 3.0;
const _brightMoon = 90.0;

TargetSuggestion _target(String name, String? objectType) => TargetSuggestion(
  targetId: name.hashCode,
  targetName: name,
  raHours: 5.5,
  decDegrees: 22,
  totalScore: 90,
  objectType: objectType,
  visibility: const TargetVisibilityInfo(
    currentAltitude: 55,
    currentAzimuth: 111,
    airmass: 1.2,
    moonDistance: 90,
  ),
);

SmartNightFilterChoice _choose(
  TargetSuggestion target, {
  List<String> wheel = _ownerWheel,
  double moon = _darkMoon,
  bool oneShotColor = false,
}) => chooseSmartNightFilters(
  target: target,
  availableFilters: wheel,
  moonIlluminationPercent: moon,
  oneShotColor: oneShotColor,
);

void main() {
  group('owner wheel on a mono camera', () {
    test('M1, a supernova remnant, is imaged SHO', () {
      final choice = _choose(_target('M1', DsoType.supernova.displayName));
      expect(choice.strategy, SmartNightStrategy.narrowbandSho);
      expect(choice.filters, ['Ha', 'OIII', 'SII']);
      expect(choice.reason, 'Narrowband SHO: M1 is a supernova remnant.');
    });

    test('NGC1952 by its catalog code is imaged SHO under any moon', () {
      for (final moon in [_darkMoon, _brightMoon]) {
        final choice = _choose(_target('NGC1952', 'SNR'), moon: moon);
        expect(choice.filters, ['Ha', 'OIII', 'SII'], reason: 'moon $moon');
      }
    });

    test('M31, a galaxy, is imaged LRGB under any moon', () {
      for (final moon in [_darkMoon, _brightMoon]) {
        final choice = _choose(_target('M31', 'Galaxy'), moon: moon);
        expect(choice.strategy, SmartNightStrategy.autoLrgb);
        expect(choice.filters, ['L', 'R', 'G', 'B']);
        expect(choice.reason, 'LRGB: M31 is a galaxy.');
      }
    });

    test('a planetary nebula and an HII region are narrowband', () {
      expect(_choose(_target('M57', 'Planetary Nebula')).filters, [
        'Ha',
        'OIII',
        'SII',
      ]);
      expect(
        _choose(_target('NGC7000', 'HII Region')).reason,
        'Narrowband SHO: NGC7000 is an HII region.',
      );
    });

    test('M42, a cluster in its nebula, is LRGB + Ha under a dark sky and '
        'SHO under a bright moon', () {
      final m42 = _target('M42', DsoType.clusterWithNebulosity.displayName);
      final dark = _choose(m42, moon: 12);
      expect(dark.strategy, SmartNightStrategy.haLrgb);
      expect(dark.filters, ['L', 'R', 'G', 'B', 'Ha']);
      expect(
        dark.reason,
        'LRGB + Ha: M42 is a cluster and nebula, and the moon is 12% lit.',
      );
      final bright = _choose(m42, moon: 80);
      expect(bright.strategy, SmartNightStrategy.narrowbandSho);
      expect(
        bright.reason,
        'Narrowband SHO: M42 is a cluster and nebula, and the moon is 80% '
        'lit.',
      );
    });

    test('a reflection nebula and a cluster are LRGB', () {
      expect(
        _choose(_target('M78', 'Reflection Nebula'), moon: _brightMoon).filters,
        ['L', 'R', 'G', 'B'],
      );
      expect(_choose(_target('M45', 'Open Cluster')).filters, [
        'L',
        'R',
        'G',
        'B',
      ]);
    });

    test('a target with no type is LRGB and says so', () {
      expect(
        _choose(_target('Unknown 1', null)).reason,
        'LRGB: Unknown 1 has no object type in the catalog.',
      );
    });
  });

  group('what the wheel holds', () {
    final m1 = _target('M1', DsoType.supernova.displayName);

    test('Ha and OIII without SII is HOO', () {
      expect(
        _choose(m1, wheel: const ['Ha', 'OIII']).strategy,
        SmartNightStrategy.narrowbandHoo,
      );
      expect(
        _choose(m1, wheel: const ['L', 'R', 'G', 'B', 'Ha', 'OIII']).filters,
        ['Ha', 'OIII'],
      );
    });

    test('Ha alone is Ha', () {
      final choice = _choose(m1, wheel: const ['L', 'R', 'G', 'B', 'Ha']);
      expect(choice.strategy, SmartNightStrategy.narrowbandHa);
      expect(choice.filters, ['Ha']);
    });

    test('an emission target on a broadband wheel is LRGB and says why', () {
      final choice = _choose(m1, wheel: const ['L', 'R', 'G', 'B']);
      expect(choice.strategy, SmartNightStrategy.autoLrgb);
      expect(
        choice.reason,
        'LRGB: M1 is a supernova remnant, but the wheel has no Ha filter.',
      );
    });

    test('a galaxy on a narrowband wheel is narrowband and says why', () {
      final choice = _choose(
        _target('M31', 'Galaxy'),
        wheel: const ['Ha', 'OIII', 'SII'],
      );
      expect(choice.filters, ['Ha', 'OIII', 'SII']);
      expect(
        choice.reason,
        'Narrowband SHO: M31 is a galaxy, but the wheel has no L, R, G or B '
        'filter.',
      );
    });

    test('slots are matched by band, never by a piece of a name', () {
      final choice = _choose(
        m1,
        wheel: const ['Dark', 'Baader Ha 7nm', 'OIII 6.5nm', 'Sulfur II'],
      );
      expect(choice.filters, ['Baader Ha 7nm', 'OIII 6.5nm', 'Sulfur II']);
      expect(
        _choose(
          _target('M31', 'Galaxy'),
          wheel: const ['Luminance', 'Red', 'Green', 'Blue', 'Dark'],
        ).filters,
        ['Luminance', 'Red', 'Green', 'Blue'],
      );
    });

    test('no wheel captures unfiltered', () {
      final choice = _choose(m1, wheel: const []);
      expect(choice.filters, [smartNightUnfilteredName]);
      expect(choice.reason, 'No filter: this rig has no filter wheel.');
    });
  });

  group('color camera', () {
    test('a color camera with no wheel takes no filter', () {
      final choice = _choose(
        _target('M1', DsoType.supernova.displayName),
        wheel: const [],
        oneShotColor: true,
      );
      expect(choice.strategy, SmartNightStrategy.oscOneShot);
      expect(choice.filters, [smartNightUnfilteredName]);
      expect(choice.reason, 'One-shot color: this rig has no filter wheel.');
    });

    test('a color camera takes the dual-band for emission and the light '
        'filter for a galaxy', () {
      const wheel = ['UV/IR Cut', 'L-eXtreme'];
      final m1 = _choose(
        _target('M1', DsoType.supernova.displayName),
        wheel: wheel,
        oneShotColor: true,
      );
      expect(m1.filters, ['L-eXtreme']);
      expect(
        m1.reason,
        'One-shot color through L-eXtreme: M1 is a supernova remnant, and the '
        'camera is a color camera.',
      );
      expect(
        _choose(
          _target('M31', 'Galaxy'),
          wheel: wheel,
          oneShotColor: true,
        ).filters,
        ['UV/IR Cut'],
      );
    });

    test('a color camera never rotates LRGB or SHO', () {
      final choice = _choose(
        _target('M1', DsoType.supernova.displayName),
        oneShotColor: true,
      );
      expect(choice.strategy, SmartNightStrategy.oscOneShot);
      expect(choice.filters, hasLength(1));
    });
  });

  group('a set the user picks', () {
    final choice = _choose(_target('M1', DsoType.supernova.displayName));

    test('lists only the sets the wheel can capture', () {
      final narrowbandOnly = _choose(
        _target('M1', DsoType.supernova.displayName),
        wheel: const ['Ha', 'OIII'],
      );
      expect(
        narrowbandOnly.capturable,
        isNot(contains(SmartNightStrategy.narrowbandSho)),
      );
      expect(
        narrowbandOnly.capturable,
        isNot(contains(SmartNightStrategy.autoLrgb)),
      );
      expect(choice.capturable, contains(SmartNightStrategy.autoLrgb));
    });

    test('maps to its slots and says it was the user who picked it', () {
      expect(choice.filtersFor(SmartNightStrategy.autoLrgb), [
        'L',
        'R',
        'G',
        'B',
      ]);
      expect(
        choice.reasonFor(SmartNightStrategy.autoLrgb),
        'LRGB: your choice.',
      );
      expect(choice.reasonFor(choice.strategy), choice.reason);
    });
  });

  test('object types read as emission, mixed or broadband', () {
    const cases = {
      'Supernova Remnant': TargetLight.emission,
      'SNR': TargetLight.emission,
      'Emission Nebula': TargetLight.emission,
      'HII Region': TargetLight.emission,
      'Planetary Nebula': TargetLight.emission,
      'PN': TargetLight.emission,
      'Cluster + Nebula': TargetLight.mixed,
      'Cl+N': TargetLight.mixed,
      'Nebula': TargetLight.mixed,
      'Emission/Reflection Nebula': TargetLight.mixed,
      'Reflection Nebula': TargetLight.broadband,
      'Dark Nebula': TargetLight.broadband,
      'Galaxy': TargetLight.broadband,
      'Galaxy Pair': TargetLight.broadband,
      'Open Cluster': TargetLight.broadband,
      'Globular Cluster': TargetLight.broadband,
      'Star': TargetLight.broadband,
    };
    for (final MapEntry(key: type, value: light) in cases.entries) {
      expect(targetLight(type), light, reason: type);
    }
    expect(targetLight(null), TargetLight.broadband);
  });
}

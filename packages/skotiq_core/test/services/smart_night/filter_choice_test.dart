import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

/// The owner's wheel (profile "10\" Newt", ZWO EFW, 8 slots).
const _ownerWheel = ['L', 'R', 'G', 'B', 'Ha', 'SII', 'OIII', 'DARK'];

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
  bool oneShotColor = false,
  int emissionRegions = 0,
}) => chooseSmartNightFilters(
  target: target,
  availableFilters: wheel,
  oneShotColor: oneShotColor,
  catalogedEmissionRegions: emissionRegions,
);

void main() {
  group('owner wheel on a mono camera', () {
    test('M1, a supernova remnant, is imaged SHO', () {
      final choice = _choose(_target('M1', DsoType.supernova.displayName));
      expect(choice.strategy, SmartNightStrategy.narrowbandSho);
      expect(choice.filters, ['Ha', 'OIII', 'SII']);
      expect(choice.reason, 'Narrowband SHO: M1 is a supernova remnant.');
    });

    test('NGC1952 by its catalog code is imaged SHO', () {
      final choice = _choose(_target('NGC1952', 'SNR'));
      expect(choice.filters, ['Ha', 'OIII', 'SII']);
      expect(choice.suggestion, isNull);
    });

    test('M31, a galaxy, is imaged LRGB with nothing offered', () {
      final choice = _choose(_target('M31', 'Galaxy'));
      expect(choice.strategy, SmartNightStrategy.autoLrgb);
      expect(choice.filters, ['L', 'R', 'G', 'B']);
      expect(choice.reason, 'LRGB: M31 is a galaxy.');
      expect(choice.suggestion, isNull);
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

    test('M42 and M8, by their catalog types, are narrowband', () {
      // OpenNGC types M42 "Cl+N" and M8 "Neb".
      for (final target in [
        _target('M42', DsoType.clusterWithNebulosity.displayName),
        _target('M8', DsoType.nebula.displayName),
      ]) {
        final choice = _choose(target);
        expect(choice.strategy, SmartNightStrategy.narrowbandSho);
        expect(choice.filters, ['Ha', 'OIII', 'SII']);
        expect(choice.suggestion, isNull);
      }
    });

    test(
      'a galaxy with catalogued emission regions is LRGB with Ha offered',
      () {
        final choice = _choose(_target('M33', 'Galaxy'), emissionRegions: 9);
        expect(choice.strategy, SmartNightStrategy.autoLrgb);
        expect(choice.filters, ['L', 'R', 'G', 'B']);
        expect(choice.suggested?.preset, SmartNightStrategy.haLrgb);
        expect(
          choice.suggestion,
          'M33 holds 9 emission regions in the catalog, and you have an Ha '
          'filter: add Ha to this plan or a later night.',
        );
        // Taking the offer is the user's choice, and the plan no longer
        // repeats it.
        final offered = choice.suggested!;
        expect(offered.filters, ['L', 'R', 'G', 'B', 'Ha']);
        expect(choice.reasonFor(offered), 'LRGB + Ha: your choice.');
        expect(choice.suggestionFor(offered), isNull);
        expect(choice.suggestionFor(choice.recommended), choice.suggestion);
      },
    );

    test('without an Ha filter nothing is said about Ha', () {
      final choice = _choose(
        _target('M33', 'Galaxy'),
        wheel: const ['L', 'R', 'G', 'B', 'OIII', 'DARK'],
        emissionRegions: 9,
      );
      expect(choice.strategy, SmartNightStrategy.autoLrgb);
      expect(choice.suggested, isNull);
      expect(choice.suggestion, isNull);
    });

    test('a reflection nebula and a cluster are LRGB', () {
      expect(_choose(_target('M45', 'Reflection Nebula')).filters, [
        'L',
        'R',
        'G',
        'B',
      ]);
      expect(_choose(_target('M78', 'Reflection Nebula')).filters, [
        'L',
        'R',
        'G',
        'B',
      ]);
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

  group('the Filters picker', () {
    final m1 = _choose(_target('M1', DsoType.supernova.displayName));

    test('lists every set the owner wheel can image, SHO recommended', () {
      expect(m1.sets().map((set) => set.label), [
        'LRGB',
        'RGB',
        'L',
        'LRGB + Ha',
        'SHO',
        'HOO',
        'Ha',
        'OIII',
        'SII',
      ]);
      expect(m1.recommended.label, 'SHO');
      expect(
        m1.recommendation,
        'Recommended: narrowband SHO, M1 is a supernova remnant.',
      );
      expect(
        _choose(_target('M31', 'Galaxy')).recommendation,
        'Recommended: LRGB, M31 is a galaxy.',
      );
      expect(m1.recommended.filters, ['Ha', 'OIII', 'SII']);
      expect(m1.sets().every((set) => !set.filters.contains('DARK')), isTrue);
    });

    test('lists only sets whose every filter is on the wheel', () {
      final narrowbandOnly = _choose(
        _target('M1', DsoType.supernova.displayName),
        wheel: const ['Ha', 'OIII'],
      );
      expect(narrowbandOnly.sets().map((set) => set.label), [
        'HOO',
        'Ha',
        'OIII',
      ]);
      final colorOnly = _choose(
        _target('M31', 'Galaxy'),
        wheel: const ['R', 'G', 'B'],
      );
      expect(colorOnly.recommended.label, 'RGB');
      expect(colorOnly.reason, 'RGB: M31 is a galaxy.');
      expect(colorOnly.sets().map((set) => set.label), ['RGB']);
    });

    test('a set the user picks says it was their choice', () {
      final lrgb = m1.sets().firstWhere((set) => set.label == 'LRGB');
      expect(lrgb.filters, ['L', 'R', 'G', 'B']);
      expect(m1.reasonFor(lrgb), 'LRGB: your choice.');
      expect(m1.reasonFor(m1.recommended), m1.reason);
    });

    test('a color camera picks one filter on its wheel, or none', () {
      final color = _choose(
        _target('M1', DsoType.supernova.displayName),
        wheel: const ['UV/IR Cut', 'L-eXtreme'],
        oneShotColor: true,
      );
      expect(color.sets().map((set) => set.label), [
        'UV/IR Cut',
        'L-eXtreme, dual-band',
      ]);
      expect(color.recommended.label, 'L-eXtreme, dual-band');
      final noWheel = _choose(
        _target('M1', DsoType.supernova.displayName),
        wheel: const [],
        oneShotColor: true,
      );
      expect(noWheel.sets().map((set) => set.label), ['No filter']);
      expect(noWheel.recommended.filters, [smartNightUnfilteredName]);
    });

    test('a saved set is listed when every filter is on the wheel', () {
      const saved = [
        CustomFilterSet(name: 'HaRGB', filters: ['Ha', 'R', 'G', 'B']),
        CustomFilterSet(name: 'Nitrogen', filters: ['NII']),
      ];
      final wheel = _choose(
        _target('M1', DsoType.supernova.displayName),
        wheel: const ['L', 'R', 'G', 'B', 'Baader Ha 7nm'],
      );
      final sets = wheel.sets(saved: saved);
      final haRgb = sets.singleWhere((set) => set.isCustom);
      expect(haRgb.label, 'HaRGB');
      expect(haRgb.filters, ['Baader Ha 7nm', 'R', 'G', 'B']);
      expect(haRgb.evenShares, isTrue);
      expect(wheel.reasonFor(haRgb), 'HaRGB: your choice.');
      expect(sets.map((set) => set.label), isNot(contains('Nitrogen')));
    });

    test('every set splits its time evenly until the user weights it', () {
      final lrgb = m1.sets().firstWhere((set) => set.label == 'LRGB');
      expect(lrgb.shares, {'L': 1.0, 'R': 1.0, 'G': 1.0, 'B': 1.0});
      expect(lrgb.evenShares, isTrue);
      final weighted = lrgb.withShares(const {'L': 2, 'B': -1});
      expect(weighted.shares, {'L': 2.0, 'R': 1.0, 'G': 1.0, 'B': 1.0});
      expect(weighted.evenShares, isFalse);
      expect(weighted.key, lrgb.key);
      expect(weighted == lrgb, isFalse);
    });

    test('a saved set keeps its shares on the wheel\'s slots', () {
      const saved = CustomFilterSet(
        name: 'HaRGB',
        filters: ['Ha', 'R', 'G', 'B'],
        shares: {'Ha': 3},
      );
      final set = saved.resolve(const ['R', 'G', 'B', 'Baader Ha 7nm'])!;
      expect(set.shares, {'Baader Ha 7nm': 3.0, 'R': 1.0, 'G': 1.0, 'B': 1.0});
      final back = CustomFilterSet.fromJson(saved.toJson());
      expect(back.shares, {'Ha': 3.0});
    });

    test('a wheel naming no band lists its one-filter choice', () {
      final odd = _choose(
        _target('M1', DsoType.supernova.displayName),
        wheel: const ['Slot 1', 'Slot 2'],
      );
      expect(odd.sets().map((set) => set.label), ['Slot 1']);
    });
  });

  group('the sets kept per profile', () {
    final m1 = _target('M1', DsoType.supernova.displayName);
    final choice = _choose(m1);
    FilterSet named(String label) =>
        choice.sets().firstWhere((set) => set.label == label);

    test('a picked set is remembered for its target until the user picks '
        'the recommendation again', () {
      var prefs = const FilterSetPreferences();
      prefs = prefs.choose(m1, named('LRGB'), recommended: choice.recommended);
      expect(
        prefs
            .setFor(m1, sets: choice.sets(), recommended: choice.recommended)
            .label,
        'LRGB',
      );
      expect(
        prefs
            .setFor(
              _target('M31', 'Galaxy'),
              sets: choice.sets(),
              recommended: choice.recommended,
            )
            .label,
        'SHO',
      );
      prefs = prefs.choose(
        m1,
        choice.recommended,
        recommended: choice.recommended,
      );
      expect(prefs.targetChoices, isEmpty);
    });

    test('a remembered set the wheel can no longer image falls back', () {
      final prefs = const FilterSetPreferences().choose(
        m1,
        named('LRGB'),
        recommended: choice.recommended,
      );
      final narrowband = _choose(m1, wheel: const ['Ha', 'OIII', 'SII']);
      expect(
        prefs
            .setFor(
              m1,
              sets: narrowband.sets(),
              recommended: narrowband.recommended,
            )
            .label,
        'SHO',
      );
    });

    test('saving replaces a set of the same name; deleting forgets the '
        'targets that used it', () {
      var prefs = const FilterSetPreferences()
          .save(const CustomFilterSet(name: 'Mine', filters: ['Ha', 'R']))
          .save(const CustomFilterSet(name: 'Mine', filters: ['Ha', 'G']));
      expect(prefs.custom.single.filters, ['Ha', 'G']);
      final mine = choice
          .sets(saved: prefs.custom)
          .singleWhere((set) => set.isCustom);
      prefs = prefs.choose(m1, mine, recommended: choice.recommended);
      expect(prefs.targetChoices, {'M1': 'custom:Mine'});
      prefs = prefs.delete('Mine');
      expect(prefs.custom, isEmpty);
      expect(prefs.targetChoices, isEmpty);
    });

    test('round-trips through JSON', () {
      final prefs = const FilterSetPreferences()
          .save(const CustomFilterSet(name: 'Mine', filters: ['Ha', 'R']))
          .choose(m1, named('HOO'), recommended: choice.recommended);
      final back = FilterSetPreferences.fromJson(prefs.toJson());
      expect(back.custom.single.name, 'Mine');
      expect(back.custom.single.filters, ['Ha', 'R']);
      expect(back.targetChoices, {'M1': 'narrowbandHoo'});
    });
  });

  test('object types read as emission or broadband', () {
    const cases = {
      'Supernova Remnant': TargetLight.emission,
      'SNR': TargetLight.emission,
      'Emission Nebula': TargetLight.emission,
      'HII Region': TargetLight.emission,
      'Planetary Nebula': TargetLight.emission,
      'PN': TargetLight.emission,
      'Cluster + Nebula': TargetLight.emission,
      'Cl+N': TargetLight.emission,
      'Nebula': TargetLight.emission,
      'Emission/Reflection Nebula': TargetLight.emission,
      'Reflection Nebula': TargetLight.broadband,
      'RNe': TargetLight.broadband,
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

  test(
    'the filter rule names no object: the class comes from catalog data',
    () {
      final source = File(
        'lib/src/services/smart_night_models/filter_choice.dart',
      ).readAsStringSync();
      final designation = RegExp(
        r'\b(M|NGC|IC|C|Sh2-|LBN|RCW|vdB|Ced|Abell)\s?\d+',
      );
      expect(designation.allMatches(source).map((m) => m.group(0)), isEmpty);
    },
  );
}

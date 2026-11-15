// A plan that calls a filter "Lum" on a wheel that calls it "L" moves the
// wheel to L at run time (the native matcher folds the names), but files the
// frames as "Lum" and fails the pre-flight's name check. Matching renames the
// plan's filters to the wheel's own names.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

Sequence _plan(List<SequenceNode> steps) {
  final root = InstructionSetNode(name: 'Root');
  return Sequence.create(
    name: 'LRGB',
    rootNodeId: root.id,
    nodes: {
      root.id: root.copyWith(childIds: [for (final s in steps) s.id]),
      for (final s in steps) s.id: s.copyWith(parentId: root.id),
    },
  );
}

void main() {
  Map<String, dynamic> fixture() =>
      jsonDecode(
            File('test/fixtures/filter_matching_cases.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  // The native rule (`device/src/filter_name.rs`) is tested against the same
  // file.
  test('a filter name stands for the bands it names', () {
    final cases = (fixture()['bands'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    for (final c in cases) {
      final name = c['name'] as String;
      expect(
        filterBands(name).toList()..sort(),
        (c['bands'] as List).cast<String>(),
        reason: '"$name"',
      );
    }
  });

  test('the matcher gives the slot the native wheel gives', () {
    final cases = (fixture()['slots'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    for (final c in cases) {
      final names = (c['names'] as List).cast<String>();
      final requested = c['requested'] as String;
      final reason = '"$requested" in $names';
      expect(matchingFilterIndex(requested, names), c['index'], reason: reason);
      expect(
        isAmbiguousFilter(requested, names),
        c['ambiguous'] ?? false,
        reason: reason,
      );
    }
  });

  test('records are the same filter only when they name the same bands', () {
    expect(sameFilter('Ha', 'Ha 7nm'), isTrue);
    expect(sameFilter('Lum', 'L'), isTrue);
    expect(sameFilter('', '  '), isTrue);
    expect(sameFilter('R', 'UV/IR Cut'), isFalse);
    expect(sameFilter('L', 'L-Pro'), isFalse);
    expect(sameFilter('Ha', 'Ha/OIII'), isFalse);
    expect(sameFilter('', 'L'), isFalse);
  });

  test('a snippet filter lands on the profile slot the run would use', () {
    expect(matchingFilterIndex('Luminance', ['Lum', 'R']), 0);
    expect(matchingFilterIndex('Ha', ['L', 'Ha 7nm']), 1);
    expect(matchingFilterIndex('Nitrogen', ['L', 'NII']), 1);
    expect(matchingFilterIndex('Nitrogen', ['L', 'Ha']), isNull);
  });

  test('a renamed filter drops the wheel slot of its old name', () {
    // Built on a wheel with Lum in slot 0; this wheel has L in slot 3.
    final change = FilterChangeNode(filterName: 'Lum', filterPosition: 0);
    final lights = ExposureNode(filter: 'Lum', filterIndex: 0);
    final red = ExposureNode(filter: 'R', filterIndex: 0);
    final smart = SmartExposureNode(
      plans: const [
        FilterPlan(
          filterName: 'Lum',
          filterIndex: 0,
          count: 1,
          durationSecs: 1,
        ),
        FilterPlan(filterName: 'R', filterIndex: 0, count: 1, durationSecs: 1),
      ],
    );
    final plan = _plan([change, lights, red, smart]);

    final matched = renameFilters(plan, const {'Lum': 'L'});

    final changed = matched.nodes[change.id]! as FilterChangeNode;
    expect((changed.filterName, changed.filterPosition), ('L', null));
    final renamedLights = matched.nodes[lights.id]! as ExposureNode;
    expect((renamedLights.filter, renamedLights.filterIndex), ('L', null));
    expect((matched.nodes[red.id]! as ExposureNode).filterIndex, 0);
    final plans = (matched.nodes[smart.id]! as SmartExposureNode).plans;
    expect((plans[0].filterName, plans[0].filterIndex), ('L', null));
    expect((plans[1].filterName, plans[1].filterIndex), ('R', 0));
  });

  test('every step that names a filter is renamed to the wheel name', () {
    final change = FilterChangeNode(name: 'Lum first', filterName: 'Lum');
    final center = CenterNode(filter: 'Lum');
    final lights = ExposureNode(filter: 'Lum', count: 40, durationSecs: 120);
    final smart = SmartExposureNode(
      plans: const [
        FilterPlan(filterName: 'Lum', count: 10, durationSecs: 60),
        FilterPlan(filterName: 'Red', count: 10, durationSecs: 60),
      ],
    );
    final untouched = ExposureNode(filter: 'UV', count: 5, durationSecs: 30);
    final plan = _plan([change, center, lights, smart, untouched]);
    const wheel = ['L', 'R', 'G', 'B'];

    final renames = filterRenamesFor(plan, wheel);
    expect(renames, {'Lum': 'L', 'Red': 'R'});

    final matched = renameFilters(plan, renames);
    expect((matched.nodes[change.id]! as FilterChangeNode).filterName, 'L');
    expect(matched.nodes[change.id]!.name, 'Lum first');
    expect((matched.nodes[center.id]! as CenterNode).filter, 'L');
    expect((matched.nodes[lights.id]! as ExposureNode).filter, 'L');
    expect(
      [
        for (final p in (matched.nodes[smart.id]! as SmartExposureNode).plans)
          p.filterName,
      ],
      ['L', 'R'],
    );
    expect((matched.nodes[untouched.id]! as ExposureNode).filter, 'UV');
    expect(filterRenamesFor(matched, wheel), isEmpty);
  });
}

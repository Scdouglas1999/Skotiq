// A plan that calls a filter "Lum" on a wheel that calls it "L" moves the
// wheel to L at run time (the native matcher folds the names), but files the
// frames as "Lum" and fails the pre-flight's name check. Matching renames the
// plan's filters to the wheel's own names.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

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
  test('long and short filter names fold together as the wheel matches them',
      () {
    expect(canonicalFilterName('Luminance'), 'L');
    expect(canonicalFilterName('lum'), 'L');
    expect(canonicalFilterName('H-alpha'), 'HA');
    expect(canonicalFilterName('Red'), 'R');
    expect(canonicalFilterName('OIII'), 'OIII');
  });

  test('a filter matches the wheel name it means, exact names first', () {
    const wheel = ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'];
    expect(matchingFilterName('Lum', wheel), 'L');
    expect(matchingFilterName('h-alpha', wheel), 'Ha');
    expect(matchingFilterName('r', wheel), 'R');
    expect(matchingFilterName('Clear', ['Clear', 'L']), 'Clear');
    expect(matchingFilterName('UV', wheel), isNull);
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

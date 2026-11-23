import 'dart:convert';
import 'dart:io';

import 'package:skotiq_astro/filters.dart';
import 'package:test/test.dart';

void main() {
  Map<String, dynamic> fixture() =>
      jsonDecode(
            File('test/fixtures/filter_matching_cases.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  // The native rule (`frame/src/filter_name.rs`) is tested against the same
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

  test('filters sort by band, every spelling with its band', () {
    final names = ['SII', 'Custom', 'H-alpha', 'b', 'Lum', 'OIII', 'Red', 'G']
      ..sort(compareFilterNames);
    expect(names, ['Lum', 'Red', 'G', 'b', 'H-alpha', 'OIII', 'SII', 'Custom']);
    expect(filterRank('Baader Ha 7nm'), filterRank('Ha'));
    expect(filterRank('L-eXtreme'), filterRank('Custom'));
    expect((['beta', 'Alpha']..sort(compareFilterNames)), ['Alpha', 'beta']);
  });
}

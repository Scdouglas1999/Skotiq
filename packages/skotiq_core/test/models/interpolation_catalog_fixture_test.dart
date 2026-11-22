// The app's variable catalog is the sequencer's: test_fixtures/interpolation_catalog/catalog.json
// is written from `variable_catalog` (sequencer/src/expressions/catalog.rs) by
// `the_catalog_fixture_matches_the_catalog`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

const _fixturePath = '../../test_fixtures/interpolation_catalog/catalog.json';

void main() {
  test('the app offers every variable as the sequencer resolves it', () {
    final fixture =
        jsonDecode(File(_fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    final native = [
      for (final entry
          in (fixture['variables'] as List).cast<Map<String, dynamic>>())
        {
          'name': entry['name'],
          'description': entry['description'],
          'group': entry['group'],
          'example': entry['example'],
          'supportsFormat': entry['supportsFormat'],
        },
    ];
    final app = [
      for (final entry in interpolationCatalog)
        {
          'name': entry.name,
          'description': entry.description,
          'group': entry.group.name,
          'example': entry.example,
          'supportsFormat': entry.supportsFormat,
        },
    ];
    expect(app, native);
  });
}

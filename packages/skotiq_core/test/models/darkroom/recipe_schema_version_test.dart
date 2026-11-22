// The recipe envelope's schema version is the engine's: the shared catalogue
// fixture test_fixtures/darkroom_ops/catalog.json carries
// RECIPE_SCHEMA_VERSION (processing/src/darkroom/catalog_fixture_tests.rs).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/darkroom/recipe.dart';

void main() {
  test('the envelope writes the schema version the engine reads', () {
    final catalog =
        jsonDecode(
              File(
                '../../test_fixtures/darkroom_ops/catalog.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(recipeSchemaVersion, catalog['recipeSchemaVersion']);
  });
}

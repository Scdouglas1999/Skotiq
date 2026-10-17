// Regenerates the committed stress-scene fixture from the seeded generator.
//
// Run from the package root:
//   dart run benchmark/tools/generate_fixture.dart
//
// Writes benchmark/fixtures/stress_scene.json. The output is deterministic
// (fixed seed, no clock, no network) so re-running produces byte-identical JSON
// unless you intentionally change the generator. Commit the regenerated file and
// refresh the goldens (see benchmark/README.md) when you do.

import 'dart:convert';
import 'dart:io';

import '../src/fixture_generator.dart';
import '../src/stress_fixture.dart';

void main() {
  final fixture = generateStressFixture();
  final json = fixture.toJson();

  const encoder = JsonEncoder.withIndent('  ');
  final out = File(StressFixture.defaultPath());
  out.parent.createSync(recursive: true);
  out.writeAsStringSync('${encoder.convert(json)}\n');

  stdout.writeln('Wrote ${out.path}');
  stdout.writeln(
    '  stars=${fixture.stars.length} '
    'dsos=${fixture.dsos.length} '
    'constellations=${fixture.constellations.length} '
    'milkyWay=${fixture.milkyWayPoints.length} '
    'planets=${fixture.planets.length}',
  );
  stdout.writeln('  size=${out.lengthSync()} bytes');
}

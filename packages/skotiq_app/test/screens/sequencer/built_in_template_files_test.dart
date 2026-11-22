// The built-in templates are bundled sequence files. They load in catalog
// order, dated by their age, and every file reads back to exactly what it
// says: nothing the parser fills in or drops.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

const _dir = '../skotiq_core/assets/sample_sequences/templates';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the catalog loads every template in order', () async {
    final now = DateTime.utc(2026, 11, 21, 12);
    final templates = await const BuiltInTemplateService().load(now: now);
    expect(templates.map((t) => t.name), [
      'First Light',
      'One-Shot Color (OSC)',
      'Quick Capture',
      'DSO Beginner',
      'Basic LRGB Sequence',
      'Narrowband (SHO)',
      'Mosaic Panel',
      'Ha-OIII Bicolor',
      'SHO Hubble Palette',
      'LRGB + Ha Enhanced',
      'Multi-Target Night',
      'Planetary Capture',
      'Unattended All-Night',
      'Comet/Asteroid Tracking',
      'Solar Ha',
      'Lunar Surface',
      'Remote Observatory',
    ]);
    for (final (i, t) in templates.indexed) {
      final entry = BuiltInTemplateService.catalog[i];
      expect(t.id, entry.id);
      expect(t.isTemplate, isTrue);
      expect(t.databaseId, isNull);
      expect(t.createdAt, now.subtract(Duration(days: entry.ageDays)));
      expect(t.nodes, contains(t.rootNodeId));
    }
  });

  test('every template file reads back unchanged', () {
    final parser = SequenceFileService();
    final files = Directory(_dir).listSync().whereType<File>().toList();
    expect(files, hasLength(BuiltInTemplateService.catalog.length));
    for (final file in files) {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final again = parser.sequenceToMap(parser.parseFromMap(json))
        ..remove('createdAt')
        ..remove('modifiedAt');
      expect(jsonEncode(again), jsonEncode(json), reason: file.path);
    }
  });
}

// The bundled template files must read back as the hand-built template trees
// they were written from: same ids, order, names, nodes and every node field.
//
// Write the files (only to regenerate them from the trees):
//   WRITE_TEMPLATE_FILES=1 flutter test test/screens/sequencer/built_in_template_files_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/tabs/templates_tab.dart';
import 'package:skotiq_core/services.dart';

const _dir = '../skotiq_core/assets/sample_sequences/templates';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final parser = SequenceFileService();

  if (Platform.environment['WRITE_TEMPLATE_FILES'] == '1') {
    test('write the template files', () {
      for (final template in handBuiltTemplates()) {
        final map = parser.sequenceToMap(template)
          ..remove('createdAt')
          ..remove('modifiedAt');
        final name = template.id.replaceFirst('template-', '');
        File('$_dir/$name.json').writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(map)}\n',
        );
      }
    });
    return;
  }

  test('the template files read back as the hand-built trees', () {
    final now = DateTime.now();
    final built = handBuiltTemplates();
    expect(
      BuiltInTemplateService.catalog.map((e) => e.id),
      built.map((t) => t.id),
    );
    for (final (i, entry) in BuiltInTemplateService.catalog.indexed) {
      final expected = built[i];
      final file = File(
        BuiltInTemplateService.assetPathFor(entry.id)
            .replaceFirst(BuiltInTemplateService.assetDirectory, _dir),
      );
      final loaded = BuiltInTemplateService.templateFromMap(
        entry,
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
        parser: parser,
        now: now,
      );
      expect(loaded.id, expected.id);
      expect(loaded.name, expected.name);
      expect(loaded.description, expected.description);
      expect(loaded.isTemplate, expected.isTemplate);
      expect(loaded.rootNodeId, expected.rootNodeId);
      expect(loaded.databaseId, isNull);
      expect(loaded.nodes.keys.toList(), expected.nodes.keys.toList());
      for (final id in expected.nodes.keys) {
        expect(loaded.nodes[id]!.runtimeType, expected.nodes[id]!.runtimeType);
        expect(loaded.nodes[id]!.props, expected.nodes[id]!.props,
            reason: '${expected.id} node $id');
      }
      expect(
        loaded.createdAt.difference(expected.createdAt).inMinutes.abs(),
        0,
      );
      expect(loaded.modifiedAt, loaded.createdAt);
    }
  });
}

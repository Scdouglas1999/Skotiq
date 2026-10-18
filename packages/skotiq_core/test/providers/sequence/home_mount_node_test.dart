// The "Home mount" sequence node: what goes on the wire to the Rust engine,
// how it survives the two persistence codecs, and where the editor offers it.
//
// `HomeMount` is the Rust serde tag (`NodeType::HomeMount`). A typo on either
// side turns every saved home step into an unknown node the engine refuses.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:skotiq_core/skotiq_core.dart';

class _FixedFileSelector extends FileSelectorPlatform {
  _FixedFileSelector(this.filePath);

  final String filePath;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => XFile(filePath);

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async => FileSaveLocation(filePath);
}

Sequence _sequenceWithHome() {
  return Sequence.create(
    id: 'seq-home',
    name: 'Home only',
    rootNodeId: 'set',
    nodes: {
      'set': InstructionSetNode(id: 'set', childIds: const ['home']),
      'home': HomeMountNode(
        id: 'home',
        parentId: 'set',
        comment: 'Re-zero the encoders',
      ),
    },
  );
}

Future<(ProviderContainer, SkotiqDatabase)> _container() async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(db)],
  );
  return (container, db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a new node is named "Home mount" and needs only the mount', () {
    final node = HomeMountNode();
    expect(node.nodeType, 'HomeMount');
    expect(node.name, 'Home mount');
    expect(node.requiredDevices, {DeviceType.mount});
    expect(node.copyWith(), equals(node));
  });

  test('the engine payload tags the node HomeMount', () async {
    final (container, db) = await _container();
    addTearDown(() async {
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await db.close();
    });
    final serializer = Provider(
      (ref) => SequenceSerializer(ref: ref, warn: (_) {}),
    );

    final wire =
        jsonDecode(
              container.read(serializer).sequenceToJson(_sequenceWithHome()),
            )
            as Map<String, dynamic>;
    final nodes = (wire['nodes'] as List).cast<Map<String, dynamic>>();
    final home = nodes.singleWhere((n) => n['id'] == 'home');

    expect(home['node_type'], {'type': 'HomeMount'});
    expect(home['name'], 'Home mount');
  });

  test('the node survives a database save and load', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = SequenceRepository(SequencesDao(db));

    final id = await repository.saveSequence(_sequenceWithHome());
    final loaded = await repository.loadSequence(id);

    final home = loaded!.nodes['home'];
    expect(home, isA<HomeMountNode>());
    expect(home!.name, 'Home mount');
    expect(home.comment, 'Re-zero the encoders');
  });

  test('a commented side-effect-only step can be saved', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = SequenceRepository(SequencesDao(db));

    final id = await repository.saveSequence(
      Sequence.create(
        id: 'seq-park',
        name: 'Park only',
        rootNodeId: 'park',
        nodes: {'park': ParkNode(id: 'park', comment: 'End of night')},
      ),
    );
    final loaded = await repository.loadSequence(id);

    expect(loaded!.nodes['park']!.comment, 'End of night');
  });

  test('the node survives a sequence file export and import', () async {
    final tempDir = await Directory.systemTemp.createTemp('home_mount_node_');
    addTearDown(() async => tempDir.delete(recursive: true));
    final original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = _FixedFileSelector(
      path.join(tempDir.path, 'home.skeq.json'),
    );
    addTearDown(() => FileSelectorPlatform.instance = original);

    final service = SequenceFileService();
    await service.exportSequence(_sequenceWithHome());
    final imported = await service.importSequence();

    expect(imported!.nodes['home'], isA<HomeMountNode>());
    expect(imported.nodes['home']!.parentId, 'set');
  });

  test('the Mount palette offers Home mount right after Unpark', () async {
    final (container, db) = await _container();
    addTearDown(() async {
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await db.close();
    });

    final mount = container
        .read(nodePaletteProvider)
        .singleWhere((c) => c.name == 'Mount');
    final names = mount.items.map((i) => i.name).toList();
    final home = mount.items.singleWhere((i) => i.name == 'Home mount');

    expect(home.createNode(), isA<HomeMountNode>());
    expect(names.indexOf('Home mount'), names.indexOf('Unpark mount') + 1);
    // Let the palette's async defaults load settle before disposal.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
}

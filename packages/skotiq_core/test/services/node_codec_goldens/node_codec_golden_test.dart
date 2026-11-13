// Pins the bytes every sequence-node codec writes and the nodes every decoder
// rebuilds, for every node type: saved sequences in users' databases and files,
// the Rust executor's serde types, the headless API and linked clients all
// read these shapes, so none of them may move.
//
// Regenerate (only when a wire change is intended):
//   UPDATE_NODE_GOLDENS=1 flutter test test/services/node_codec_goldens

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

import 'node_fixtures.dart';

const _goldenDir = 'test/services/node_codec_goldens/goldens';
final bool _update = Platform.environment['UPDATE_NODE_GOLDENS'] == '1';

void _expectGolden(String name, Object? actual) {
  final file = File('$_goldenDir/$name.json');
  final text = '${const JsonEncoder.withIndent('  ').convert(plain(actual))}\n';
  if (_update) {
    file.createSync(recursive: true);
    file.writeAsStringSync(text);
    return;
  }
  expect(
    file.existsSync(),
    isTrue,
    reason: '${file.path} is missing; run with UPDATE_NODE_GOLDENS=1',
  );
  final expected = file.readAsStringSync();
  if (text != expected) {
    final actual = File('${Directory.systemTemp.path}/node_goldens_actual/$name.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    fail('${file.path} differs; the new output is in ${actual.path}');
  }
}

Map<String, Object?> _dumpById(Iterable<SequenceNode> nodes) {
  final sorted = nodes.toList()..sort((a, b) => a.id.compareTo(b.id));
  return {for (final n in sorted) n.id: dumpNode(n)};
}

Object? _attempt(Object? Function() body) {
  try {
    return body();
  } on Object catch (e) {
    return 'error ${e.runtimeType}: $e';
  }
}

/// Every spelling the DB reader accepts in `sequence_nodes.specific_type`.
const _dbSpellings = [
  'exposure', 'TakeExposure', 'slew', 'SlewToTarget', 'center', //
  'CenterTarget', 'autofocus', 'Autofocus', 'dither', 'Dither',
  'filterChange', 'ChangeFilter', 'coolCamera', 'CoolCamera', 'warmCamera',
  'WarmCamera', 'rotator', 'MoveRotator', 'park', 'Park', 'unpark', 'Unpark',
  'homemount', 'HomeMount', 'waitTime', 'WaitForTime', 'delay', 'Delay',
  'notification', 'Notification', 'script', 'RunScript', 'targetGroup',
  'TargetHeader', 'loop', 'Loop', 'parallel', 'Parallel', 'conditional',
  'Conditional', 'recovery', 'Recovery', 'startGuiding', 'StartGuiding',
  'stopGuiding', 'StopGuiding', 'meridianFlip', 'MeridianFlip', 'openDome',
  'OpenDome', 'closeDome', 'CloseDome', 'parkDome', 'ParkDome',
  'polarAlignment', 'PolarAlignment', 'instructionSet', 'InstructionSet',
  'targetScheduler', 'TargetScheduler', 'target_scheduler', 'smartExposure',
  'SmartExposure', 'smart_exposure', 'pluginNode', 'PluginNode', 'plugin_node',
  'liveStacking', 'LiveStacking', 'live_stacking', 'openCover', 'OpenCover',
  'open_cover', 'closeCover', 'CloseCover', 'close_cover', 'calibratorOn',
  'CalibratorOn', 'calibrator_on', 'calibratorOff', 'CalibratorOff',
  'calibrator_off', 'sciencePhotometry', 'SciencePhotometry',
  'science_photometry',
  // Not accepted today; pinned so the answer stays "unsupported".
  'takeexposure', 'Mosaic', 'FlatWizard',
];

/// Every spelling the file and snippet readers accept in `nodeType`, plus
/// the forms they normalize (case, separators) and a few they reject.
const _fileSpellings = [
  'TargetHeader', 'targetheader', 'targetgroup', 'TargetGroup', 'Loop', //
  'Parallel', 'Conditional', 'Recovery', 'InstructionSet', 'instruction_set',
  'SlewToTarget', 'slew', 'CenterTarget', 'center', 'TakeExposure',
  'exposure', 'take-exposure', 'SmartExposure', 'smart_exposure',
  'smartexposurenode', 'Autofocus', 'Dither', 'StartGuiding', 'StopGuiding',
  'ChangeFilter', 'filterChange', 'CoolCamera', 'WarmCamera', 'MoveRotator',
  'rotator', 'Park', 'Unpark', 'HomeMount', 'home_mount', 'WaitForTime',
  'waitTime', 'Delay', 'Notification', 'RunScript', 'script', 'MeridianFlip',
  'OpenDome', 'CloseDome', 'ParkDome', 'PolarAlignment', 'polalignment',
  'TargetScheduler', 'target_scheduler', 'targetschedulernode', 'PluginNode',
  'plugin_node', 'LiveStacking', 'live_stacking', 'OpenCover', 'CloseCover',
  'CalibratorOn', 'calibrator_on', 'CalibratorOff', 'SciencePhotometry',
  'science_photometry', 'Mosaic', 'FlatWizard', 'NoSuchNode',
];

Future<(ProviderContainer, db.SkotiqDatabase)> _container() async {
  final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(database)],
  );
  await container.read(appSettingsProvider.future);
  addTearDown(() async {
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    await database.close();
  });
  return (container, database);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sets = {'full': fullNodes, 'defaults': defaultNodes};

  test('the fixtures cover every node type', () {
    final types = {for (final n in fullNodes()) n.runtimeType};
    expect(types, hasLength(fullNodes().length));
    expect(
      {for (final n in defaultNodes()) n.runtimeType},
      types,
      reason: 'full and default sets name the same node types',
    );
    expect(types, hasLength(38));
  });

  group('database codec', () {
    late db.SkotiqDatabase database;
    late SequenceRepository repository;

    setUp(() {
      database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
      repository = SequenceRepository(database.sequencesDao);
    });
    tearDown(() => database.close());

    Future<List<Map<String, Object?>>> rows(int sequenceId) async {
      final stored = await database.sequencesDao.getNodesForSequence(
        sequenceId,
      );
      stored.sort((a, b) => a.nodeId.compareTo(b.nodeId));
      return [
        for (final r in stored)
          {
            'nodeId': r.nodeId,
            'nodeType': r.nodeType,
            'specificType': r.specificType,
            'name': r.name,
            'parentNodeId': r.parentNodeId,
            'orderIndex': r.orderIndex,
            'isEnabled': r.isEnabled,
            'properties': jsonDecode(r.properties),
          },
      ];
    }

    for (final MapEntry(key: label, value: nodes) in sets.entries) {
      test('$label nodes: stored rows and the nodes read back', () async {
        final id = await repository.saveSequence(flatSequence(label, nodes()));
        _expectGolden('db_rows_$label', await rows(id));
        final loaded = await repository.loadSequence(id);
        _expectGolden('db_decoded_$label', _dumpById(loaded!.nodes.values));
      });
    }

    test('rows with no properties decode to the reader defaults', () async {
      final id = await repository.saveSequence(
        flatSequence('empty', fullNodes()),
      );
      await database
          .update(database.sequenceNodes)
          .write(const db.SequenceNodesCompanion(properties: Value('{}')));
      final loaded = await repository.loadSequence(id);
      _expectGolden('db_decoded_empty_properties', _dumpById(loaded!.nodes.values));
    });

    test('every accepted specific_type spelling', () async {
      final out = <String, Object?>{};
      for (final spelling in _dbSpellings) {
        final id = await repository.saveSequence(
          flatSequence('spelling', [DelayNode(id: 'probe')]),
        );
        await (database.update(database.sequenceNodes)
              ..where((t) => t.nodeId.equals('probe')))
            .write(db.SequenceNodesCompanion(specificType: Value(spelling)));
        final result = await () async {
          try {
            final loaded = await repository.loadSequence(id);
            return dumpNode(loaded!.nodes['probe']!);
          } on Object catch (e) {
            return 'error ${e.runtimeType}: $e';
          }
        }();
        out[spelling] = result;
      }
      _expectGolden('db_spellings', out);
    });
  });

  group('file codec', () {
    final files = SequenceFileService();

    for (final MapEntry(key: label, value: nodes) in sets.entries) {
      test('$label nodes: written maps and the nodes read back', () {
        final maps = {
          for (final n in nodes()) n.id: files.nodeToMap(n),
        };
        _expectGolden('file_nodes_$label', maps);
        _expectGolden('file_decoded_$label', {
          for (final MapEntry(:key, :value) in maps.entries)
            key: dumpNode(files.nodeFromMap(value)),
        });
      });
    }

    test('a whole sequence document', () {
      final map = files.sequenceToMap(flatSequence('doc', fullNodes()));
      _expectGolden('file_sequence_document', map);
      final parsed = files.parseFromMap(jsonDecode(jsonEncode(map)) as Map<String, dynamic>);
      _expectGolden('file_sequence_document_decoded', {
        'name': parsed.name,
        'description': parsed.description,
        'rootNodeId': parsed.rootNodeId,
        'nodes': _dumpById(parsed.nodes.values),
      });
    });

    test('a node with nothing but its type decodes to the reader defaults', () {
      _expectGolden('file_spellings', {
        for (final spelling in _fileSpellings)
          spelling: _attempt(
            () => dumpNode(
              files.nodeFromMap({'nodeType': spelling, 'id': 'probe'}),
            ),
          ),
      });
    });

    test('shipped sample sequences and the starter export', () {
      final out = <String, Object?>{};
      final paths = [
        ...Directory('assets/sample_sequences')
            .listSync()
            .whereType<File>()
            .map((f) => f.path)
            .where((p) => p.endsWith('.json')),
        'test/fixtures/m51_starter_export.skseq.json',
      ]..sort();
      for (final path in paths) {
        out[path] = _attempt(() {
          final seq = files.parseSequenceFile(File(path).readAsStringSync());
          return {
            'name': seq.name,
            'rootNodeId': seq.rootNodeId,
            'nodes': _dumpById(seq.nodes.values),
          };
        });
      }
      _expectGolden('file_shipped_documents', out);
    });
  });

  group('executor wire', () {
    for (final MapEntry(key: label, value: nodes) in sets.entries) {
      test('$label nodes as the native sequencer reads them', () async {
        final (container, _) = await _container();
        final warnings = <String>[];
        final serializer = Provider(
          (ref) => SequenceSerializer(ref: ref, warn: warnings.add),
        );
        final out = <String, Object?>{};
        for (final node in nodes()) {
          out[node.id] = _attempt(() {
            final json = container
                .read(serializer)
                .sequenceToJson(flatSequence('wire', [node]));
            final decoded = jsonDecode(json) as Map<String, dynamic>;
            final wireNodes = (decoded['nodes'] as List)
                .cast<Map<String, dynamic>>();
            return wireNodes.singleWhere((n) => n['id'] == node.id);
          });
        }
        _expectGolden('wire_nodes_$label', {...out, 'warnings': warnings});
      });
    }

    test('a whole sequence document', () async {
      final (container, _) = await _container();
      final serializer = Provider(
        (ref) => SequenceSerializer(ref: ref, warn: (_) {}),
      );
      final json = container
          .read(serializer)
          .sequenceToJson(flatSequence('wire-doc', fullNodes()));
      _expectGolden('wire_sequence_document', jsonDecode(json));
    });
  });

  group('snippet codec', () {
    for (final MapEntry(key: label, value: nodes) in sets.entries) {
      test('$label nodes saved as a snippet and inserted back', () {
        final sequence = flatSequence('snippet', nodes());
        final snippet = createSnippetFromSelection(
          name: 'All',
          description: 'every node',
          category: SnippetCategory.custom,
          iconName: 'puzzle',
          nodeIds: [for (final n in nodes()) n.id],
          sequence: sequence,
        );
        _expectGolden('snippet_node_data_$label', snippet.nodeData);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final editor = container.read(currentSequenceProvider.notifier)
          ..createSequence();
        final rootId = container.read(currentSequenceProvider)!.rootNodeId!;
        editor.insertSnippet(snippet, parentId: rootId);
        final inserted = container.read(currentSequenceProvider)!;
        final root = inserted.nodes[rootId]!;
        _expectGolden('snippet_inserted_$label', [
          for (final id in root.childIds) _withoutIdentity(inserted.nodes[id]!),
        ]);
      });
    }

    test('legacy snippet entries with nothing but a type', () {
      final out = <String, Object?>{};
      for (final spelling in _fileSpellings) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final editor = container.read(currentSequenceProvider.notifier)
          ..createSequence();
        final rootId = container.read(currentSequenceProvider)!.rootNodeId!;
        out[spelling] = _attempt(() {
          editor.insertSnippet(
            TemplateSnippet(
              id: 'probe',
              name: 'Probe',
              description: '',
              category: SnippetCategory.custom,
              iconName: 'puzzle',
              nodeData: [
                {'nodeType': spelling},
              ],
              createdAt: DateTime.utc(2026),
            ),
            parentId: rootId,
          );
          final seq = container.read(currentSequenceProvider)!;
          final children = seq.nodes[rootId]!.childIds;
          return children.isEmpty
              ? 'nothing inserted'
              : _withoutIdentity(seq.nodes[children.last]!);
        });
      }
      _expectGolden('snippet_spellings', out);
    });
  });

  group('diff and describe', () {
    const diffService = SequenceDiffService();

    test('every field change from defaults to fully set', () {
      final result = diffService.diff(
        previous: flatSequence('a', defaultNodes()),
        current: flatSequence('b', fullNodes()),
      );
      _expectGolden('diff_modified', [
        for (final entry in result.modified)
          {
            'nodeId': entry.nodeId,
            'nodeKind': entry.nodeKind,
            'label': entry.label,
            'changes': [
              for (final c in entry.changes)
                {
                  'field': c.field,
                  'old': plain(c.oldValue),
                  'new': plain(c.newValue),
                  'describe': c.describe(),
                },
            ],
          },
      ]);
    });

    for (final MapEntry(key: label, value: nodes) in sets.entries) {
      test('how $label nodes are described when added', () {
        final result = diffService.diff(
          previous: flatSequence('empty', const []),
          current: flatSequence('added', nodes()),
        );
        _expectGolden('describe_$label', {
          for (final entry in result.added) entry.nodeId: entry.label,
        });
      });
    }
  });

  group('time estimate', () {
    const estimator = SequenceTimeEstimator();
    final at = DateTime.utc(2026, 3, 14, 21);

    for (final MapEntry(key: label, value: nodes) in sets.entries) {
      test('$label node durations', () {
        _expectGolden('durations_$label', {
          for (final n in nodes())
            n.id: _attempt(() => estimator.nodeDuration(n, at: at).inMilliseconds),
        });
      });
    }
  });
}

Map<String, Object?> _withoutIdentity(SequenceNode node) {
  final dump = dumpNode(node);
  final props = [...(dump['props']! as List)];
  props[0] = '<id>';
  props[3] = '<childIds>';
  props[4] = '<parentId>';
  return {...dump, 'props': props};
}

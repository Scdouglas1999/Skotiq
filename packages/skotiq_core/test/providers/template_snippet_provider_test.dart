import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('skotiq-snippets-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('failed remove and update restore the last persisted state', () async {
    var storage = File('${tempDir.path}/custom_snippets.json');
    final notifier = CustomSnippetsNotifier(snippetsFile: () async => storage);
    addTearDown(notifier.dispose);
    await notifier.loadFromDisk();

    final original = _snippet('one', 'Original');
    await notifier.addSnippet(original);
    expect(notifier.state, [original]);

    final blocker = File('${tempDir.path}/not-a-directory');
    await blocker.writeAsString('block writes beneath this path');
    storage = File('${blocker.path}/custom_snippets.json');

    await expectLater(
      notifier.removeSnippet(original.id),
      throwsA(isA<Exception>()),
    );
    expect(notifier.state, [original]);

    await expectLater(
      notifier.updateSnippet(original.copyWith(name: 'Changed')),
      throwsA(isA<Exception>()),
    );
    expect(notifier.state, [original]);
  });

  test('overlapping mutations persist in invocation order', () async {
    final storage = File('${tempDir.path}/custom_snippets.json');
    final notifier = _TrackingSaveNotifier(() async => storage);
    addTearDown(notifier.dispose);
    await notifier.loadFromDisk();

    await Future.wait([
      notifier.addSnippet(_snippet('one', 'One')),
      notifier.addSnippet(_snippet('two', 'Two')),
    ]);

    expect(notifier.maxConcurrentSaves, 1);
    expect(notifier.state.map((snippet) => snippet.id), ['one', 'two']);
    final persisted = jsonDecode(await storage.readAsString()) as List<dynamic>;
    expect(persisted.map((entry) => (entry as Map<String, dynamic>)['id']), [
      'one',
      'two',
    ]);
  });

  test('a corrupt templates file is not silently overwritten', () async {
    final storage = File('${tempDir.path}/custom_snippets.json');
    await storage.writeAsString('{not valid JSON');
    final notifier = CustomSnippetsNotifier(snippetsFile: () async => storage);
    addTearDown(notifier.dispose);
    await notifier.loadFromDisk();

    await expectLater(
      notifier.addSnippet(_snippet('one', 'One')),
      throwsA(isA<StateError>()),
    );
    expect(await storage.readAsString(), '{not valid JSON');
    expect(notifier.state, isEmpty);
  });
}

TemplateSnippet _snippet(String id, String name) {
  return TemplateSnippet(
    id: id,
    name: name,
    description: '$name description',
    category: SnippetCategory.custom,
    iconName: 'star',
    nodeData: const [],
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

class _TrackingSaveNotifier extends CustomSnippetsNotifier {
  _TrackingSaveNotifier(Future<File> Function() snippetsFile)
    : super(snippetsFile: snippetsFile);

  int _concurrentSaves = 0;
  int maxConcurrentSaves = 0;

  @override
  Future<void> saveToDisk() async {
    _concurrentSaves++;
    if (_concurrentSaves > maxConcurrentSaves) {
      maxConcurrentSaves = _concurrentSaves;
    }
    try {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await super.saveToDisk();
    } finally {
      _concurrentSaves--;
    }
  }
}

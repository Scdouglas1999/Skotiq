// A remote client's plan changes are written into the host's editor, and the
// host's periodic re-hydrate no longer wipes them: the client and the host
// edit one plan, and the last writer wins with a note.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/host_open_plan.dart';
import '../../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Sequence _plan(String name, {int count = 5, int? databaseId}) {
  return Sequence.create(
    name: name,
    rootNodeId: 'root',
    nodes: {
      'root': InstructionSetNode(
        id: 'root',
        name: 'Sequence',
        childIds: const ['expose'],
      ),
      'expose': ExposureNode(
        id: 'expose',
        parentId: 'root',
        durationSecs: 10,
        count: count,
        frameType: FrameType.light,
      ),
    },
    databaseId: databaseId,
  );
}

Map<String, dynamic> _hostCanvas(SequenceFileService files, Sequence sequence) =>
    openPlanDocument(files, sequence, unsaved: false);

Future<void> _settle() =>
    Future<void>.delayed(remoteEditorWriteThroughDebounce * 2);

void main() {
  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  late _MockNetworkBackend host;
  late ProviderContainer container;
  late List<Map<String, dynamic>?> written;
  Completer<void>? holdWrite;

  setUp(() {
    written = [];
    holdWrite = null;
    host = _MockNetworkBackend();
    when(() => host.eventStream).thenAnswer((_) => const Stream.empty());
    when(() => host.serverHost).thenReturn('rig.local');
    when(
      () => host.saveFullSequence(
        any(),
        isTemplate: any(named: 'isTemplate'),
        databaseId: any(named: 'databaseId'),
      ),
    ).thenAnswer((_) async => 12);
    when(
      () => host.putOpenEditorSequence(
        any(),
        databaseId: any(named: 'databaseId'),
        isDirty: any(named: 'isDirty'),
      ),
    ).thenAnswer((invocation) async {
      written.add(
        invocation.positionalArguments.first as Map<String, dynamic>?,
      );
      final gate = holdWrite;
      if (gate != null) await gate.future;
    });
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _FixedBackendNotifier(ref, host)),
      ],
    );
    container.read(remoteSequenceEditorSyncProvider);
  });

  tearDown(() => container.dispose());

  test('an edit made here reaches the host editor, and the host\'s stale '
      'canvas from the periodic re-hydrate does not wipe it', () async {
    final files = container.read(sequenceFileServiceProvider);
    final editor = container.read(currentSequenceProvider.notifier);
    final stale = _plan('New Sequence');
    showHostOpenPlan(container, _hostCanvas(files, stale));
    expect(
      written,
      isEmpty,
      reason:
          'a plan taken from the host is not '
          'written back',
    );

    holdWrite = Completer<void>();
    editor.setName('M13');
    await Future<void>.delayed(remoteEditorWriteThroughDebounce * 2);
    expect(written.single?['name'], 'M13');

    // The re-hydrate lands while the write is still in flight.
    showHostOpenPlan(container, _hostCanvas(files, stale));
    expect(container.read(currentSequenceProvider)?.name, 'M13');

    holdWrite!.complete();
    await _settle();
    // The host now holds this plan; its echo, which went through the wire
    // format, changes nothing here.
    final shown = container.read(currentSequenceProvider)!;
    showHostOpenPlan(container, _hostCanvas(files, files.parseFromMap(files.sequenceToMap(shown))));
    expect(identical(container.read(currentSequenceProvider), shown), isTrue);
    expect(editor.canUndo, isTrue);
  });

  test(
    'a saved plan opened here is written to the host and stays open',
    () async {
      final files = container.read(sequenceFileServiceProvider);
      final editor = container.read(currentSequenceProvider.notifier);
      showHostOpenPlan(container, _hostCanvas(files, _plan('New Sequence')));

      editor.loadCopyForEditing(_plan('QA M13 pair', databaseId: 5));
      await _settle();

      expect(written.single?['name'], 'QA M13 pair');
      final hostNow = files.parseFromMap(written.single!);
      showHostOpenPlan(container, _hostCanvas(files, hostNow.copyWith(databaseId: 5)));
      expect(container.read(currentSequenceProvider)?.name, 'QA M13 pair');
    },
  );

  test(
    'a later edit on the host replaces this client\'s plan with a note',
    () async {
      final files = container.read(sequenceFileServiceProvider);
      final editor = container.read(currentSequenceProvider.notifier);
      showHostOpenPlan(container, _hostCanvas(files, _plan('Plan')));
      editor.setName('Plan, client edit');
      await _settle();
      expect(written, hasLength(1));

      showHostOpenPlan(container, _hostCanvas(files, _plan('Plan, host edit', count: 9)));

      expect(container.read(currentSequenceProvider)?.name, 'Plan, host edit');
      final notes = container.read(uiNotificationProvider);
      expect(notes, hasLength(1));
      expect(notes.single.title, 'Plan updated');
      expect(notes.single.message, contains('rig.local'));
      await _settle();
      expect(written, hasLength(1), reason: 'the host\'s plan is not echoed');
    },
  );
}

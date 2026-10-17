import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
    registerFallbackValue(Sequence.create(name: 'fallback', nodes: const {}));
  });

  group('remoteSequenceEditorSyncProvider', () {
    test('debounces saveFullSequence until edits settle', () {
      fakeAsync((async) {
        final backend = _MockNetworkBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(
          () => backend.saveFullSequence(
            any(),
            isTemplate: any(named: 'isTemplate'),
            databaseId: any(named: 'databaseId'),
          ),
        ).thenAnswer((_) async => 99);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );

        container.read(remoteSequenceEditorSyncProvider);
        final editor = container.read(currentSequenceProvider.notifier);

        const rootId = 'root-remote-sync';
        editor.loadSequence(
          Sequence.create(
            name: 'Draft',
            nodes: {rootId: InstructionSetNode(id: rootId, name: 'Sequence')},
            rootNodeId: rootId,
          ),
        );
        editor.setName('Draft v2');

        async.elapse(const Duration(milliseconds: 500));
        verifyNever(
          () => backend.saveFullSequence(
            any(),
            isTemplate: any(named: 'isTemplate'),
            databaseId: any(named: 'databaseId'),
          ),
        );

        async.elapse(remoteSequenceAutoSaveDebounce);
        async.flushMicrotasks();

        verify(
          () => backend.saveFullSequence(
            any(
              that: predicate<Map<String, dynamic>>(
                (map) => map['name'] == 'Draft v2',
              ),
            ),
            isTemplate: false,
            databaseId: null,
          ),
        ).called(1);

        expect(container.read(currentSequenceProvider)?.databaseId, 99);
        expect(container.read(currentSequenceProvider.notifier).isDirty, false);

        container.dispose();
      });
    });

    test('does not save when sequence is clean after load', () {
      fakeAsync((async) {
        final backend = _MockNetworkBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );

        container.read(remoteSequenceEditorSyncProvider);
        final editor = container.read(currentSequenceProvider.notifier);

        const rootId = 'root-clean-load';
        editor.loadSequence(
          Sequence.create(
            name: 'Loaded',
            databaseId: 5,
            nodes: {rootId: InstructionSetNode(id: rootId, name: 'Sequence')},
            rootNodeId: rootId,
          ),
        );

        async.elapse(remoteSequenceAutoSaveDebounce);
        async.flushMicrotasks();

        verifyNever(
          () => backend.saveFullSequence(
            any(),
            isTemplate: any(named: 'isTemplate'),
            databaseId: any(named: 'databaseId'),
          ),
        );

        container.dispose();
      });
    });

    test('saves after createSequence when user adds a node', () {
      fakeAsync((async) {
        final backend = _MockNetworkBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(
          () => backend.saveFullSequence(
            any(),
            isTemplate: any(named: 'isTemplate'),
            databaseId: any(named: 'databaseId'),
          ),
        ).thenAnswer((_) async => 11);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );

        container.read(remoteSequenceEditorSyncProvider);
        final editor = container.read(currentSequenceProvider.notifier);
        editor.createSequence(name: 'New from tablet');

        const childId = 'child-node-remote';
        editor.addNode(
          InstructionSetNode(id: childId, name: 'Lights'),
          parentId: editor.state!.rootNodeId!,
        );

        async.elapse(remoteSequenceAutoSaveDebounce);
        async.flushMicrotasks();

        verify(
          () => backend.saveFullSequence(
            any(
              that: predicate<Map<String, dynamic>>(
                (map) => map['name'] == 'New from tablet',
              ),
            ),
            isTemplate: false,
            databaseId: null,
          ),
        ).called(1);

        container.dispose();
      });
    });

    test(
      'an edit made during an in-flight save remains dirty and is sent next',
      () {
        fakeAsync((async) {
          final backend = _MockNetworkBackend();
          final firstSave = Completer<int>();
          final savedNames = <String>[];
          var calls = 0;
          when(
            () => backend.eventStream,
          ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
          when(
            () => backend.saveFullSequence(
              any(),
              isTemplate: any(named: 'isTemplate'),
              databaseId: any(named: 'databaseId'),
            ),
          ).thenAnswer((invocation) {
            final document =
                invocation.positionalArguments.single as Map<String, dynamic>;
            savedNames.add(document['name'] as String);
            calls++;
            return calls == 1 ? firstSave.future : Future<int>.value(99);
          });

          final container = ProviderContainer(
            overrides: [
              inMemoryDatabaseOverride(),
              backendProvider.overrideWith(
                (ref) => _FixedBackendNotifier(ref, backend),
              ),
            ],
          );
          container.read(remoteSequenceEditorSyncProvider);
          final editor = container.read(currentSequenceProvider.notifier);
          const rootId = 'root-in-flight-edit';
          editor.loadSequence(
            Sequence.create(
              name: 'Draft',
              nodes: {rootId: InstructionSetNode(id: rootId, name: 'Sequence')},
              rootNodeId: rootId,
            ),
          );

          editor.setName('Draft v2');
          async.elapse(remoteSequenceAutoSaveDebounce);
          async.flushMicrotasks();
          expect(calls, 1);

          editor.setName('Draft v3');
          async.elapse(remoteSequenceAutoSaveDebounce);
          async.flushMicrotasks();
          expect(calls, 1, reason: 'remote saves must be serialized');

          firstSave.complete(99);
          async.flushMicrotasks();
          expect(editor.isDirty, isTrue);
          expect(container.read(currentSequenceProvider)?.databaseId, 99);

          async.elapse(remoteSequenceAutoSaveDebounce);
          async.flushMicrotasks();
          expect(calls, 2);
          expect(savedNames, ['Draft v2', 'Draft v3']);
          expect(editor.isDirty, isFalse);

          container.dispose();
        });
      },
    );

    test('a delayed save response cannot re-anchor a different sequence', () {
      fakeAsync((async) {
        final backend = _MockNetworkBackend();
        final firstSave = Completer<int>();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(
          () => backend.saveFullSequence(
            any(),
            isTemplate: any(named: 'isTemplate'),
            databaseId: any(named: 'databaseId'),
          ),
        ).thenAnswer((_) => firstSave.future);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );
        container.read(remoteSequenceEditorSyncProvider);
        final editor = container.read(currentSequenceProvider.notifier);
        editor.loadSequence(Sequence.create(name: 'Sequence A'));
        editor.setName('Sequence A edited');
        async.elapse(remoteSequenceAutoSaveDebounce);
        async.flushMicrotasks();

        final sequenceB = Sequence.create(name: 'Sequence B', databaseId: 77);
        editor.loadSequence(sequenceB, discardUnsaved: true);
        firstSave.complete(99);
        async.flushMicrotasks();

        expect(container.read(currentSequenceProvider)?.name, 'Sequence B');
        expect(container.read(currentSequenceProvider)?.databaseId, 77);
        expect(editor.isDirty, isFalse);

        container.dispose();
      });
    });

    test(
      'application shutdown refuses to discard a failed remote save',
      () async {
        final backend = _MockNetworkBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(
          () => backend.saveFullSequence(
            any(),
            isTemplate: any(named: 'isTemplate'),
            databaseId: any(named: 'databaseId'),
          ),
        ).thenThrow(StateError('host unavailable'));

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(remoteSequenceEditorSyncProvider);
        final editor = container.read(currentSequenceProvider.notifier);
        editor.loadSequence(Sequence.create(name: 'Shutdown draft'));
        editor.setName('Shutdown draft edited');

        await expectLater(
          container.read(backendProvider.notifier).prepareForShutdown(),
          throwsStateError,
        );

        expect(editor.isDirty, isTrue);
        expect(container.read(backendProvider), same(backend));
      },
    );

    test(
      'backend disconnect awaits the pending dirty save before disposal',
      () {
        fakeAsync((async) {
          final backend = _MockNetworkBackend();
          when(
            () => backend.eventStream,
          ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
          // The backend-swap path guards on the outgoing host being
          // controllable (`oldBackend.connectionState == connected`) before
          // it flushes + disposes; an unstubbed getter made disconnect()
          // reject before the flush ever ran.
          when(
            () => backend.connectionState,
          ).thenReturn(BackendConnectionState.connected);
          when(
            () => backend.saveFullSequence(
              any(),
              isTemplate: any(named: 'isTemplate'),
              databaseId: any(named: 'databaseId'),
            ),
          ).thenAnswer((_) async => 55);

          final container = ProviderContainer(
            overrides: [
              inMemoryDatabaseOverride(),
              backendProvider.overrideWith(
                (ref) => _FixedBackendNotifier(ref, backend),
              ),
            ],
          );
          container.read(remoteSequenceEditorSyncProvider);
          final editor = container.read(currentSequenceProvider.notifier);
          editor.loadSequence(Sequence.create(name: 'Disconnect draft'));
          editor.setName('Disconnect draft edited');

          var disconnected = false;
          unawaited(
            container.read(backendProvider.notifier).disconnect().then((_) {
              disconnected = true;
            }),
          );
          async.flushMicrotasks();

          expect(disconnected, isTrue);
          verify(
            () => backend.saveFullSequence(
              any(
                that: predicate<Map<String, dynamic>>(
                  (map) => map['name'] == 'Disconnect draft edited',
                ),
              ),
              isTemplate: false,
              databaseId: null,
            ),
          ).called(1);
          expect(container.read(backendProvider), isA<DisconnectedBackend>());

          container.dispose();
        });
      },
    );
  });
}

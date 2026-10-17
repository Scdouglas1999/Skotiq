// SequenceExecutor.skipToNode forwards through the backend to the native
// sequencer. The Rust side is exercised by the `skotiq_sequencer` cargo
// tests; this file pins the Dart proxy so dropping the call (or sending the
// wrong node id) fires loudly at `flutter test` time.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../mocks/mock_backend.dart';

/// Mirrors the pattern used in `device_service_filter_wheel_test.dart`: the
/// real `BackendNotifier` is a `StateNotifier<SkotiqBackend>`, so we
/// substitute it with one that boots into our `MockBackend` instead of the
/// `DisconnectedBackend` default.
class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  group('SequenceExecutor.skipToNode', () {
    late MockBackend backend;
    late SkotiqDatabase db;
    late ProviderContainer container;

    setUp(() {
      backend = MockBackend();
      // Default no-op for the proxy call so tests that only care about
      // *whether* the proxy fired don't have to re-stub every time.
      when(() => backend.sequencerSkipToNode(any())).thenAnswer((_) async {});
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Future<void>.delayed(Duration.zero);
        await db.close();
      });
    });

    test('forwards the node id verbatim to the backend', () async {
      final executor = container.read(sequenceExecutorProvider);
      await executor.skipToNode('node-42');
      verify(() => backend.sequencerSkipToNode('node-42')).called(1);
    });

    test('propagates backend errors so the UI can show a snackbar', () async {
      when(
        () => backend.sequencerSkipToNode(any()),
      ).thenThrow(StateError('Executor is not running'));
      final executor = container.read(sequenceExecutorProvider);
      // The UI handler (sequence_tree_context_menu.dart) catches this and
      // routes it into a snackbar. Verify here that the throw is preserved
      // so the catch site actually has something to report.
      expect(() => executor.skipToNode('node-1'), throwsA(isA<StateError>()));
    });

    test('multiple sequential calls are all forwarded', () async {
      // The executor must not coalesce repeated jumps (e.g. a user clicking
      // "Skip to here" on different nodes in rapid succession) — each call
      // reaches the backend so the Rust side updates its `next_jump_target`.
      final executor = container.read(sequenceExecutorProvider);
      await executor.skipToNode('node-a');
      await executor.skipToNode('node-b');
      await executor.skipToNode('node-c');
      verifyInOrder([
        () => backend.sequencerSkipToNode('node-a'),
        () => backend.sequencerSkipToNode('node-b'),
        () => backend.sequencerSkipToNode('node-c'),
      ]);
    });
  });
}

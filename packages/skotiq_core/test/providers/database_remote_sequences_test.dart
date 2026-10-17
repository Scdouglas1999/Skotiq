import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  group('allDbSequencesProvider remote parity', () {
    test('polls host sequence-management list on NetworkBackend', () async {
      final backend = _MockNetworkBackend();
      when(() => backend.getSequenceList()).thenAnswer(
        (_) async => [
          {
            'id': 4,
            'name': 'Host LRGB',
            'description': 'notes',
            'rootNodeId': 'root-1',
            'isTemplate': false,
            'createdAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
            'updatedAt': DateTime(2026, 1, 2).millisecondsSinceEpoch,
          },
        ],
      );

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      final rows = await container.read(allDbSequencesProvider.future);
      expect(rows, hasLength(1));
      expect(rows.single.id, 4);
      expect(rows.single.name, 'Host LRGB');
      verify(() => backend.getSequenceList()).called(1);
    });

    test('allDbTemplatesProvider uses templates list endpoint', () async {
      final backend = _MockNetworkBackend();
      when(() => backend.getSequenceTemplates()).thenAnswer(
        (_) async => [
          {
            'id': 9,
            'name': 'Ha template',
            'description': null,
            'rootNodeId': null,
            'isTemplate': true,
            'createdAt': DateTime(2026, 2, 1).millisecondsSinceEpoch,
            'updatedAt': DateTime(2026, 2, 2).millisecondsSinceEpoch,
          },
        ],
      );

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      final rows = await container.read(allDbTemplatesProvider.future);
      expect(rows, hasLength(1));
      expect(rows.single.isTemplate, isTrue);
      verify(() => backend.getSequenceTemplates()).called(1);
    });
  });
}

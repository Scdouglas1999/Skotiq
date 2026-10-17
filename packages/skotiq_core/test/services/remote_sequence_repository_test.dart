import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  group('SequenceRepository.remote', () {
    late _MockNetworkBackend backend;
    late ProviderContainer container;

    setUp(() {
      backend = _MockNetworkBackend();
      container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
    });

    tearDown(() => container.dispose());

    test('loadAllSequences reads host list-full documents', () async {
      when(() => backend.listFullSequences()).thenAnswer(
        (_) async => [
          {
            'schemaVersion': SequenceFileService.currentSchemaVersion,
            'version': '2.0',
            'name': 'Host Sequence',
            'description': '',
            'rootNodeId': 'root-1',
            'isTemplate': false,
            'databaseId': 42,
            'createdAt': DateTime(2026, 1, 1).toIso8601String(),
            'modifiedAt': DateTime(2026, 1, 2).toIso8601String(),
            'nodes': {
              'root-1': {
                'id': 'root-1',
                'nodeType': 'instructionSet',
                'name': 'Sequence',
                'parentId': null,
                'childIds': <String>[],
                'orderIndex': 0,
                'isEnabled': true,
              },
            },
          },
        ],
      );

      final repo = container.read(sequenceRepositoryProvider);
      final sequences = await repo.loadAllSequences();

      expect(sequences, hasLength(1));
      expect(sequences.first.name, 'Host Sequence');
      expect(sequences.first.databaseId, 42);
      verify(() => backend.listFullSequences()).called(1);
    });

    test('loadSequence fetches one full host document', () async {
      when(() => backend.getFullSequence(42)).thenAnswer(
        (_) async => {
          'schemaVersion': SequenceFileService.currentSchemaVersion,
          'version': '2.0',
          'name': 'One Host Sequence',
          'description': '',
          'rootNodeId': 'root-one',
          'isTemplate': false,
          'databaseId': 42,
          'createdAt': DateTime(2026, 1, 1).toIso8601String(),
          'modifiedAt': DateTime(2026, 1, 2).toIso8601String(),
          'nodes': {
            'root-one': {
              'id': 'root-one',
              'nodeType': 'instructionSet',
              'name': 'Sequence',
              'parentId': null,
              'childIds': <String>[],
              'orderIndex': 0,
              'isEnabled': true,
            },
          },
        },
      );

      final sequence = await container
          .read(sequenceRepositoryProvider)
          .loadSequence(42);

      expect(sequence?.name, 'One Host Sequence');
      expect(sequence?.databaseId, 42);
      verify(() => backend.getFullSequence(42)).called(1);
      verifyNever(() => backend.listFullSequences());
      verifyNever(() => backend.listFullTemplates());
    });

    test('saveSequence posts full document to host', () async {
      when(
        () => backend.saveFullSequence(
          any(),
          isTemplate: any(named: 'isTemplate'),
          databaseId: any(named: 'databaseId'),
        ),
      ).thenAnswer((_) async => 7);

      final repo = container.read(sequenceRepositoryProvider);
      const rootId = 'root-save-test';
      final sequence = Sequence.create(
        name: 'Tablet Draft',
        databaseId: null,
        nodes: {rootId: InstructionSetNode(id: rootId, name: 'Sequence')},
        rootNodeId: rootId,
      );

      final id = await repo.saveSequence(sequence);

      expect(id, 7);
      verify(
        () => backend.saveFullSequence(
          any(
            that: predicate<Map<String, dynamic>>(
              (map) => map['name'] == 'Tablet Draft',
            ),
          ),
          isTemplate: false,
          databaseId: null,
        ),
      ).called(1);
    });

    test(
      'summary metadata comes from the host without hydrating trees',
      () async {
        when(() => backend.listSequenceSummaries()).thenAnswer(
          (_) async => [
            RemoteSequenceSummary(
              id: 42,
              name: 'Host Sequence',
              nodeCount: 8,
              targetCount: 2,
              exposureCount: 3,
              totalIntegrationSecs: 7200,
              runCount: 4,
              tags: const ['winter'],
              isFavorite: true,
              createdAt: DateTime.utc(2026, 1, 1),
              modifiedAt: DateTime.utc(2026, 1, 2),
              primaryTargetName: 'M42',
              lastRunAt: DateTime.utc(2026, 1, 3),
            ),
          ],
        );

        final summary =
            (await container
                    .read(sequenceRepositoryProvider)
                    .loadSequenceSummaries())
                .single;
        expect(summary.id, 42);
        expect(summary.tags, ['winter']);
        expect(summary.isFavorite, isTrue);
        expect(summary.runCount, 4);
        verify(() => backend.listSequenceSummaries()).called(1);
        verifyNever(() => backend.listFullSequences());
      },
    );

    test('tags and favorites mutate host-owned metadata', () async {
      when(() => backend.setSequenceTags(42, any())).thenAnswer((_) async {});
      when(
        () => backend.toggleSequenceFavorite(42),
      ).thenAnswer((_) async => true);
      final repo = container.read(sequenceRepositoryProvider);

      await repo.setTags(42, ['  winter ', 'winter', '', 'narrowband']);
      expect(await repo.toggleFavorite(42), isTrue);

      verify(
        () => backend.setSequenceTags(42, ['winter', 'narrowband']),
      ).called(1);
      verify(() => backend.toggleSequenceFavorite(42)).called(1);
    });

    test(
      'explicit remote version snapshot lists and restores in place',
      () async {
        const rootId = 'root-version-test';
        final sequence = Sequence.create(
          name: 'Remote version',
          databaseId: 42,
          nodes: {rootId: InstructionSetNode(id: rootId, name: 'Sequence')},
          rootNodeId: rootId,
        );
        final snapshotJson = jsonEncode(
          SequenceFileService().sequenceToMap(sequence),
        );
        final versionSummary = RemoteSequenceVersionSummary(
          id: 9,
          sequenceId: 42,
          label: 'before edit',
          createdAt: DateTime.utc(2026, 1, 3),
        );
        final version = RemoteSequenceVersion(
          id: 9,
          sequenceId: 42,
          snapshotJson: snapshotJson,
          label: 'before edit',
          createdAt: DateTime.utc(2026, 1, 3),
        );
        when(
          () =>
              backend.snapshotSequenceVersion(42, any(), label: 'before edit'),
        ).thenAnswer((_) async => 9);
        when(
          () => backend.listSequenceVersions(42),
        ).thenAnswer((_) async => [versionSummary]);
        when(
          () => backend.getSequenceVersion(9),
        ).thenAnswer((_) async => version);
        final repo = container.read(sequenceRepositoryProvider);

        expect(
          await repo.snapshotVersionOnSave(sequence, label: 'before edit'),
          9,
        );
        expect((await repo.listVersions(42)).single.label, 'before edit');
        final restored = await repo.restoreVersion(9);
        expect(restored?.name, 'Remote version');
        expect(restored?.databaseId, 42);
      },
    );

    test('unsaved remote sequence does not create a version request', () async {
      const rootId = 'root-unsaved-version-test';
      final sequence = Sequence.create(
        name: 'Unsaved remote',
        nodes: {rootId: InstructionSetNode(id: rootId, name: 'Sequence')},
        rootNodeId: rootId,
      );

      expect(
        await container
            .read(sequenceRepositoryProvider)
            .snapshotVersionOnSave(sequence),
        isNull,
      );
      verifyNever(
        () => backend.snapshotSequenceVersion(
          any(),
          any(),
          label: any(named: 'label'),
        ),
      );
    });
  });
}

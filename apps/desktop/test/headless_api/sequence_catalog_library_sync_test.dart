import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequence_management_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// End-to-end: tablet POST save-full → host Drift → catalog bus →
/// [savedSequencesProvider] on the desktop [ProviderContainer].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Sequence catalog library sync', () {
    late ProviderContainer container;
    late SequenceManagementHandlers handlers;
    late SkotiqDatabase db;

    setUp(() async {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      handlers = SequenceManagementHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test(
      'save-full refreshes savedSequencesProvider when sync is active',
      () async {
        container.read(sequenceLibrarySyncProvider);
        container.listen(savedSequencesProvider, (_, __) {});

        const rootId = 'root-catalog-library-sync';
        final response = await translateHandlerErrors(
          handlers.handleSaveFullSequence(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sequence-management/save-full'),
              body: jsonEncode({
                'sequence': {
                  'schemaVersion': SequenceFileService.currentSchemaVersion,
                  'version': '2.0',
                  'name': 'Tablet Draft',
                  'description': '',
                  'rootNodeId': rootId,
                  'isTemplate': false,
                  'createdAt': DateTime(2026, 1, 1).toIso8601String(),
                  'modifiedAt': DateTime(2026, 1, 2).toIso8601String(),
                  'nodes': {
                    rootId: {
                      'id': rootId,
                      'nodeType': 'instructionSet',
                      'name': 'Sequence',
                      'parentId': null,
                      'childIds': <String>[],
                      'orderIndex': 0,
                      'isEnabled': true,
                    },
                  },
                },
                'isTemplate': false,
              }),
              headers: {'Content-Type': 'application/json'},
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        await Future<void>.delayed(Duration.zero);

        final sequences = await container.read(savedSequencesProvider.future);
        expect(sequences, hasLength(1));
        expect(sequences.single.name, 'Tablet Draft');
      },
    );
  });
}

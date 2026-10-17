import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequence_management_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SequenceManagementHandlers', () {
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

    test('invalid sequence ID returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetSequenceById(
          Request(
            'GET',
            Uri.parse('http://localhost/api/sequence-management/not-an-id'),
          ),
          'not-an-id',
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test(
      'create sequence malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCreateSequence(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sequence-management'),
              body: jsonEncode({}),
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test(
      'set node enabled malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSetNodeEnabled(
            Request(
              'POST',
              Uri.parse(
                'http://localhost/api/sequence-management/nodes/1/enabled',
              ),
              body: jsonEncode({}),
            ),
            '1',
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test(
      'create node rejects unsupported wire types without poisoning the tree',
      () async {
        final sequenceId = await db.sequencesDao.createSequence(
          SequencesCompanion.insert(name: 'Node validation'),
        );

        final response = await translateHandlerErrors(
          handlers.handleCreateNode(
            Request(
              'POST',
              Uri.parse(
                'http://localhost/api/sequence-management/$sequenceId/nodes',
              ),
              body: jsonEncode({
                'nodeId': 'bad-root',
                'nodeType': 'container',
                'specificType': 'sequential',
                'name': 'Unsupported root',
                'properties': '{}',
              }),
            ),
            '$sequenceId',
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['field'], 'specificType');
        expect(await db.sequencesDao.getNodesForSequence(sequenceId), isEmpty);
      },
    );

    test(
      'save-full rejects a malformed payload as 400 without leaking internals',
      () async {
        // A bad `nodes` encoding is a CLIENT error, so it must be a 400 whose
        // message names the offending field and nothing else. A 500 carrying
        // `e.toString()` reads as "the host broke", invites a retry storm, and
        // ships Dart class names over the wire.
        final response = await translateHandlerErrors(
          handlers.handleSaveFullSequence(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sequence-management/save-full'),
              body: jsonEncode({
                'sequence': {
                  'name': 'Bad',
                  // `nodes` must be a JSON object keyed by node id.
                  'nodes': <dynamic>['not', 'an', 'object'],
                },
              }),
              headers: {'Content-Type': 'application/json'},
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        expect(response.headers['content-type'], 'application/json');
        final raw = await response.readAsString();
        final body = jsonDecode(raw) as Map;
        expect(body['field'], 'sequence');
        expect(body['expected'], 'sequence_document');
        // No Dart type/exception names may reach the caller.
        expect(raw, isNot(contains('FormatException')));
        expect(raw, isNot(contains('TypeError')));
        expect(raw, isNot(contains('is not a subtype of')));
      },
    );

    test('save-full persists sequence and notifies catalog bus', () async {
      final updates = <SequenceCatalogUpdate>[];
      final sub = container
          .read(sequenceCatalogUpdateBusProvider)
          .stream
          .listen(updates.add);

      const rootId = 'root-save-full-test';
      final response = await translateHandlerErrors(
        handlers.handleSaveFullSequence(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequence-management/save-full'),
            body: jsonEncode({
              'sequence': {
                'schemaVersion': SequenceFileService.currentSchemaVersion,
                'version': '2.0',
                'name': 'Remote Draft',
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
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['id'], isA<int>());

      expect(updates, hasLength(1));
      expect(updates.single.action, 'saved');
      expect(updates.single.name, 'Remote Draft');
      expect(updates.single.sequenceId, body['id']);
      expect(
        await db.sequenceVersionsDao.listVersions(body['id'] as int),
        isEmpty,
        reason: 'debounced save-full must not flood explicit version history',
      );

      await sub.cancel();
    });

    test(
      'delete sequence publishes catalog bus and HostStateChanged',
      () async {
        const rootId = 'root-delete-notify';
        final saveResponse = await translateHandlerErrors(
          handlers.handleSaveFullSequence(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sequence-management/save-full'),
              body: jsonEncode({
                'sequence': {
                  'schemaVersion': SequenceFileService.currentSchemaVersion,
                  'version': '2.0',
                  'name': 'To Delete',
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
        final saveBody = jsonDecode(await saveResponse.readAsString()) as Map;
        final sequenceId = saveBody['id'] as int;

        final published = <SkotiqEvent>[];
        container.read(hostMutationEventHubProvider).wsBroadcast =
            published.add;

        final deleteResponse = await translateHandlerErrors(
          handlers.handleDeleteSequence(
            Request(
              'DELETE',
              Uri.parse('http://localhost/api/sequence-management/$sequenceId'),
            ),
            sequenceId.toString(),
          ),
        );
        expect(deleteResponse.statusCode, HttpStatus.ok);
        expect(published, hasLength(1));
        expect(published.single.eventType, hostStateChangedEventType);
        expect(published.single.data['entityId'], sequenceId.toString());
        expect(published.single.data['action'], HostMutationAction.deleted);
      },
    );

    test('list-full returns persisted sequences', () async {
      const rootId = 'root-list-full';
      await translateHandlerErrors(
        handlers.handleSaveFullSequence(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequence-management/save-full'),
            body: jsonEncode({
              'sequence': {
                'schemaVersion': SequenceFileService.currentSchemaVersion,
                'version': '2.0',
                'name': 'List Full Entry',
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

      final listResponse = await translateHandlerErrors(
        handlers.handleListFullSequences(
          Request(
            'GET',
            Uri.parse('http://localhost/api/sequence-management/list-full'),
          ),
        ),
      );
      expect(listResponse.statusCode, HttpStatus.ok);
      final body = jsonDecode(await listResponse.readAsString()) as Map;
      final sequences = body['sequences'] as List;
      expect(sequences, isNotEmpty);
      final saved = sequences.cast<Map>().singleWhere(
        (m) => m['name'] == 'List Full Entry',
      );

      final detailResponse = await translateHandlerErrors(
        handlers.handleGetFullSequence(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/sequence-management/${saved['databaseId']}/full',
            ),
          ),
          '${saved['databaseId']}',
        ),
      );
      expect(detailResponse.statusCode, HttpStatus.ok);
      final detail = jsonDecode(await detailResponse.readAsString()) as Map;
      expect((detail['sequence'] as Map)['name'], 'List Full Entry');
    });

    test('remote library metadata and explicit versions round-trip', () async {
      const rootId = 'root-library-parity';
      final sequenceMap = <String, dynamic>{
        'schemaVersion': SequenceFileService.currentSchemaVersion,
        'version': '2.0',
        'name': 'Library Parity',
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
      };
      final saveResponse = await translateHandlerErrors(
        handlers.handleSaveFullSequence(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequence-management/save-full'),
            body: jsonEncode({'sequence': sequenceMap, 'isTemplate': false}),
            headers: {'Content-Type': 'application/json'},
          ),
        ),
      );
      final sequenceId =
          (jsonDecode(await saveResponse.readAsString()) as Map)['id'] as int;

      final tagsResponse = await translateHandlerErrors(
        handlers.handleSetTags(
          Request(
            'PUT',
            Uri.parse(
              'http://localhost/api/sequence-management/$sequenceId/tags',
            ),
            body: jsonEncode({
              'tags': ['  winter ', 'winter', '', 'narrowband'],
            }),
            headers: {'Content-Type': 'application/json'},
          ),
          '$sequenceId',
        ),
      );
      expect(tagsResponse.statusCode, HttpStatus.ok);

      final favoriteResponse = await translateHandlerErrors(
        handlers.handleToggleFavorite(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/sequence-management/$sequenceId/favorite',
            ),
          ),
          '$sequenceId',
        ),
      );
      final favoriteBody =
          jsonDecode(await favoriteResponse.readAsString()) as Map;
      expect(favoriteBody['isFavorite'], isTrue);

      final summariesResponse = await translateHandlerErrors(
        handlers.handleListSequenceSummaries(
          Request(
            'GET',
            Uri.parse('http://localhost/api/sequence-management/summaries'),
          ),
        ),
      );
      final summariesBody =
          jsonDecode(await summariesResponse.readAsString()) as Map;
      final summary = (summariesBody['summaries'] as List)
          .cast<Map>()
          .singleWhere((row) => row['id'] == sequenceId);
      expect(summary['tags'], ['winter', 'narrowband']);
      expect(summary['isFavorite'], isTrue);

      final snapshotResponse = await translateHandlerErrors(
        handlers.handleSnapshotVersion(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/sequence-management/$sequenceId/versions',
            ),
            body: jsonEncode({'sequence': sequenceMap, 'label': 'before edit'}),
            headers: {'Content-Type': 'application/json'},
          ),
          '$sequenceId',
        ),
      );
      final versionId =
          (jsonDecode(await snapshotResponse.readAsString()) as Map)['id']
              as int;

      final listResponse = await translateHandlerErrors(
        handlers.handleListVersions(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/sequence-management/$sequenceId/versions',
            ),
          ),
          '$sequenceId',
        ),
      );
      final versions =
          (jsonDecode(await listResponse.readAsString()) as Map)['versions']
              as List;
      expect(versions, hasLength(1));
      expect((versions.single as Map)['label'], 'before edit');
      expect(
        versions.single,
        isNot(contains('snapshotJson')),
        reason: 'history lists must not transfer every full sequence snapshot',
      );

      final detailResponse = await translateHandlerErrors(
        handlers.handleGetVersion(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/sequence-management/versions/$versionId',
            ),
          ),
          '$versionId',
        ),
      );
      final version =
          (jsonDecode(await detailResponse.readAsString()) as Map)['version']
              as Map;
      expect(version['sequenceId'], sequenceId);
      expect(version['snapshotJson'], contains('Library Parity'));
    });
  });
}

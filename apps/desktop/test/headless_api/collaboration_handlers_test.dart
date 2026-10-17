import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/collaboration_handlers.dart';
import 'package:skotiq_desktop/headless_api/request_context.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CollaborationHandlers', () {
    late Directory tempDir;
    late LoggingService logger;
    late LiveCollaborationSessionManager manager;
    late CollaborationHandlers handlers;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'ns_collaboration_handlers_test_',
      );
      logger = LoggingService(
        applicationSupportDirectoryProvider: () async => tempDir,
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => null,
      );
      await logger.ensureInitialized();
      manager = LiveCollaborationSessionManager();
      handlers = CollaborationHandlers(manager: manager, logger: logger);
    });

    tearDown(() async {
      manager.dispose();
      await logger.dispose();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Request post(String path, Object? body, {Map<String, Object>? context}) =>
        Request(
          'POST',
          Uri.parse('http://localhost$path'),
          body: body is String ? body : jsonEncode(body),
          context: context,
        );

    test(
      'malformed JSON is a client error on every object-body endpoint',
      () async {
        final methods = <Future<Response> Function(Request)>[
          handlers.handleCollaborationJoin,
          handlers.handleCollaborationLeave,
          handlers.handleCollaborationPreview,
          handlers.handleCollaborationChat,
          handlers.handleCollaborationAnnotation,
          handlers.handleSetSessionHandoff,
        ];

        for (final method in methods) {
          final response = await translateHandlerErrors(
            method(post('/api/collaboration/test', '{')),
          );
          expect(response.statusCode, HttpStatus.badRequest);
        }
      },
    );

    test('wrong field types are 400s rather than generic 500s', () async {
      final cases =
          <(Future<Response> Function(Request), Map<String, Object?>)>[
            (handlers.handleCollaborationJoin, {'viewerId': 'v', 'name': 3}),
            (handlers.handleCollaborationLeave, {'viewerId': 3}),
            (handlers.handleCollaborationPreview, {'preview': <Object>[]}),
            (
              handlers.handleCollaborationChat,
              {'viewerId': 'v', 'viewerName': 3, 'message': 'hello'},
            ),
            (
              handlers.handleCollaborationAnnotation,
              {
                'annotationId': 'a',
                'viewerId': 'v',
                'kind': 'label',
                'payload': <Object>[],
              },
            ),
            (handlers.handleSetSessionHandoff, {'handoff': <Object>[]}),
          ];

      for (final (method, body) in cases) {
        final response = await translateHandlerErrors(
          method(post('/api/collaboration/test', body)),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: '$body');
      }
    });

    test(
      'authenticated chat and annotations do not require a duplicate ID',
      () async {
        const authContext = <String, Object>{
          authIdentityContextKey: 'authenticated-viewer',
        };

        final join = await handlers.handleCollaborationJoin(
          post('/api/collaboration/viewers/join', {
            'name': 'Alice',
          }, context: authContext),
        );
        expect(join.statusCode, HttpStatus.ok);

        final chat = await handlers.handleCollaborationChat(
          post('/api/collaboration/chat', {
            'viewerName': 'Alice',
            'message': 'Clear skies',
          }, context: authContext),
        );
        expect(chat.statusCode, HttpStatus.ok);
        expect(manager.state.chat.single.viewerId, 'authenticated-viewer');

        final annotation = await handlers.handleCollaborationAnnotation(
          post('/api/collaboration/annotations', {
            'annotationId': 'target-box',
            'kind': 'roi',
            'payload': {'x': 12, 'y': 24},
          }, context: authContext),
        );
        expect(annotation.statusCode, HttpStatus.ok);
        expect(
          manager.state.annotations.single.viewerId,
          'authenticated-viewer',
        );
      },
    );

    test('blank human-visible fields are rejected instead of stored', () async {
      final cases =
          <(Future<Response> Function(Request), Map<String, Object?>)>[
            (
              handlers.handleCollaborationJoin,
              {'viewerId': 'v', 'name': '   '},
            ),
            (
              handlers.handleCollaborationChat,
              {'viewerId': 'v', 'viewerName': 'Alice', 'message': '   '},
            ),
            (
              handlers.handleCollaborationAnnotation,
              {
                'annotationId': '   ',
                'viewerId': 'v',
                'kind': 'roi',
                'payload': <String, Object?>{},
              },
            ),
          ];

      for (final (method, body) in cases) {
        final response = await translateHandlerErrors(
          method(post('/api/collaboration/test', body)),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: '$body');
      }
    });
  });
}

// The darkroom peer-delivery surface must not be reachable by a read-only
// credential, and must be tagged with its own resource rather than `system`.
//
// Live defect: the three `/api/darkroom/delivery/**` routes had no entry in
// `resourcePrefixKeys` and no explicit scope rule, so `resourceKeyForEndpoint`
// fell through to `system` and the scope fell through to the method default —
// GET -> view. Reproduced against the release bundle on port 8303: a
// view-scoped token reached BOTH GET handlers (they answered 404
// `unknown_delivery_peer` from the handler's own business logic, not a 403
// naming a capability), meaning a read-only credential could stream every
// published master byte-for-byte on a rig that had a peer configured.
//
// These assertions go over real HTTP through the real auth middleware, so they
// classify by refusal BODY (which names the missing capability) rather than by
// status code.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import 'handler_test_helpers.dart';

class _Reply {
  final int statusCode;
  final Map<String, dynamic> body;

  const _Reply(this.statusCode, this.body);

  /// True when this is a scope refusal — decided by the body naming the
  /// missing capability, never by the status code alone.
  bool get isScopeRefusal => body.containsKey('requiredResource');
}

Future<_Reply> _get(
  HttpClient client,
  Uri baseUri,
  String path, {
  required String token,
}) async {
  final request = await client.getUrl(baseUri.resolve(path));
  request.headers.set('Authorization', 'Bearer $token');
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  final decoded = text.isEmpty ? const {} : jsonDecode(text);
  return _Reply(
    response.statusCode,
    decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
  );
}

void main() {
  const manifest = '/api/darkroom/delivery/manifest/1?peer=office-pc';
  const artifact = '/api/darkroom/delivery/artifact/1/abc?peer=office-pc';

  late ProviderContainer container;
  late HeadlessApiServer server;
  late HttpClient client;
  late Uri baseUri;

  setUp(() async {
    container = createHeadlessTestContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '7.0.0', buildNumber: 1),
        ),
      ],
    );
    server = HeadlessApiServer(
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: 'admin-token',
      scopedAuthTokens: const {
        'view-token': HeadlessTokenScope.view,
        'control-token': HeadlessTokenScope.control,
      },
      fineGrainedAuthTokens: {
        // A token that holds `system` and nothing else. Before the fix this
        // reached the delivery surface, because the surface WAS `system`.
        'system-only-token': HeadlessAuthGrant.forResources(const {
          HeadlessResource.system: HeadlessAccessLevel.control,
        }),
        // A token scoped to exactly the surface it is meant to use.
        'darkroom-token': HeadlessAuthGrant.forResources(const {
          HeadlessResource.darkroom: HeadlessAccessLevel.control,
        }),
      },
    );
    await server.start();
    client = HttpClient();
    baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    container.dispose();
  });

  test(
    'a view-scoped credential is refused the manifest and the bytes',
    () async {
      for (final path in const [manifest, artifact]) {
        final reply = await _get(client, baseUri, path, token: 'view-token');
        expect(
          reply.isScopeRefusal,
          isTrue,
          reason:
              'GET $path answered ${reply.statusCode} ${reply.body} to a '
              'read-only credential without naming a missing capability, i.e. '
              'it reached the handler',
        );
        expect(reply.body['requiredResource'], 'darkroom');
        expect(reply.body['requiredLevel'], 'control');
      }
    },
  );

  test('a control credential still reaches the handler', () async {
    // The paired desktop collecting its night. It must NOT be refused on
    // scope — it gets the handler's own 404 because this fixture has no peer
    // destination configured.
    final reply = await _get(client, baseUri, manifest, token: 'control-token');
    expect(
      reply.isScopeRefusal,
      isFalse,
      reason: 'a control credential must still be able to collect a night',
    );
    expect(reply.body['error'], 'unknown_delivery_peer');
  });

  test(
    'a fine-grained system token no longer reaches the delivery surface',
    () async {
      final reply = await _get(
        client,
        baseUri,
        manifest,
        token: 'system-only-token',
      );
      expect(reply.isScopeRefusal, isTrue);
      expect(reply.body['requiredResource'], 'darkroom');
    },
  );

  test(
    'a fine-grained darkroom token reaches it without holding system',
    () async {
      final reply = await _get(
        client,
        baseUri,
        manifest,
        token: 'darkroom-token',
      );
      expect(
        reply.isScopeRefusal,
        isFalse,
        reason: 'darkroom:control must be sufficient on its own',
      );
      expect(reply.body['error'], 'unknown_delivery_peer');
    },
  );
}

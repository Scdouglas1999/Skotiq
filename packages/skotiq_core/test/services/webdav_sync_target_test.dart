// Cloud backup/sync — WebDAV client unit tests against a fake HTTP layer.
//
// Verifies request shape (method, URL encoding, Depth header, body),
// the Basic-auth header, multistatus parsing, and the HTTP-status ->
// SyncTargetException error mapping. No network access: every request
// is served by `package:http/testing.dart`'s MockClient.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  final baseUrl = Uri.parse(
    'https://cloud.example.com/remote.php/dav/files/astro',
  );

  WebDavSyncTarget targetWith(MockClient client) => WebDavSyncTarget(
    baseUrl: baseUrl,
    username: 'astro',
    password: 's3cret!',
    client: client,
  );

  String expectedAuth() =>
      'Basic ${base64Encode(utf8.encode('astro:s3cret!'))}';

  group('request shape', () {
    test('uploadFile issues PUT with basic auth and body bytes', () async {
      http.Request? seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response('', 201);
      });

      await targetWith(
        client,
      ).uploadFile('skotiq-sync/my laptop/bundle-1.nsbak', [1, 2, 3]);

      expect(seen, isNotNull);
      expect(seen!.method, 'PUT');
      expect(seen!.headers['Authorization'], expectedAuth());
      expect(seen!.bodyBytes, [1, 2, 3]);
      // Each path segment is percent-encoded individually.
      expect(
        seen!.url.toString(),
        'https://cloud.example.com/remote.php/dav/files/astro/'
        'skotiq-sync/my%20laptop/bundle-1.nsbak',
      );
    });

    test(
      'listDirectory issues PROPFIND with Depth: 1 and trailing slash',
      () async {
        http.Request? seen;
        final client = MockClient((request) async {
          seen = request;
          return http.Response(_sampleMultistatus, 207);
        });

        await targetWith(client).listDirectory('skotiq-sync');

        expect(seen!.method, 'PROPFIND');
        expect(seen!.headers['Depth'], '1');
        expect(seen!.headers['Authorization'], expectedAuth());
        expect(seen!.body, contains('propfind'));
        expect(seen!.url.path, endsWith('/skotiq-sync/'));
      },
    );

    test(
      'ensureDirectory issues MKCOL per segment and tolerates 405',
      () async {
        final methods = <String>[];
        final paths = <String>[];
        final client = MockClient((request) async {
          methods.add(request.method);
          paths.add(request.url.path);
          // First segment "already exists", second is created.
          return http.Response('', paths.length == 1 ? 405 : 201);
        });

        await targetWith(client).ensureDirectory('skotiq-sync/obsy-pi');

        expect(methods, ['MKCOL', 'MKCOL']);
        expect(paths[0], endsWith('/skotiq-sync/'));
        expect(paths[1], endsWith('/skotiq-sync/obsy-pi/'));
      },
    );

    test(
      'ensureDirectory creates the base URL path when the server 409s',
      () async {
        // RFC 4918 §9.3.1: a spec-compliant server answers 409 Conflict when
        // MKCOL's parent collection is missing. The parent of the first
        // relative segment is the base URL's own path, so a base folder the
        // operator has not created by hand fails every push with "remote state
        // conflict (HTTP 409)" unless the ancestors are created first.
        final existing = <String>{
          '/',
          '/remote.php/',
          '/remote.php/dav/',
          '/remote.php/dav/files/',
        };
        final paths = <String>[];
        final client = MockClient((request) async {
          expect(request.method, 'MKCOL');
          final path = request.url.path;
          paths.add(path);
          final parent = path.substring(
            0,
            path.lastIndexOf('/', path.length - 2) + 1,
          );
          if (!existing.contains(parent)) return http.Response('', 409);
          if (existing.contains(path)) return http.Response('', 405);
          existing.add(path);
          return http.Response('', 201);
        });

        await targetWith(client).ensureDirectory('skotiq-sync/obsy-pi');

        // The 409 is recovered by creating /remote.php/dav/files/astro/ and
        // then retrying, rather than surfacing as a failed backup.
        expect(paths.first, endsWith('/astro/skotiq-sync/'));
        expect(paths, contains('/remote.php/dav/files/astro/'));
        expect(paths.last, endsWith('/astro/skotiq-sync/obsy-pi/'));
      },
    );

    test('downloadFile returns body bytes on 200', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        return http.Response.bytes([9, 8, 7], 200);
      });

      final bytes = await targetWith(
        client,
      ).downloadFile('skotiq-sync/m/f.nsbak');
      expect(bytes, [9, 8, 7]);
    });

    test('deleteFile treats 404 as a no-op', () async {
      final client = MockClient((request) async => http.Response('', 404));
      await targetWith(client).deleteFile('skotiq-sync/m/gone.nsbak');
    });
  });

  group('error mapping', () {
    Future<SyncTargetException> captureError(int status) async {
      final client = MockClient((request) async => http.Response('', status));
      try {
        await targetWith(client).downloadFile('x/y.nsbak');
        fail('expected SyncTargetException');
      } on SyncTargetException catch (e) {
        return e;
      }
    }

    test('401 maps to auth', () async {
      final e = await captureError(401);
      expect(e.kind, SyncTargetErrorKind.auth);
      expect(e.statusCode, 401);
      expect(e.message, contains('authentication failed'));
    });

    test('403 maps to auth', () async {
      expect((await captureError(403)).kind, SyncTargetErrorKind.auth);
    });

    test('404 maps to notFound', () async {
      expect((await captureError(404)).kind, SyncTargetErrorKind.notFound);
    });

    test('423 maps to conflict', () async {
      expect((await captureError(423)).kind, SyncTargetErrorKind.conflict);
    });

    test('503 maps to server', () async {
      final e = await captureError(503);
      expect(e.kind, SyncTargetErrorKind.server);
      expect(e.statusCode, 503);
    });

    test('client-level failure maps to network', () async {
      final client = MockClient((request) async {
        throw http.ClientException('connection refused');
      });
      expect(
        () => targetWith(client).downloadFile('x/y.nsbak'),
        throwsA(
          isA<SyncTargetException>().having(
            (e) => e.kind,
            'kind',
            SyncTargetErrorKind.network,
          ),
        ),
      );
    });
  });

  group('multistatus parsing', () {
    test('parses entries, skips self, decodes names and metadata', () async {
      final client = MockClient(
        (request) async => http.Response(_sampleMultistatus, 207),
      );

      final entries = await targetWith(client).listDirectory('skotiq-sync');

      expect(entries, hasLength(3));

      final dir = entries.firstWhere((e) => e.isDirectory);
      expect(dir.name, 'obsy-pi');

      final bundle = entries.firstWhere(
        (e) => e.name == 'bundle-2026-06-09.nsbak',
      );
      expect(bundle.isDirectory, isFalse);
      expect(bundle.sizeBytes, 4242);
      expect(bundle.modified, DateTime.utc(2026, 6, 9, 4, 30, 0));

      // Percent-encoded + XML-escaped name decodes cleanly.
      expect(entries.any((e) => e.name == 'a b&c.nsbak'), isTrue);
    });

    test('tolerates uppercase D: namespace prefix', () async {
      const body = '''<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/remote.php/dav/files/astro/skotiq-sync/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/remote.php/dav/files/astro/skotiq-sync/manifest.json</D:href>
    <D:propstat><D:prop>
      <D:resourcetype/><D:getcontentlength>17</D:getcontentlength>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>''';
      final client = MockClient((request) async => http.Response(body, 207));

      final entries = await targetWith(client).listDirectory('skotiq-sync');
      expect(entries, hasLength(1));
      expect(entries.single.name, 'manifest.json');
      expect(entries.single.isDirectory, isFalse);
      expect(entries.single.sizeBytes, 17);
    });
  });
}

/// Nextcloud-style multistatus: the listed directory itself (must be
/// skipped), a sub-collection, a bundle file with size + mtime, and a
/// file whose name needs percent-decoding and XML-unescaping.
const String _sampleMultistatus = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/astro/skotiq-sync/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/astro/skotiq-sync/obsy-pi/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/astro/skotiq-sync/bundle-2026-06-09.nsbak</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getcontentlength>4242</d:getcontentlength>
        <d:getlastmodified>Tue, 09 Jun 2026 04:30:00 GMT</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/astro/skotiq-sync/a%20b&amp;c.nsbak</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''';

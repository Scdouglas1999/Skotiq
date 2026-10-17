// Cloud backup/sync — S3 client unit tests against a fake HTTP layer.
//
// Verifies (1) AWS Signature Version 4 correctness against AWS's
// published "GET Object" example vector, (2) request shape (method,
// URL, query, x-amz-* headers, Authorization scope) for each verb via
// `package:http/testing.dart`'s MockClient, (3) list-objects-v2 XML
// parsing incl. continuation, (4) path-style vs virtual-host
// addressing, (5) the HTTP-status -> SyncTargetException mapping, and
// (6) that credentials never appear in thrown messages. No network.

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  final endpoint = Uri.parse('https://s3.us-east-1.amazonaws.com');

  S3SyncTarget targetWith(MockClient client, {bool pathStyle = false}) =>
      S3SyncTarget(
        endpoint: endpoint,
        region: 'us-east-1',
        bucket: 'astro-backups',
        accessKey: 'AKIAIOSFODNN7EXAMPLE',
        secretKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        pathStyle: pathStyle,
        client: client,
      );

  group('SigV4 — AWS published example vector (GET Object)', () {
    // https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
    test('matches AWS\'s documented signature', () {
      const emptyHash =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      final sig = S3SyncTarget.computeSigV4(
        method: 'GET',
        uri: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        headers: {
          'host': 'examplebucket.s3.amazonaws.com',
          'range': 'bytes=0-9',
          'x-amz-content-sha256': emptyHash,
          'x-amz-date': '20130524T000000Z',
        },
        payloadHash: emptyHash,
        accessKey: 'AKIAIOSFODNN7EXAMPLE',
        secretKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        region: 'us-east-1',
        time: DateTime.utc(2013, 5, 24),
      );

      expect(
        sig.signature,
        'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
      );
      expect(sig.signedHeaders, 'host;range;x-amz-content-sha256;x-amz-date');
      expect(sig.credentialScope, '20130524/us-east-1/s3/aws4_request');
      expect(
        sig.authorization,
        startsWith(
          'AWS4-HMAC-SHA256 '
          'Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request',
        ),
      );
      // Canonical request is locked to the AWS example byte-for-byte.
      expect(
        sig.canonicalRequest,
        'GET\n/test.txt\n\n'
        'host:examplebucket.s3.amazonaws.com\n'
        'range:bytes=0-9\n'
        'x-amz-content-sha256:$emptyHash\n'
        'x-amz-date:20130524T000000Z\n\n'
        'host;range;x-amz-content-sha256;x-amz-date\n'
        '$emptyHash',
      );
    });
  });

  group('request shape (virtual-host)', () {
    test('uploadFile PUTs with real payload hash and octet-stream', () async {
      http.Request? seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response('', 200);
      });

      await targetWith(
        client,
      ).uploadFile('skotiq-sync/laptop/b.skbak', [1, 2, 3]);

      expect(seen, isNotNull);
      expect(seen!.method, 'PUT');
      expect(seen!.url.scheme, 'https');
      expect(seen!.url.host, 'astro-backups.s3.us-east-1.amazonaws.com');
      expect(seen!.url.path, '/skotiq-sync/laptop/b.skbak');
      expect(seen!.bodyBytes, [1, 2, 3]);
      expect(seen!.headers['Content-Type'], 'application/octet-stream');
      // x-amz-content-sha256 is the real SHA-256 of the body (not UNSIGNED).
      expect(
        seen!.headers['x-amz-content-sha256'],
        sha256.convert([1, 2, 3]).toString(),
      );
      expect(seen!.headers['x-amz-date'], matches(r'^\d{8}T\d{6}Z$'));
      expect(
        seen!.headers['Authorization'],
        startsWith('AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/'),
      );
      expect(
        seen!.headers['Authorization'],
        contains('/us-east-1/s3/aws4_request'),
      );
    });

    test('downloadFile GETs and returns body bytes', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.host, 'astro-backups.s3.us-east-1.amazonaws.com');
        return http.Response.bytes([9, 8, 7], 200);
      });
      final bytes = await targetWith(client).downloadFile('s/f.skbak');
      expect(bytes, [9, 8, 7]);
    });

    test('deleteFile DELETEs and treats 404 as no-op', () async {
      final methods = <String>[];
      final client = MockClient((request) async {
        methods.add(request.method);
        return http.Response('', 404);
      });
      await targetWith(client).deleteFile('s/gone.skbak');
      expect(methods, ['DELETE']);
    });

    test('listDirectory GETs list-type=2 with prefix and delimiter', () async {
      http.Request? seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(_sampleList, 200);
      });

      await targetWith(client).listDirectory('skotiq-sync');

      expect(seen!.method, 'GET');
      expect(seen!.url.queryParameters['list-type'], '2');
      expect(seen!.url.queryParameters['delimiter'], '/');
      expect(seen!.url.queryParameters['prefix'], 'skotiq-sync/');
      expect(
        seen!.headers['x-amz-content-sha256'],
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('testConnection GETs list-type=2 with max-keys=0', () async {
      http.Request? seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(_emptyList, 200);
      });
      await targetWith(client).testConnection();
      expect(seen!.method, 'GET');
      expect(seen!.url.queryParameters['list-type'], '2');
      expect(seen!.url.queryParameters['max-keys'], '0');
    });

    test('ensureDirectory is a no-op (sends nothing)', () async {
      var hits = 0;
      final client = MockClient((request) async {
        hits++;
        return http.Response('', 200);
      });
      await targetWith(client).ensureDirectory('skotiq-sync/laptop');
      expect(hits, 0);
    });
  });

  group('path-style addressing (MinIO)', () {
    test('host stays the endpoint and bucket moves into the path', () async {
      http.Request? seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response('', 200);
      });

      await targetWith(client, pathStyle: true).uploadFile('sync/b.skbak', [1]);

      expect(seen!.url.host, 's3.us-east-1.amazonaws.com');
      expect(seen!.url.path, '/astro-backups/sync/b.skbak');
    });
  });

  group('list-objects-v2 parsing', () {
    test('maps Contents -> files and CommonPrefixes -> directories', () async {
      final client = MockClient(
        (request) async => http.Response(_sampleList, 200),
      );

      final entries = await targetWith(client).listDirectory('skotiq-sync');

      expect(entries, hasLength(3));

      final dir = entries.firstWhere((e) => e.isDirectory);
      expect(dir.name, 'obsy-pi');

      final bundle = entries.firstWhere(
        (e) => e.name == 'bundle-2026-06-09.skbak',
      );
      expect(bundle.isDirectory, isFalse);
      expect(bundle.sizeBytes, 4242);
      expect(bundle.modified, DateTime.utc(2026, 6, 9, 4, 30, 0));

      // The zero-byte prefix marker (Key == prefix) is skipped.
      expect(entries.any((e) => e.name == 'skotiq-sync'), isFalse);
    });

    test('follows NextContinuationToken across pages', () async {
      var calls = 0;
      final tokensSeen = <String?>[];
      final client = MockClient((request) async {
        calls++;
        tokensSeen.add(request.url.queryParameters['continuation-token']);
        return http.Response(calls == 1 ? _truncatedPage : _finalPage, 200);
      });

      final entries = await targetWith(client).listDirectory('skotiq-sync');

      expect(calls, 2);
      expect(tokensSeen, [null, 'TOKEN-2']);
      expect(entries.map((e) => e.name), ['page1.skbak', 'page2.skbak']);
    });
  });

  group('error mapping', () {
    Future<SyncTargetException> captureError(int status) async {
      final client = MockClient((request) async => http.Response('', status));
      try {
        await targetWith(client).downloadFile('x/y.skbak');
        fail('expected SyncTargetException');
      } on SyncTargetException catch (e) {
        return e;
      }
    }

    test('401 and 403 map to auth', () async {
      expect((await captureError(401)).kind, SyncTargetErrorKind.auth);
      expect((await captureError(403)).kind, SyncTargetErrorKind.auth);
    });

    test('404 maps to notFound', () async {
      expect((await captureError(404)).kind, SyncTargetErrorKind.notFound);
    });

    test('409 maps to conflict', () async {
      expect((await captureError(409)).kind, SyncTargetErrorKind.conflict);
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
      await expectLater(
        () => targetWith(client).downloadFile('x/y.skbak'),
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

  group('credential hygiene', () {
    test('thrown messages never contain the access key or secret', () async {
      final client = MockClient((request) async => http.Response('', 403));
      try {
        await targetWith(client).downloadFile('x/y.skbak');
        fail('expected SyncTargetException');
      } on SyncTargetException catch (e) {
        final text = e.toString();
        expect(text, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
        expect(text, isNot(contains('wJalrXUtnFEMI')));
      }
    });
  });
}

const String _sampleList = '''<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>astro-backups</Name>
  <Prefix>skotiq-sync/</Prefix>
  <Delimiter>/</Delimiter>
  <IsTruncated>false</IsTruncated>
  <Contents>
    <Key>skotiq-sync/</Key>
    <Size>0</Size>
  </Contents>
  <Contents>
    <Key>skotiq-sync/bundle-2026-06-09.skbak</Key>
    <LastModified>2026-06-09T04:30:00.000Z</LastModified>
    <Size>4242</Size>
    <ETag>"abc"</ETag>
  </Contents>
  <Contents>
    <Key>skotiq-sync/manifest.json</Key>
    <LastModified>2026-06-09T04:31:00.000Z</LastModified>
    <Size>17</Size>
  </Contents>
  <CommonPrefixes>
    <Prefix>skotiq-sync/obsy-pi/</Prefix>
  </CommonPrefixes>
</ListBucketResult>''';

const String _emptyList = '''<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>astro-backups</Name>
  <IsTruncated>false</IsTruncated>
</ListBucketResult>''';

const String _truncatedPage = '''<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>astro-backups</Name>
  <Prefix>skotiq-sync/</Prefix>
  <IsTruncated>true</IsTruncated>
  <NextContinuationToken>TOKEN-2</NextContinuationToken>
  <Contents>
    <Key>skotiq-sync/page1.skbak</Key>
    <Size>1</Size>
  </Contents>
</ListBucketResult>''';

const String _finalPage = '''<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>astro-backups</Name>
  <Prefix>skotiq-sync/</Prefix>
  <IsTruncated>false</IsTruncated>
  <Contents>
    <Key>skotiq-sync/page2.skbak</Key>
    <Size>2</Size>
  </Contents>
</ListBucketResult>''';

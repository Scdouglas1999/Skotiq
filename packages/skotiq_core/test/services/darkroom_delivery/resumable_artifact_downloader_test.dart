// The desktop's side of a pull: resume an interrupted transfer the way the
// imaging downloader does, and never let unverified bytes occupy the name the
// operator will open.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_failure.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/resumable_artifact_downloader.dart';
import 'package:path/path.dart' as p;

/// One scripted HTTP answer.
class _Answer {
  _Answer({
    required this.statusCode,
    this.body = const <int>[],
    this.headers = const <String, String>{},
    int? contentLength,
  }) : contentLength = contentLength ?? body.length;

  final int statusCode;
  final List<int> body;
  final Map<String, String> headers;
  final int contentLength;
}

class _FakeHttpClient implements ArtifactHttpClient {
  _FakeHttpClient(this.answers);

  final List<_Answer> answers;
  final List<Map<String, String>> requestHeaders = [];
  final List<Object?> postedBodies = [];
  int closes = 0;

  @override
  Future<ArtifactHttpResponse> get(Uri url, Map<String, String> headers) async {
    requestHeaders.add(Map<String, String>.from(headers));
    final answer = answers.removeAt(0);
    return ArtifactHttpResponse(
      statusCode: answer.statusCode,
      headers: answer.headers,
      body: Stream<List<int>>.fromIterable([answer.body]),
      contentLength: answer.contentLength,
    );
  }

  @override
  Future<ArtifactHttpResponse> postJson(
    Uri url,
    Map<String, String> headers,
    Object? body,
  ) async {
    postedBodies.add(body);
    final answer = answers.removeAt(0);
    return ArtifactHttpResponse(
      statusCode: answer.statusCode,
      headers: answer.headers,
      body: Stream<List<int>>.fromIterable([answer.body]),
      contentLength: answer.contentLength,
    );
  }

  @override
  void close() => closes++;
}

void main() {
  late Directory tempDir;
  final url = Uri.parse(
    'http://rig.local:8080/api/darkroom/delivery/artifact/1/aa',
  );
  final payload = utf8.encode('LINEAR-MASTER-BYTES-0123456789');
  final checksum = sha256.convert(payload).toString();
  const artifactId = 'aa';
  const etag = '"aa-1700000000000"';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns_download_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  String destinationPath() => p.join(tempDir.path, 'M31_Ha_master.fits');
  File partial() => File('${destinationPath()}$kArtifactDownloadPartSuffix');
  File sidecar() => File('${partial().path}$kArtifactDownloadSidecarSuffix');

  test('downloads, verifies, then renames onto the final name', () async {
    final http = _FakeHttpClient([
      _Answer(
        statusCode: 200,
        body: payload,
        headers: {'etag': etag, 'accept-ranges': 'bytes'},
      ),
    ]);

    final transferred = await ResumableArtifactDownloader(http).download(
      url: url,
      headers: const {'authorization': 'Bearer t'},
      artifactId: artifactId,
      destinationPath: destinationPath(),
      expectedChecksum: checksum,
    );

    expect(transferred, payload.length);
    expect(await File(destinationPath()).readAsBytes(), payload);
    expect(await partial().exists(), isFalse);
    expect(await sidecar().exists(), isFalse);
  });

  test('resumes a partial with Range and If-Range', () async {
    await partial().writeAsBytes(payload.sublist(0, 10));
    await sidecar().writeAsString(
      jsonEncode({
        'artifactId': artifactId,
        'etag': etag,
        'totalLength': payload.length,
      }),
    );
    final http = _FakeHttpClient([
      _Answer(
        statusCode: 206,
        body: payload.sublist(10),
        headers: {
          'etag': etag,
          'content-range': 'bytes 10-${payload.length - 1}/${payload.length}',
        },
      ),
    ]);

    final transferred = await ResumableArtifactDownloader(http).download(
      url: url,
      headers: const {},
      artifactId: artifactId,
      destinationPath: destinationPath(),
      expectedChecksum: checksum,
    );

    expect(transferred, payload.length - 10);
    expect(http.requestHeaders.single['range'], 'bytes=10-');
    expect(http.requestHeaders.single['if-range'], etag);
    expect(await File(destinationPath()).readAsBytes(), payload);
  });

  test('a 416 wipes the partial and starts over once', () async {
    await partial().writeAsBytes(payload.sublist(0, 10));
    await sidecar().writeAsString(
      jsonEncode({
        'artifactId': artifactId,
        'etag': etag,
        'totalLength': payload.length,
      }),
    );
    final http = _FakeHttpClient([
      _Answer(statusCode: 416),
      _Answer(statusCode: 200, body: payload, headers: {'etag': etag}),
    ]);

    await ResumableArtifactDownloader(http).download(
      url: url,
      headers: const {},
      artifactId: artifactId,
      destinationPath: destinationPath(),
      expectedChecksum: checksum,
    );

    expect(http.requestHeaders.length, 2);
    expect(http.requestHeaders.last.containsKey('range'), isFalse);
    expect(await File(destinationPath()).readAsBytes(), payload);
  });

  test('a partial the sidecar does not describe is restarted, not appended '
      'to', () async {
    await partial().writeAsBytes(utf8.encode('JUNK'));
    final http = _FakeHttpClient([
      _Answer(statusCode: 200, body: payload, headers: {'etag': etag}),
    ]);

    await ResumableArtifactDownloader(http).download(
      url: url,
      headers: const {},
      artifactId: artifactId,
      destinationPath: destinationPath(),
      expectedChecksum: checksum,
    );

    expect(http.requestHeaders.single.containsKey('range'), isFalse);
    expect(await File(destinationPath()).readAsBytes(), payload);
  });

  test('an ETag that changed during a resume is refused', () async {
    await partial().writeAsBytes(payload.sublist(0, 10));
    await sidecar().writeAsString(
      jsonEncode({
        'artifactId': artifactId,
        'etag': etag,
        'totalLength': payload.length,
      }),
    );
    final http = _FakeHttpClient([
      _Answer(
        statusCode: 206,
        body: payload.sublist(10),
        headers: {
          'etag': '"aa-1800000000000"',
          'content-range': 'bytes 10-${payload.length - 1}/${payload.length}',
        },
      ),
    ]);

    await expectLater(
      ResumableArtifactDownloader(http).download(
        url: url,
        headers: const {},
        artifactId: artifactId,
        destinationPath: destinationPath(),
        expectedChecksum: checksum,
      ),
      throwsA(isA<DeliveryFailure>()),
    );
    expect(await File(destinationPath()).exists(), isFalse);
  });

  test(
    'a Content-Range that does not continue the partial is refused',
    () async {
      await partial().writeAsBytes(payload.sublist(0, 10));
      await sidecar().writeAsString(
        jsonEncode({
          'artifactId': artifactId,
          'etag': etag,
          'totalLength': payload.length,
        }),
      );
      final http = _FakeHttpClient([
        _Answer(
          statusCode: 206,
          body: payload.sublist(10),
          headers: {
            'etag': etag,
            'content-range': 'bytes 5-${payload.length - 1}/${payload.length}',
          },
        ),
      ]);

      await expectLater(
        ResumableArtifactDownloader(http).download(
          url: url,
          headers: const {},
          artifactId: artifactId,
          destinationPath: destinationPath(),
          expectedChecksum: checksum,
        ),
        throwsA(isA<DeliveryFailure>()),
      );
    },
  );

  test(
    'bytes that do not hash to the manifest never take the final name',
    () async {
      final http = _FakeHttpClient([
        _Answer(
          statusCode: 200,
          body: utf8.encode('TRUNCATED'),
          headers: {'etag': etag},
        ),
      ]);

      await expectLater(
        ResumableArtifactDownloader(http).download(
          url: url,
          headers: const {},
          artifactId: artifactId,
          destinationPath: destinationPath(),
          expectedChecksum: checksum,
        ),
        throwsA(
          isA<DeliveryFailure>().having(
            (f) => f.kind,
            'kind',
            DeliveryFailureKind.checksumMismatch,
          ),
        ),
      );
      expect(await File(destinationPath()).exists(), isFalse);
      expect(await partial().exists(), isFalse);
      expect(await sidecar().exists(), isFalse);
    },
  );

  test('a body shorter than the Content-Length is refused', () async {
    final http = _FakeHttpClient([
      _Answer(
        statusCode: 200,
        body: payload.sublist(0, 5),
        headers: {'etag': etag},
        contentLength: payload.length,
      ),
    ]);

    await expectLater(
      ResumableArtifactDownloader(http).download(
        url: url,
        headers: const {},
        artifactId: artifactId,
        destinationPath: destinationPath(),
        expectedChecksum: checksum,
      ),
      throwsA(isA<DeliveryFailure>()),
    );
    expect(await File(destinationPath()).exists(), isFalse);
  });

  test('a partial that is already complete is verified without another '
      'request', () async {
    await partial().writeAsBytes(payload);
    await sidecar().writeAsString(
      jsonEncode({
        'artifactId': artifactId,
        'etag': etag,
        'totalLength': payload.length,
      }),
    );
    final http = _FakeHttpClient([]);

    final transferred = await ResumableArtifactDownloader(http).download(
      url: url,
      headers: const {},
      artifactId: artifactId,
      destinationPath: destinationPath(),
      expectedChecksum: checksum,
    );

    expect(transferred, 0);
    expect(http.requestHeaders, isEmpty);
    expect(await File(destinationPath()).readAsBytes(), payload);
  });

  test('an unauthorized answer is a credential failure, not a transport '
      'hiccup', () async {
    final http = _FakeHttpClient([
      _Answer(statusCode: 401, body: utf8.encode('{"error":"Unauthorized"}')),
    ]);

    await expectLater(
      ResumableArtifactDownloader(http).download(
        url: url,
        headers: const {},
        artifactId: artifactId,
        destinationPath: destinationPath(),
        expectedChecksum: checksum,
      ),
      throwsA(
        isA<DeliveryFailure>()
            .having(
              (f) => f.kind,
              'kind',
              DeliveryFailureKind.credentialMissing,
            )
            .having((f) => f.retryable, 'retryable', isFalse),
      ),
    );
  });

  test(
    'a 404 says the artifact is gone rather than blaming the network',
    () async {
      final http = _FakeHttpClient([
        _Answer(
          statusCode: 404,
          body: utf8.encode('{"error":"artifact_not_published"}'),
        ),
      ]);

      await expectLater(
        ResumableArtifactDownloader(http).download(
          url: url,
          headers: const {},
          artifactId: artifactId,
          destinationPath: destinationPath(),
          expectedChecksum: checksum,
        ),
        throwsA(
          isA<DeliveryFailure>().having(
            (f) => f.kind,
            'kind',
            DeliveryFailureKind.sourceMissing,
          ),
        ),
      );
    },
  );
}

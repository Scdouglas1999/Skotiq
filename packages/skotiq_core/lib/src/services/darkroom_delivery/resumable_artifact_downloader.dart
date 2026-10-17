/// Resumable, verified download of one published artifact.
///
/// The protocol is the one the imaging client already speaks to
/// `/api/images/<id>/download`: a `.skotiq-download` sidecar next to the
/// partial file recording the ETag and the total length, `Range` +
/// `If-Range` to resume, a 416 that wipes the partial and starts over once,
/// and a `Content-Range` that must agree with what was asked for. That client
/// is welded to `NetworkBackend` internals and to an image id, so this is the
/// same contract written against the delivery endpoints rather than a copy of
/// the code.
///
/// One thing is added: the bytes land under a staging name and are renamed
/// onto the final name only after their SHA-256 matches the manifest. A
/// partial download therefore never occupies the name the operator will open,
/// which is the same guarantee the rig-side transports give.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'delivery_artifact.dart';
import 'delivery_failure.dart';

/// Suffix of the partial file a download writes into.
const String kArtifactDownloadPartSuffix = '.nsdownload-part';

/// Suffix of the sidecar recording what the partial file is.
const String kArtifactDownloadSidecarSuffix = '.skotiq-download';

/// One HTTP response, as the downloader needs it.
class ArtifactHttpResponse {
  /// Status line code.
  final int statusCode;

  /// Response headers, lowercase keys.
  final Map<String, String> headers;

  /// Body bytes.
  final Stream<List<int>> body;

  /// `Content-Length`, or -1 when the server did not send one.
  final int contentLength;

  const ArtifactHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.contentLength,
  });
}

/// The HTTP the downloader speaks.
///
/// A seam so the resume, self-heal and verification paths are testable without
/// a server; production passes [IoArtifactHttpClient].
abstract class ArtifactHttpClient {
  /// Issue a GET and return the response with its body unread.
  Future<ArtifactHttpResponse> get(Uri url, Map<String, String> headers);

  /// Issue a POST with a JSON body and return the response.
  Future<ArtifactHttpResponse> postJson(
    Uri url,
    Map<String, String> headers,
    Object? body,
  );

  /// Release any connections held open.
  void close();
}

/// [ArtifactHttpClient] over `dart:io`.
class IoArtifactHttpClient implements ArtifactHttpClient {
  final HttpClient _client;

  IoArtifactHttpClient({HttpClient? client, Duration? connectionTimeout})
    : _client = client ?? HttpClient() {
    if (connectionTimeout != null) {
      _client.connectionTimeout = connectionTimeout;
    }
  }

  @override
  Future<ArtifactHttpResponse> get(Uri url, Map<String, String> headers) async {
    final request = await _client.getUrl(url);
    headers.forEach(request.headers.set);
    return _wrap(await request.close());
  }

  @override
  Future<ArtifactHttpResponse> postJson(
    Uri url,
    Map<String, String> headers,
    Object? body,
  ) async {
    final request = await _client.postUrl(url);
    headers.forEach(request.headers.set);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.write(jsonEncode(body));
    return _wrap(await request.close());
  }

  @override
  void close() => _client.close(force: true);

  ArtifactHttpResponse _wrap(HttpClientResponse response) {
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    return ArtifactHttpResponse(
      statusCode: response.statusCode,
      headers: headers,
      body: response,
      contentLength: response.contentLength,
    );
  }
}

/// What one artifact's sidecar records.
class ArtifactDownloadSidecar {
  /// The manifest id the partial belongs to.
  final String artifactId;

  /// The ETag the server served the partial under.
  final String etag;

  /// The full length of the resource.
  final int totalLength;

  const ArtifactDownloadSidecar({
    required this.artifactId,
    required this.etag,
    required this.totalLength,
  });

  /// The sidecar's JSON.
  Map<String, Object?> toJson() => <String, Object?>{
    'artifactId': artifactId,
    'etag': etag,
    'totalLength': totalLength,
  };

  /// Parse a sidecar, or null when it is absent or does not describe a
  /// resumable partial.
  static ArtifactDownloadSidecar? tryParse(String? raw) {
    if (raw == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // A sidecar that is not JSON describes nothing. The caller restarts the
      // download rather than resuming against a length it cannot read.
      return null;
    }
    if (decoded is! Map) return null;
    final artifactId = decoded['artifactId'];
    final etag = decoded['etag'];
    final totalLength = decoded['totalLength'];
    if (artifactId is! String || etag is! String || totalLength is! int) {
      return null;
    }
    if (artifactId.isEmpty || etag.isEmpty || totalLength <= 0) return null;
    return ArtifactDownloadSidecar(
      artifactId: artifactId,
      etag: etag,
      totalLength: totalLength,
    );
  }
}

/// Downloads one artifact, resuming an interrupted attempt and verifying the
/// result before it takes its final name.
class ResumableArtifactDownloader {
  final ArtifactHttpClient _http;

  ResumableArtifactDownloader(this._http);

  /// Fetch [url] into [destinationPath] and prove it hashes to
  /// [expectedChecksum].
  ///
  /// Returns the number of bytes that were transferred on this call, which is
  /// zero when a previous attempt had already finished the file.
  Future<int> download({
    required Uri url,
    required Map<String, String> headers,
    required String artifactId,
    required String destinationPath,
    required String expectedChecksum,
    void Function(int received, int total)? onProgress,
  }) async {
    final destination = File(destinationPath);
    await destination.parent.create(recursive: true);
    final partial = File('$destinationPath$kArtifactDownloadPartSuffix');
    final sidecar = File('${partial.path}$kArtifactDownloadSidecarSuffix');

    final transferred = await _attempt(
      url: url,
      headers: headers,
      artifactId: artifactId,
      partial: partial,
      sidecar: sidecar,
      onProgress: onProgress,
      mayRestart: true,
    );

    final landed = await sha256OfFile(partial);
    if (landed != expectedChecksum) {
      await _delete(partial);
      await _delete(sidecar);
      throw DeliveryFailure(
        DeliveryFailureKind.checksumMismatch,
        'The download of ${p.basename(destinationPath)} hashes to $landed, '
        'not $expectedChecksum; the partial was discarded',
      );
    }

    try {
      await partial.rename(destinationPath);
    } on FileSystemException catch (error) {
      throw DeliveryFailure(
        DeliveryFailureKind.transportFailure,
        'The verified download could not be renamed onto $destinationPath: '
        '${error.message}',
        cause: error,
      );
    }
    await _delete(sidecar);
    return transferred;
  }

  Future<int> _attempt({
    required Uri url,
    required Map<String, String> headers,
    required String artifactId,
    required File partial,
    required File sidecar,
    required void Function(int received, int total)? onProgress,
    required bool mayRestart,
  }) async {
    var resumeOffset = 0;
    ArtifactDownloadSidecar? state;

    if (await partial.exists()) {
      resumeOffset = await partial.length();
      state = ArtifactDownloadSidecar.tryParse(
        await sidecar.exists() ? await sidecar.readAsString() : null,
      );
      final canResume =
          resumeOffset > 0 &&
          state != null &&
          state.artifactId == artifactId &&
          resumeOffset <= state.totalLength;
      if (!canResume) {
        await _delete(partial);
        await _delete(sidecar);
        resumeOffset = 0;
        state = null;
      } else if (resumeOffset == state.totalLength) {
        onProgress?.call(resumeOffset, state.totalLength);
        return 0;
      }
    } else {
      await _delete(sidecar);
    }

    final requestHeaders = <String, String>{...headers};
    if (resumeOffset > 0 && state != null) {
      requestHeaders[HttpHeaders.rangeHeader] = 'bytes=$resumeOffset-';
      requestHeaders[HttpHeaders.ifRangeHeader] = state.etag;
    }

    final response = await _http.get(url, requestHeaders);
    final status = response.statusCode;

    if (status == HttpStatus.requestedRangeNotSatisfiable &&
        resumeOffset > 0 &&
        mayRestart) {
      await response.body.drain<void>();
      await _delete(partial);
      await _delete(sidecar);
      return _attempt(
        url: url,
        headers: headers,
        artifactId: artifactId,
        partial: partial,
        sidecar: sidecar,
        onProgress: onProgress,
        mayRestart: false,
      );
    }

    if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
      final body = await _readText(response);
      throw DeliveryFailure(
        _kindForStatus(status),
        'GET $url answered $status: ${body.isEmpty ? 'no body' : body}',
      );
    }

    final etag = response.headers[HttpHeaders.etagHeader]?.trim();
    final contentRange = response.headers['content-range'];
    final int totalLength;

    if (status == HttpStatus.partialContent) {
      if (resumeOffset == 0 || state == null) {
        await response.body.drain<void>();
        throw DeliveryFailure(
          DeliveryFailureKind.transportFailure,
          'GET $url answered 206 for a request that asked for the whole file',
        );
      }
      final range = _parseContentRange(contentRange, url);
      if (range.start != resumeOffset ||
          range.end < range.start ||
          range.end >= range.total ||
          range.total != state.totalLength) {
        await response.body.drain<void>();
        throw DeliveryFailure(
          DeliveryFailureKind.transportFailure,
          'GET $url answered a Content-Range of $contentRange, which does not '
          'continue the partial at byte $resumeOffset',
        );
      }
      if (etag == null || etag.isEmpty || etag != state.etag) {
        await response.body.drain<void>();
        throw DeliveryFailure(
          DeliveryFailureKind.transportFailure,
          'The artifact at $url changed while it was being resumed',
        );
      }
      totalLength = range.total;
    } else {
      if (contentRange != null) {
        await response.body.drain<void>();
        throw DeliveryFailure(
          DeliveryFailureKind.transportFailure,
          'GET $url answered 200 with a Content-Range header',
        );
      }
      if (response.contentLength <= 0) {
        await response.body.drain<void>();
        throw DeliveryFailure(
          DeliveryFailureKind.transportFailure,
          'GET $url answered 200 without a positive Content-Length',
        );
      }
      await _delete(partial);
      resumeOffset = 0;
      totalLength = response.contentLength;
    }

    if (etag != null && etag.isNotEmpty) {
      await sidecar.writeAsString(
        jsonEncode(
          ArtifactDownloadSidecar(
            artifactId: artifactId,
            etag: etag,
            totalLength: totalLength,
          ).toJson(),
        ),
      );
    }

    final sink = partial.openWrite(mode: FileMode.append);
    var received = resumeOffset;
    try {
      await for (final chunk in response.body) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, totalLength);
      }
    } finally {
      await sink.close();
    }

    if (received != totalLength) {
      throw DeliveryFailure(
        DeliveryFailureKind.transportFailure,
        'GET $url delivered $received of $totalLength bytes',
      );
    }
    return received - resumeOffset;
  }

  static DeliveryFailureKind _kindForStatus(int status) {
    if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
      return DeliveryFailureKind.credentialMissing;
    }
    if (status == HttpStatus.notFound) {
      return DeliveryFailureKind.sourceMissing;
    }
    return DeliveryFailureKind.transportFailure;
  }

  static ({int start, int end, int total}) _parseContentRange(
    String? header,
    Uri url,
  ) {
    final value = header?.trim();
    if (value == null) {
      throw DeliveryFailure(
        DeliveryFailureKind.transportFailure,
        'GET $url answered 206 with no Content-Range, so there is no way to '
        'know which bytes arrived',
      );
    }
    final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$').firstMatch(value);
    if (match == null) {
      throw DeliveryFailure(
        DeliveryFailureKind.transportFailure,
        'GET $url answered 206 with an unreadable Content-Range: $header',
      );
    }
    return (
      start: int.parse(match.group(1)!),
      end: int.parse(match.group(2)!),
      total: int.parse(match.group(3)!),
    );
  }

  static Future<String> _readText(ArtifactHttpResponse response) async {
    final buffer = StringBuffer();
    await for (final chunk in response.body) {
      buffer.write(utf8.decode(chunk, allowMalformed: true));
      if (buffer.length > 512) break;
    }
    return buffer.toString().trim();
  }

  static Future<void> _delete(File file) async {
    if (await file.exists()) await file.delete();
  }
}

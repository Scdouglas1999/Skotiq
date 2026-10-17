part of '../constellation_client.dart';

extension _ConstellationClientTransport on ConstellationClient {
  /// Resolve a `/v1`-rooted path (+ optional query) against [hubBaseUrl],
  /// preserving any path prefix the hub is mounted under.
  Uri _v1(String relPath, [Map<String, String>? query]) {
    final segments = <String>[
      ...hubBaseUrl.pathSegments.where((s) => s.isNotEmpty),
      'v1',
      ...relPath.split('/').where((s) => s.isNotEmpty),
    ];
    return hubBaseUrl.replace(
      pathSegments: segments,
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? bodyBytes,
  }) async {
    final request = http.Request(method, uri);
    request.headers.addAll(_authHeaders);
    if (headers != null) request.headers.addAll(headers);
    if (bodyBytes != null) request.bodyBytes = bodyBytes;
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      // Bound body collection too: `.timeout` on send() only covers receiving
      // the response headers, so a hub that sends headers then stalls mid-body
      // would hang here forever. These are small JSON receipts, so a single
      // request timeout on the whole exchange is appropriate.
      return await http.Response.fromStream(streamed).timeout(_timeout);
    } on ConstellationException {
      rethrow;
    } on SocketException catch (e) {
      throw ConstellationException(
        'Cannot reach ${uri.host}: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on http.ClientException catch (e) {
      throw ConstellationException(
        'Request to ${uri.host} failed: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on TimeoutException {
      throw ConstellationException(
        'Request to ${uri.host} timed out',
        kind: ConstellationErrorKind.network,
      );
    }
  }

  /// Stream a file's bytes as the request body (used for raw FITS subframes,
  /// which can be far larger than a sums delta). Mirrors [_send]'s error
  /// mapping but never holds the whole file in memory twice.
  Future<http.Response> _sendFile(
    String method,
    Uri uri,
    File file, {
    Map<String, String>? headers,
  }) async {
    final length = await file.length();
    final request = http.StreamedRequest(method, uri);
    request.headers.addAll(_authHeaders);
    if (headers != null) request.headers.addAll(headers);
    request.contentLength = length;
    // Pump the file into the request sink, then close it so the request body
    // terminates. Errors on the read side surface through the `send` future.
    unawaited(
      file
          .openRead()
          .forEach(request.sink.add)
          .whenComplete(request.sink.close),
    );
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      // Bound body collection too: `.timeout` on send() only covers receiving
      // the response headers, so a hub that sends headers then stalls mid-body
      // would hang here forever. These are small JSON receipts, so a single
      // request timeout on the whole exchange is appropriate.
      return await http.Response.fromStream(streamed).timeout(_timeout);
    } on ConstellationException {
      rethrow;
    } on SocketException catch (e) {
      throw ConstellationException(
        'Cannot reach ${uri.host}: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on http.ClientException catch (e) {
      throw ConstellationException(
        'Request to ${uri.host} failed: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on TimeoutException {
      throw ConstellationException(
        'Request to ${uri.host} timed out',
        kind: ConstellationErrorKind.network,
      );
    }
  }

  /// Stream a GET response body straight to [outPath] on disk, never
  /// materializing the whole blob in memory (the download mirror of [_sendFile]).
  /// Used for panel masters and the stitched mosaic output — the largest
  /// artifacts in the system, where buffering `response.bodyBytes` could approach
  /// a gigabyte on both ends. On a non-200 the (small) error body IS read so
  /// [_throwForStatus] can surface the hub's message. Returns [outPath].
  Future<String> _download(
    String method,
    Uri uri,
    String outPath,
    String operation,
  ) async {
    final request = http.Request(method, uri);
    request.headers.addAll(_authHeaders);
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      if (streamed.statusCode != 200) {
        _throwForStatus(await http.Response.fromStream(streamed), operation);
      }
      final out = File(outPath);
      await out.parent.create(recursive: true);
      final sink = out.openWrite();
      try {
        // Bound body collection too: `.timeout` on send() only covers receiving
        // the response headers, so a hub that sends headers then stalls
        // mid-body would hang here forever. These artifacts run to gigabytes,
        // so the bound is on the IDLE gap between chunks — a deadline on the
        // whole transfer would abort healthy slow links.
        await sink.addStream(streamed.stream.timeout(_timeout));
        await sink.close();
      } on Object {
        await _closeQuietly(sink);
        // Never leave a truncated artifact behind: neither a retry nor the
        // reader that opens it can tell a partial file from a complete one.
        await _deleteQuietly(out);
        rethrow;
      }
      return outPath;
    } on ConstellationException {
      rethrow;
    } on SocketException catch (e) {
      throw ConstellationException(
        'Cannot reach ${uri.host}: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on http.ClientException catch (e) {
      throw ConstellationException(
        'Request to ${uri.host} failed: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on TimeoutException {
      throw ConstellationException(
        'Request to ${uri.host} timed out',
        kind: ConstellationErrorKind.network,
      );
    }
  }

  Never _throwForStatus(http.Response response, String operation) {
    final status = response.statusCode;
    final kind = switch (status) {
      401 || 403 => ConstellationErrorKind.auth,
      404 => ConstellationErrorKind.notFound,
      // A 409 from the hub is a geometry/order mismatch — the tiling on this
      // hub does not match the local one, so the contribution can never fuse.
      409 => ConstellationErrorKind.geometryMismatch,
      405 || 423 => ConstellationErrorKind.conflict,
      // The hub rejected the REQUEST (bad params, an un-shareable license, a
      // malformed body). Classifying it `unknown` made every caller report the
      // appliance's own 5xx for a fault the caller must fix, inviting an
      // identical retry that can never succeed. Matches SharedCalibrationClient.
      400 || 422 => ConstellationErrorKind.protocol,
      >= 500 => ConstellationErrorKind.server,
      _ => ConstellationErrorKind.unknown,
    };
    final detail = switch (kind) {
      ConstellationErrorKind.auth =>
        'authentication failed — token missing the required scope',
      ConstellationErrorKind.notFound => 'not found on hub',
      ConstellationErrorKind.geometryMismatch =>
        'tile geometry/order mismatch (hub uses a different HEALPix tiling)',
      ConstellationErrorKind.conflict => 'hub state conflict',
      ConstellationErrorKind.server => 'hub server error',
      ConstellationErrorKind.protocol => 'the hub rejected this request',
      _ => 'unexpected hub response',
    };
    final body = response.body.trim();
    throw ConstellationException(
      '$operation failed: $detail (HTTP $status)'
      '${body.isEmpty ? '' : ' — $body'}',
      kind: kind,
      statusCode: status,
    );
  }

  Map<String, dynamic> _decodeJson(http.Response response, String operation) {
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw ConstellationException(
        '$operation returned malformed JSON: $e',
        kind: ConstellationErrorKind.protocol,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw ConstellationException(
        '$operation returned a non-object payload',
        kind: ConstellationErrorKind.protocol,
      );
    }
    return decoded;
  }

  bool _requireBool(Map<String, dynamic> body, String field, String operation) {
    final value = body[field];
    if (value is bool) return value;
    throw ConstellationException(
      '$operation returned a missing or non-boolean "$field" field',
      kind: ConstellationErrorKind.protocol,
    );
  }
}

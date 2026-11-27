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
  }) => _exchange.send(
    method,
    uri,
    headers: {..._authHeaders, ...?headers},
    body: bodyBytes,
  );

  /// Stream [file] as the request body (raw FITS subframes, panel masters,
  /// the mosaic output), never holding the whole file in memory.
  Future<http.Response> _sendFile(
    String method,
    Uri uri,
    File file, {
    Map<String, String>? headers,
  }) => _exchange.send(
    method,
    uri,
    headers: {..._authHeaders, ...?headers},
    file: file,
  );

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
    final streamed = await _exchange.open(method, uri, headers: _authHeaders);
    if (streamed.statusCode != 200) {
      _throwForStatus(await http.Response.fromStream(streamed), operation);
    }
    final out = File(outPath);
    await out.parent.create(recursive: true);
    final sink = out.openWrite();
    try {
      await sink.addStream(streamed.stream);
      await sink.close();
    } on Object {
      await _closeQuietly(sink);
      // Never leave a truncated artifact behind: neither a retry nor the
      // reader that opens it can tell a partial file from a complete one.
      await _deleteQuietly(out);
      rethrow;
    }
    return outPath;
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
      // malformed body): a fault the caller must fix, which an identical
      // retry can never get past.
      400 || 422 => ConstellationErrorKind.protocol,
      >= 500 => ConstellationErrorKind.server,
      _ => ConstellationErrorKind.unknown,
    };
    final detail = switch (kind) {
      ConstellationErrorKind.auth =>
        'authentication failed: token missing the required scope',
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
      '${body.isEmpty ? '' : ': $body'}',
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

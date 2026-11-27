// The HTTP side of every client of a Skotiq hub (`server/skotiq_hub/`): the
// `/v1` base path, the bearer token, bounded requests and downloads, and the
// one reading of the hub's HTTP status as a [ConstellationErrorKind].

import 'dart:convert';
import 'dart:io' show File, FileSystemException, IOSink, SocketException;

import 'package:http/http.dart' as http;

import '../http_exchange.dart';
import 'constellation_models.dart';

/// Requests to one hub as one account. Every request but [openUnbounded]
/// goes through one [HttpExchange], which turns a failure before an HTTP
/// status into a network [ConstellationException]; [throwForStatus] reads
/// the status.
class HubTransport {
  /// [client] is injectable for tests (`package:http/testing.dart`
  /// MockClient). When omitted a real client is created and owned here
  /// ([close] disposes it). A request fails when no bytes move for [timeout].
  HubTransport({
    required this.hubBaseUrl,
    required this.bearerToken,
    http.Client? client,
    Duration timeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null {
    _exchange = HttpExchange(
      _client,
      networkFailure: ConstellationException.network,
      idleLimit: timeout,
    );
  }

  /// Hub root, e.g. `https://hub.example.org` or `http://192.168.1.20:8088`.
  final Uri hubBaseUrl;

  final String bearerToken;

  final http.Client _client;
  final bool _ownsClient;
  late final HttpExchange _exchange;

  void close() {
    if (_ownsClient) _client.close();
  }

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer $bearerToken',
  };

  /// Resolve a `/v1`-rooted path (+ optional query) against [hubBaseUrl],
  /// preserving any path prefix the hub is mounted under.
  Uri v1(String relPath, [Map<String, String>? query]) {
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

  Future<http.Response> send(
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

  /// Stream [file] as the request body, never holding the whole file in
  /// memory.
  Future<http.Response> sendFile(
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

  /// Stream a response body straight to [outPath] on disk, never
  /// materializing the whole blob in memory (the download mirror of
  /// [sendFile]). On a non-200 the (small) error body IS read so
  /// [throwForStatus] can surface the hub's message. Returns [outPath].
  Future<String> download(
    String method,
    Uri uri,
    String outPath,
    String operation,
  ) async {
    final streamed = await _exchange.open(method, uri, headers: _authHeaders);
    if (streamed.statusCode != 200) {
      throwForStatus(await http.Response.fromStream(streamed), operation);
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

  /// Open a long-lived reply (an event stream) without the idle limit: the
  /// hub may stay quiet on it for as long as nothing happens.
  Future<http.StreamedResponse> openUnbounded(
    String method,
    Uri uri,
    String operation,
  ) async {
    final request = http.Request(method, uri)..headers.addAll(_authHeaders);
    try {
      return await _client.send(request);
    } on SocketException catch (e) {
      throw ConstellationException(
        'Cannot reach ${uri.host}: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on http.ClientException catch (e) {
      throw ConstellationException(
        '$operation failed: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    }
  }

  /// What a hub's HTTP [status] means to its clients.
  static ConstellationErrorKind kindForStatus(int status) => switch (status) {
    401 || 403 => ConstellationErrorKind.auth,
    404 => ConstellationErrorKind.notFound,
    // The tiling on this hub does not match the local one, so the
    // contribution can never fuse.
    409 => ConstellationErrorKind.geometryMismatch,
    405 || 423 => ConstellationErrorKind.conflict,
    // The hub rejected the REQUEST (bad params, an un-shareable license, a
    // malformed body, a master whose content it refuses): a fault the caller
    // must fix, which an identical retry can never get past.
    400 || 422 => ConstellationErrorKind.protocol,
    >= 500 => ConstellationErrorKind.server,
    _ => ConstellationErrorKind.unknown,
  };

  Never throwForStatus(http.Response response, String operation) {
    final status = response.statusCode;
    final kind = kindForStatus(status);
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

  Map<String, dynamic> decodeJson(http.Response response, String operation) {
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

  bool requireBool(Map<String, dynamic> body, String field, String operation) {
    final value = body[field];
    if (value is bool) return value;
    throw ConstellationException(
      '$operation returned a missing or non-boolean "$field" field',
      kind: ConstellationErrorKind.protocol,
    );
  }
}

/// Close [sink] while already unwinding a download failure: the stream
/// consumer has usually torn the file handle down itself, and a secondary
/// close error must not mask the real cause.
Future<void> _closeQuietly(IOSink sink) async {
  try {
    await sink.close();
  } on Object {
    // Already failing; the original error is the one worth reporting.
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Best-effort cleanup; the caller's error still propagates.
  }
}

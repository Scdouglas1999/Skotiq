import 'dart:async';
import 'dart:io' show File, SocketException;

import 'package:http/http.dart' as http;

/// One HTTP request and its reply for the remote clients (cloud sync, the
/// hub, the shared calibration library): the request goes out, the reply
/// comes back, and a failure before an HTTP status arrived is handed to
/// [networkFailure] with a sentence naming the host.
///
/// [headerDeadline] bounds the wait from sending the request to the reply's
/// headers, which includes sending the request body; [bodyDeadline] bounds
/// collecting the reply's body. Null leaves that wait unbounded.
class HttpExchange {
  HttpExchange(
    this._client, {
    required Exception Function(String message) networkFailure,
    Duration? headerDeadline,
    Duration? bodyDeadline,
  }) : _networkFailure = networkFailure,
       _headerDeadline = headerDeadline,
       _bodyDeadline = bodyDeadline;

  final http.Client _client;
  final Exception Function(String message) _networkFailure;
  final Duration? _headerDeadline;
  final Duration? _bodyDeadline;

  /// The request body goes to the socket in slices of this size, so a slow
  /// link moves it piece by piece.
  static const int _sliceBytes = 64 * 1024;

  /// Send [method] [uri] with [headers] and at most one of [body] or [file]
  /// as the request body, and read the whole reply.
  Future<http.Response> send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? body,
    File? file,
  }) async {
    try {
      final streamed = await _start(
        method,
        uri,
        headers: headers,
        body: body,
        file: file,
      );
      return await _within(http.Response.fromStream(streamed), _bodyDeadline);
    } on Object catch (error) {
      final mapped = _mapped(error, uri);
      if (mapped == null) rethrow;
      throw mapped;
    }
  }

  /// Send a bodyless [method] [uri] and return the reply as soon as its
  /// headers arrive. A network failure while its body streams reaches the
  /// stream's listener as the same [networkFailure].
  Future<http.StreamedResponse> open(
    String method,
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final http.StreamedResponse streamed;
    try {
      streamed = await _start(method, uri, headers: headers);
    } on Object catch (error) {
      final mapped = _mapped(error, uri);
      if (mapped == null) rethrow;
      throw mapped;
    }
    return http.StreamedResponse(
      streamed.stream.handleError(
        (Object error) => throw _mapped(error, uri)!,
        test: (error) => _mapped(error, uri) != null,
      ),
      streamed.statusCode,
      contentLength: streamed.contentLength,
      request: streamed.request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  Future<http.StreamedResponse> _start(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? body,
    File? file,
  }) async {
    assert(body == null || file == null, 'one request body at most');
    final request = http.StreamedRequest(method, uri);
    if (headers != null) request.headers.addAll(headers);
    final Stream<List<int>> content;
    if (file != null) {
      request.contentLength = await file.length();
      content = file.openRead();
    } else {
      final bytes = body ?? const <int>[];
      request.contentLength = bytes.length;
      content = _slices(bytes);
    }
    unawaited(
      request.sink
          .addStream(content)
          .then((_) {}, onError: request.sink.addError)
          .whenComplete(request.sink.close),
    );
    return _within(_client.send(request), _headerDeadline);
  }

  static Stream<List<int>> _slices(List<int> bytes) async* {
    for (var start = 0; start < bytes.length; start += _sliceBytes) {
      final end = start + _sliceBytes < bytes.length
          ? start + _sliceBytes
          : bytes.length;
      yield bytes.sublist(start, end);
    }
  }

  static Future<T> _within<T>(Future<T> future, Duration? deadline) =>
      deadline == null ? future : future.timeout(deadline);

  Exception? _mapped(Object error, Uri uri) => switch (error) {
    SocketException(:final message) => _networkFailure(
      'Cannot reach ${uri.host}: $message',
    ),
    http.ClientException(:final message) => _networkFailure(
      'Request to ${uri.host} failed: $message',
    ),
    TimeoutException() => _networkFailure('Request to ${uri.host} timed out'),
    _ => null,
  };
}

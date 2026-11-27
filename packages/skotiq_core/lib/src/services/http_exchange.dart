import 'dart:async';
import 'dart:io' show File, SocketException;

import 'package:http/http.dart' as http;

/// One HTTP request and its reply for the remote clients (cloud sync, the
/// hub, the shared calibration library): the request goes out, the reply
/// comes back, and a failure before an HTTP status arrived is handed to
/// [networkFailure] with a sentence naming the host.
///
/// The exchange gives up when no bytes move for [idleLimit]: not while the
/// request body goes out, not while the server works on its reply, not
/// between chunks of the reply's body. A slow link that keeps moving is never
/// cut off, however long the whole transfer takes.
class HttpExchange {
  HttpExchange(
    this._client, {
    required Exception Function(String message) networkFailure,
    required Duration idleLimit,
  }) : _networkFailure = networkFailure,
       _idleLimit = idleLimit;

  final http.Client _client;
  final Exception Function(String message) _networkFailure;
  final Duration _idleLimit;

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
  }) async => http.Response.fromStream(
    await open(method, uri, headers: headers, body: body, file: file),
  );

  /// Send the request as [send] does and return the reply as soon as its
  /// headers arrive. A network failure or an idle body reaches the stream's
  /// listener as the same [networkFailure].
  Future<http.StreamedResponse> open(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? body,
    File? file,
  }) async {
    assert(body == null || file == null, 'one request body at most');
    final watch = _IdleWatch(_idleLimit);
    final Stream<List<int>> content;
    final int length;
    if (file != null) {
      length = await file.length();
      content = file.openRead();
    } else {
      final bytes = body ?? const <int>[];
      length = bytes.length;
      content = _slices(bytes);
    }
    final request = _BodyRequest(
      method,
      uri,
      content.map((chunk) {
        watch.touch();
        return chunk;
      }),
      abortTrigger: watch.expired,
    )..contentLength = length;
    if (headers != null) request.headers.addAll(headers);

    final http.StreamedResponse streamed;
    try {
      streamed = await Future.any([
        _client.send(request),
        watch.expired.then<http.StreamedResponse>(
          (_) => throw TimeoutException(null, _idleLimit),
        ),
      ]);
    } on Object catch (error) {
      watch.stop();
      final mapped = _mapped(error, uri, watch);
      if (mapped == null) rethrow;
      throw mapped;
    }
    watch.touch();
    return http.StreamedResponse(
      _watched(streamed.stream, uri, watch),
      streamed.statusCode,
      contentLength: streamed.contentLength,
      request: streamed.request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  /// [source] with every chunk keeping [watch] awake, its network failures
  /// mapped, and an idle gap ending it with the timeout failure. A paused
  /// listener holds the watch: its own slowness is not the link's.
  Stream<List<int>> _watched(
    Stream<List<int>> source,
    Uri uri,
    _IdleWatch watch,
  ) {
    late final StreamController<List<int>> out;
    StreamSubscription<List<int>>? sub;
    void finish() {
      watch.stop();
      if (!out.isClosed) unawaited(out.close());
    }

    out = StreamController<List<int>>(
      onListen: () {
        sub = source.listen(
          (chunk) {
            watch.touch();
            out.add(chunk);
          },
          onError: (Object error, StackTrace stack) {
            if (out.isClosed) return;
            out.addError(_mapped(error, uri, watch) ?? error, stack);
          },
          onDone: finish,
        );
        unawaited(
          watch.expired.then((_) {
            if (out.isClosed) return;
            out.addError(_mapped(TimeoutException(null), uri, watch)!);
            finish();
            unawaited(sub?.cancel());
          }),
        );
      },
      onPause: () {
        sub?.pause();
        watch.hold();
      },
      onResume: () {
        sub?.resume();
        watch.touch();
      },
      onCancel: () {
        watch.stop();
        return sub?.cancel();
      },
    );
    return out.stream;
  }

  static Stream<List<int>> _slices(List<int> bytes) async* {
    for (var start = 0; start < bytes.length; start += _sliceBytes) {
      final end = start + _sliceBytes < bytes.length
          ? start + _sliceBytes
          : bytes.length;
      yield bytes.sublist(start, end);
    }
  }

  /// The network failure [error] stands for, or null when it is not one. An
  /// abort the idle watch caused reads as the timeout it is.
  Exception? _mapped(Object error, Uri uri, _IdleWatch watch) {
    if (watch.hasExpired &&
        (error is TimeoutException || error is http.ClientException)) {
      return _networkFailure('Request to ${uri.host} timed out');
    }
    return switch (error) {
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
}

/// A request whose body is [_body], read only when the transport takes it:
/// a request that fails before it is sent never opens its file.
final class _BodyRequest extends http.BaseRequest with http.Abortable {
  _BodyRequest(super.method, super.url, this._body, {this.abortTrigger});

  final Stream<List<int>> _body;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}

/// Completes [expired] once [touch] has not been called for the limit.
class _IdleWatch {
  _IdleWatch(this._limit) {
    touch();
  }

  final Duration _limit;
  final Completer<void> _expired = Completer<void>();
  Timer? _timer;

  Future<void> get expired => _expired.future;

  bool get hasExpired => _expired.isCompleted;

  /// Bytes moved: the idle gap starts again.
  void touch() {
    if (hasExpired) return;
    _timer?.cancel();
    _timer = Timer(_limit, _expired.complete);
  }

  /// Nothing is owed by the link until the next [touch].
  void hold() => _timer?.cancel();

  /// The exchange is over.
  void stop() => _timer?.cancel();
}

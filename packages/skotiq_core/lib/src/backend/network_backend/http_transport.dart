part of '../network_backend.dart';

extension _NetworkBackendHttpTransport on _NetworkBackendTransport {
  String _nextRequestId(String endpoint) {
    _requestCounter = (_requestCounter + 1) % 0xFFFFF;
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final seq = _requestCounter.toRadixString(36);
    final safeEndpoint = endpoint
        .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '')
        .toLowerCase();
    return 'nb-$ts-$seq-${safeEndpoint.isEmpty ? 'request' : safeEndpoint}';
  }

  /// Add authentication, compatibility, and trace headers to HTTP requests.
  Map<String, String> _addAuthHeaders(
    Map<String, String> headers, {
    required String endpoint,
  }) {
    headers[RemoteApiCompatibility.apiVersionHeader] = RemoteApiCompatibility
        .clientApiVersion
        .format();
    headers[_NetworkBackendTransport._requestIdHeader] = _nextRequestId(
      endpoint,
    );
    if (authToken != null && authToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }
    return headers;
  }

  Map<String, String> _buildRequestHeaders(
    String endpoint, {
    bool jsonContent = false,
    Map<String, String>? extraHeaders,
  }) {
    final headers = _addAuthHeaders({}, endpoint: endpoint);
    if (jsonContent) {
      headers[HttpHeaders.contentTypeHeader] = 'application/json';
    }
    if (extraHeaders != null && extraHeaders.isNotEmpty) {
      headers.addAll(extraHeaders);
    }
    return headers;
  }

  Future<http.Response> _sendWithAuthRefresh({
    required String endpoint,
    required Future<http.Response> Function(Map<String, String> headers) send,
    bool jsonContent = false,
    Map<String, String>? extraHeaders,
  }) async {
    var headers = _buildRequestHeaders(
      endpoint,
      jsonContent: jsonContent,
      extraHeaders: extraHeaders,
    );
    final response = await send(headers);
    if (response.statusCode != 401 || refreshAuthToken == null) {
      return response;
    }

    final previousToken = authToken;
    final refreshedToken = await refreshAuthToken!();
    if (refreshedToken == null ||
        refreshedToken.isEmpty ||
        refreshedToken == previousToken) {
      return response;
    }

    authToken = refreshedToken;
    // New credentials invalidate a previously-latched auth rejection — the
    // host rejected the OLD token, not this one, so let requests (and the
    // next WS connect) actually reach the wire.
    _rejectedAuthToken = null;
    _authRejected = false;
    headers = _buildRequestHeaders(
      endpoint,
      jsonContent: jsonContent,
      extraHeaders: extraHeaders,
    );
    return send(headers);
  }

  /// Open a streaming GET with the same authentication and compatibility
  /// contract as the package:http JSON helpers.
  ///
  /// Binary endpoints use dart:io's [HttpClient] so their response can be
  /// streamed directly to disk. Keeping the header/refresh logic here avoids
  /// those endpoints quietly becoming unauthenticated when host auth is on.
  Future<HttpClientResponse> _openRawGetWithAuthRefresh(
    String endpoint, {
    Map<String, String>? extraHeaders,
  }) async {
    Future<HttpClientResponse> send() async {
      final request = await _httpClient.getUrl(_apiUri(endpoint));
      final headers = _buildRequestHeaders(
        endpoint,
        extraHeaders: extraHeaders,
      );
      headers.forEach(request.headers.set);
      return request.close();
    }

    final response = await send();
    if (response.statusCode != HttpStatus.unauthorized ||
        refreshAuthToken == null) {
      return response;
    }

    final previousToken = authToken;
    final String? refreshedToken;
    try {
      refreshedToken = await refreshAuthToken!();
    } catch (_) {
      await response.drain<void>();
      rethrow;
    }
    if (refreshedToken == null ||
        refreshedToken.isEmpty ||
        refreshedToken == previousToken) {
      return response;
    }

    await response.drain<void>();
    authToken = refreshedToken;
    _rejectedAuthToken = null;
    _authRejected = false;
    return send();
  }

  bool _isTransientFailure(Object error) {
    if (error is dart_error.SkotiqError) {
      return error.isRecoverable;
    }
    if (error is ServerError) {
      final status = error.httpStatus;
      return status != null && _isTransientStatusCode(status);
    }
    if (error is SocketException) {
      return true;
    }
    if (error is TimeoutException) {
      return true;
    }
    if (error is HttpException) {
      // Connection reset, broken pipe, etc.
      return true;
    }
    if (error is Exception) {
      final errorStr = error.toString().toLowerCase();
      if (errorStr.contains('connection') ||
          errorStr.contains('timeout') ||
          errorStr.contains('reset') ||
          errorStr.contains('refused') ||
          errorStr.contains('network')) {
        return true;
      }
    }
    return false;
  }

  bool _isTransientStatusCode(int statusCode) {
    // 408 Request Timeout, 429 Too Many Requests, 500 Internal Server Error,
    // 502 Bad Gateway, 503 Service Unavailable, 504 Gateway Timeout
    return statusCode == 408 || statusCode == 429 || statusCode >= 500;
  }

  /// The failure a non-success response stands for: the host's error body
  /// when it sent one, otherwise the status alone.
  ///
  /// A 403 for a token the host does not know also latches the rejection, so
  /// [_retryableRequest] fails fast and [_connect] stops retrying instead of
  /// running the host's per-address auth-failure limiter into a lockout. A
  /// scope or session-ownership 403 does not: that token is still good for
  /// what it covers.
  ServerError _parseErrorResponse(
    int statusCode,
    String responseBody,
    String method,
    String endpoint,
  ) {
    final body = _errorBody(statusCode, responseBody);
    if (statusCode == HttpStatus.forbidden &&
        body?.message == ApiErrorBody.invalidTokenMessage) {
      _latchAuthRejection('$method $endpoint');
    }
    return ServerError(
      code: body?.code ?? ApiErrorBody.codeForStatus(statusCode),
      message: body?.message ?? 'HTTP $statusCode: $method $endpoint failed',
      httpStatus: statusCode,
      details: body?.details?.cast<String, dynamic>(),
    );
  }

  /// Null for a body that is not the host's: a proxy's HTML page, plain
  /// text, nothing at all.
  ApiErrorBody? _errorBody(int statusCode, String responseBody) {
    final Object? json;
    try {
      json = jsonDecode(responseBody);
    } on FormatException {
      return null;
    }
    return json is Map<String, dynamic>
        ? ApiErrorBody.tryParse(json, httpStatus: statusCode)
        : null;
  }

  /// Longest a mutating request may keep retrying after its first attempt.
  /// A device command delivered later than this would act on a rig the user
  /// no longer sees in the state they issued it from.
  static const Duration _mutatingRetryWindow = Duration(seconds: 5);

  /// True when [error] shows the request never reached the host: the
  /// connection itself was refused or the host could not be found or routed
  /// to. Anything else (timeout, reset, 5xx) may have been delivered.
  bool _failedBeforeDelivery(Object error) {
    if (error is SocketException) {
      const refusedOrUnreachable = {111, 113, 101, 10061, 10065, 10051};
      final code = error.osError?.errorCode;
      if (code != null && refusedOrUnreachable.contains(code)) return true;
    }
    if (error is SocketException || error is http.ClientException) {
      final message = error.toString().toLowerCase();
      return message.contains('connection refused') ||
          message.contains('failed host lookup') ||
          message.contains('no route to host') ||
          message.contains('network is unreachable');
    }
    return false;
  }

  /// Retry a request with exponential backoff, at most [maxAttempts] times and
  /// only for transient failures.
  ///
  /// A [mutating] request (POST, DELETE) changes host state, so it is retried
  /// only when the failed attempt provably never reached the host, and only
  /// within [_mutatingRetryWindow] of the first attempt. A timed-out or
  /// failed command is never sent again later.
  Future<T> _retryableRequest<T>(
    Future<T> Function() request, {
    int maxAttempts = 3,
    Duration? timeout,
    bool mutating = false,
  }) async {
    // Fail fast once the host has definitively rejected this exact token:
    // every call would 403 anyway, and each attempt feeds the server's
    // per-IP auth-failure counter toward a `429` lockout. Throwing locally
    // keeps the failure visible to the caller without the wire traffic.
    // Equality (not just non-null) is the gate so a swapped-in replacement
    // token is allowed through.
    final rejected = _rejectedAuthToken;
    if (rejected != null && rejected == authToken) {
      throw const ServerError(
        code: 'invalid_auth_token',
        message:
            'Access denied: Invalid authentication token (not retried — '
            'the host rejected this token)',
        httpStatus: HttpStatus.forbidden,
      );
    }

    // Null `timeout` defers to the host-tuned [requestTimeout] (30 s on LAN,
    // 60 s on a tailnet). Callers that pass an explicit value override the
    // tuning.
    final effectiveTimeout = timeout ?? requestTimeout;
    final firstAttempt = Stopwatch()..start();
    int attempt = 0;
    Object? lastError;
    StackTrace? lastStackTrace;

    while (attempt < maxAttempts) {
      try {
        return await request().timeout(effectiveTimeout);
      } catch (e, stackTrace) {
        lastError = e;
        lastStackTrace = stackTrace;
        attempt++;

        if (attempt >= maxAttempts) {
          Log.error(
            '[NetworkBackend] Request failed after $maxAttempts attempts: $e',
            source: 'NetworkBackend',
            error: e,
          );
          rethrow;
        }

        if (mutating &&
            (!_failedBeforeDelivery(e) ||
                firstAttempt.elapsed >= _mutatingRetryWindow)) {
          rethrow;
        }

        if (!_isTransientFailure(e)) {
          Log.error(
            '[NetworkBackend] Non-transient failure, not retrying: $e',
            source: 'NetworkBackend',
            error: e,
          );
          rethrow;
        }

        // Calculate backoff delay: 1s, 2s, 4s
        final delay = Duration(seconds: 1 << (attempt - 1));
        Log.warning(
          '[NetworkBackend] Transient failure, retrying in ${delay.inSeconds}s (attempt $attempt/$maxAttempts): $e',
          source: 'NetworkBackend',
          error: e,
        );
        await Future.delayed(delay);
      }
    }

    // The loop always returns or rethrows. Preserve any non-Exception Error as
    // well if that invariant changes, rather than masking it with a type cast.
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  /// The request path of [endpoint] below `/api/`, with its `<name>`
  /// parameters taken from [path]. [sends] is the verb the calling helper
  /// puts on the wire.
  String _endpointPath(
    ApiEndpoint endpoint,
    ApiMethod sends, [
    Map<String, Object> path = const {},
  ]) {
    final route = endpoint.route;
    if (route.method != sends) {
      throw StateError('${route.signature} is not sent as ${sends.wireName}');
    }
    final filled = route.fill(path);
    if (!filled.startsWith(_NetworkBackendTransport._apiPrefix)) {
      throw StateError('${route.signature} is not an API route');
    }
    return filled.substring(_NetworkBackendTransport._apiPrefix.length);
  }

  Map<String, String>? _queryStrings(Map<String, dynamic>? query) =>
      query?.map((key, value) => MapEntry(key, value.toString()));

  Future<Map<String, dynamic>> _get(
    ApiEndpoint endpoint, {
    Map<String, Object> path = const {},
    Map<String, dynamic>? query,
  }) async {
    final target = _endpointPath(endpoint, ApiMethod.get, path);
    return _retryableRequest(() async {
      final uri = _apiUri(target, _queryStrings(query));

      final response = await _sendWithAuthRefresh(
        endpoint: target,
        send: (headers) => _http.get(uri, headers: headers),
      );

      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'GET',
          target,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    });
  }

  Future<Map<String, dynamic>> _post(
    ApiEndpoint endpoint, {
    Map<String, Object> path = const {},
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    int maxAttempts = 3,
    Duration? timeout,
  }) async {
    final target = _endpointPath(endpoint, ApiMethod.post, path);
    return _retryableRequest(
      maxAttempts: maxAttempts,
      timeout: timeout,
      mutating: true,
      () async {
        final uri = _apiUri(target);

        final response = await _sendWithAuthRefresh(
          endpoint: target,
          jsonContent: true,
          extraHeaders: headers,
          send: (headers) => _http.post(
            uri,
            headers: headers,
            body: body == null ? null : jsonEncode(body),
          ),
        );

        // A create answers 201 Created, so any 2xx is success.
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw _parseErrorResponse(
            response.statusCode,
            response.body,
            'POST',
            target,
          );
        }
        if (response.body.trim().isEmpty) return <String, dynamic>{};

        return jsonDecode(response.body) as Map<String, dynamic>;
      },
    );
  }

  /// Mint a single-use WebSocket ticket via `POST /api/ws/ticket`.
  ///
  /// WebSocket upgrades can't carry an `Authorization` header through the
  /// browser/dart WS client, so the legacy path put the long-lived bearer
  /// token directly in the `?token=` query string — where it leaks into
  /// access logs, proxy logs, and connection history (especially over the
  /// appliance's default plain-HTTP LAN transport). The ticket is bound
  /// server-side to this token's identity, expires in ~60 s, and is consumed
  /// on first use, so it's safe to place in the URL.
  ///
  /// Returns the ticket, or null when the call fails or the server predates
  /// the endpoint — callers then fall back to `?token=`, which the server
  /// still accepts (with a deprecation warning) for backward compatibility.
  Future<String?> _mintWsTicket() async {
    if (authToken == null || authToken!.isEmpty) {
      return null;
    }
    try {
      final res = await _post(AuthApi.wsTicketIssue);
      final ticket = res['ticket'];
      if (ticket is String && ticket.isNotEmpty) {
        return ticket;
      }
    } catch (e) {
      Log.debug(
        'WS ticket unavailable; falling back to legacy ?token=: $e',
        source: 'NetworkBackend',
      );
    }
    return null;
  }

  Future<void> _delete(
    ApiEndpoint endpoint, {
    Map<String, Object> path = const {},
    Map<String, dynamic>? query,
  }) async {
    final target = _endpointPath(endpoint, ApiMethod.delete, path);
    return _retryableRequest(mutating: true, () async {
      final uri = _apiUri(target, _queryStrings(query));

      final response = await _sendWithAuthRefresh(
        endpoint: target,
        send: (headers) => _http.delete(uri, headers: headers),
      );

      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'DELETE',
          target,
        );
      }
    });
  }

  Future<Map<String, dynamic>> _put(
    ApiEndpoint endpoint, {
    Map<String, Object> path = const {},
    Map<String, dynamic>? body,
  }) async {
    final target = _endpointPath(endpoint, ApiMethod.put, path);
    return _retryableRequest(() async {
      final uri = _apiUri(target);

      final response = await _sendWithAuthRefresh(
        endpoint: target,
        jsonContent: true,
        send: (headers) => _http.put(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
      );

      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'PUT',
          target,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    });
  }

  Future<Uint8List> _downloadBytes(
    ApiEndpoint endpoint, {
    Map<String, Object> path = const {},
    Map<String, dynamic>? query,
  }) async {
    final downloaded = await _downloadBytesWithHeaders(
      endpoint,
      path: path,
      query: query,
    );
    return downloaded.bytes;
  }

  Future<({Uint8List bytes, Map<String, String> headers})>
  _downloadBytesWithHeaders(
    ApiEndpoint endpoint, {
    Map<String, Object> path = const {},
    Map<String, dynamic>? query,
  }) async {
    final target = _endpointPath(endpoint, ApiMethod.get, path);
    return _retryableRequest(() async {
      final uri = _apiUri(target, _queryStrings(query));
      final response = await _sendWithAuthRefresh(
        endpoint: target,
        send: (headers) => _http.get(uri, headers: headers),
      );
      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'GET',
          target,
        );
      }
      return (
        bytes: response.bodyBytes,
        headers: Map<String, String>.from(response.headers),
      );
    });
  }

  /// Stream a binary GET straight to [localPath], reporting progress in
  /// `[0, 1]` when the server declares a Content-Length.
  ///
  /// Simpler cousin of the resumable image download in
  /// `imaging_profile_operations.dart`: log files and calibration masters
  /// are modest enough that an interrupted transfer just restarts, so the
  /// sidecar/Range/ETag machinery is deliberately not replicated here.
  Future<void> _downloadToFile(
    ApiEndpoint endpoint,
    String localPath, {
    Map<String, Object> path = const {},
    void Function(double)? onProgress,
  }) async {
    final target = _endpointPath(endpoint, ApiMethod.get, path);
    final file = File(localPath);
    await file.parent.create(recursive: true);
    final response = await _openRawGetWithAuthRefresh(target);
    if (response.statusCode != HttpStatus.ok) {
      final body = await response.transform(utf8.decoder).join();
      throw _parseErrorResponse(response.statusCode, body, 'GET', target);
    }
    final totalLength = response.contentLength;
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (totalLength > 0) {
          onProgress?.call((received / totalLength).clamp(0.0, 1.0).toDouble());
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (totalLength > 0 && received != totalLength) {
      throw FormatException(
        '$target transfer truncated ($received of $totalLength bytes)',
      );
    }
    onProgress?.call(1);
  }

  Future<Map<String, dynamic>> _postRaw(
    ApiEndpoint endpoint, {
    required Map<String, dynamic> query,
    required Uint8List bytes,
    String contentType = 'application/octet-stream',
  }) async {
    final target = _endpointPath(endpoint, ApiMethod.post);
    return _retryableRequest(() async {
      final uri = _apiUri(target, _queryStrings(query));

      final response = await _sendWithAuthRefresh(
        endpoint: target,
        extraHeaders: {HttpHeaders.contentTypeHeader: contentType},
        send: (headers) => _http.post(uri, headers: headers, body: bytes),
      );

      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'POST',
          target,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    });
  }

  Future<Uint8List> _postRawBytes(
    ApiEndpoint endpoint, {
    Map<String, Object> path = const {},
    required Map<String, dynamic> body,
  }) async {
    final target = _endpointPath(endpoint, ApiMethod.post, path);
    return _retryableRequest(() async {
      final uri = _apiUri(target);

      final response = await _sendWithAuthRefresh(
        endpoint: target,
        jsonContent: true,
        send: (headers) =>
            _http.post(uri, headers: headers, body: jsonEncode(body)),
      );
      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'POST',
          target,
        );
      }
      return response.bodyBytes;
    });
  }

  List<T> _rowsFromJson<T>(
    Object? source,
    T Function(Map<String, dynamic>) decoder,
  ) {
    if (source is! List) {
      throw const FormatException(
        'Remote response row collection is missing or is not a list',
      );
    }
    final decoded = <T>[];
    for (var index = 0; index < source.length; index++) {
      final row = source[index];
      if (row is! Map) {
        throw FormatException('Remote response row $index is not an object');
      }
      decoded.add(decoder(row.cast<String, dynamic>()));
    }
    return decoded;
  }
}

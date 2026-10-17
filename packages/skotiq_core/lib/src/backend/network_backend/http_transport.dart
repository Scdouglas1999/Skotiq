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

  /// Determine if an HTTP exception is a transient failure that can be retried
  bool _isTransientFailure(dynamic error) {
    // Check for structured SkotiqError
    if (error is dart_error.SkotiqError) {
      return error.isRecoverable;
    }
    // Error parsing: the headless envelope's httpStatus tells
    // us whether the request should be retried. Mirror the same status
    // ranges as [_isTransientStatusCode] so retry behaviour is
    // consistent whether the failure was decoded into a [ServerError] or
    // a fallback [SkotiqError].
    if (error is ServerError) {
      final status = error.httpStatus;
      if (status != null) {
        return _isTransientStatusCode(status);
      }
      return false;
    }
    if (error is SocketException) {
      // Network errors are transient
      return true;
    }
    if (error is TimeoutException) {
      // Timeouts are transient
      return true;
    }
    if (error is HttpException) {
      // Connection reset, broken pipe, etc.
      return true;
    }
    if (error is Exception) {
      final errorStr = error.toString().toLowerCase();
      // Check for common transient error messages
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

  /// Check if an HTTP status code indicates a transient failure
  bool _isTransientStatusCode(int statusCode) {
    // 408 Request Timeout, 429 Too Many Requests, 500 Internal Server Error,
    // 502 Bad Gateway, 503 Service Unavailable, 504 Gateway Timeout
    return statusCode == 408 || statusCode == 429 || statusCode >= 500;
  }

  /// Parse an error response from the server.
  ///
  /// Attempts to parse structured error JSON from the response body.
  /// Falls back to creating an error from the status code and endpoint.
  ///
  /// Return type is [Exception] rather than the narrower
  /// [dart_error.SkotiqError] because the headless server's new
  /// envelope ({code, message, details}) is surfaced as a typed
  /// [ServerError] — see the [error parsing] branch below.
  /// Existing callers `throw` the result so the widened type doesn't
  /// change their behaviour; the retry helper's
  /// `_isTransientFailure` accepts any Object via duck-typing.
  Exception _parseErrorResponse(
    int statusCode,
    String responseBody,
    String method,
    String endpoint,
  ) {
    _markAuthRejectedIfTerminal(statusCode, responseBody, method, endpoint);
    // Try to parse as structured error JSON
    try {
      final json = jsonDecode(responseBody);
      if (json is Map<String, dynamic>) {
        // Error parsing: [ServerError.tryFromJson] is the single
        // converged parser for the headless error envelope. It accepts
        // the canonical {code, message}, the unified {error, code,
        // message} transition shape, AND the legacy prose-only {error}
        // bodies (synthesizing a code from the status). We still guard
        // on the absence of `category` so we don't swallow the richer
        // SkotiqError envelope, which always carries `category` and
        // is decoded just below.
        if (!json.containsKey('category')) {
          final serverError = ServerError.tryFromJson(
            json,
            httpStatus: statusCode,
          );
          if (serverError != null) {
            return serverError;
          }
        }

        // Check for full structured error format
        if (json.containsKey('category') && json.containsKey('message')) {
          return dart_error.SkotiqError.fromJson(json);
        }

        // Check for legacy error format: {error: 'message', message: 'details'}
        if (json.containsKey('error') || json.containsKey('message')) {
          final errorMsg =
              json['error'] as String? ??
              json['message'] as String? ??
              'Unknown error';
          final detailMsg =
              json['message'] as String? ?? json['details'] as String? ?? '';
          final fullMessage = detailMsg.isNotEmpty && detailMsg != errorMsg
              ? '$errorMsg: $detailMsg'
              : errorMsg;

          return dart_error.SkotiqError.fromString(fullMessage);
        }
      }
    } catch (e, stackTrace) {
      // Why: the server may return a non-JSON body (HTML error page, plain
      // text from a misbehaving proxy, empty body). The structured-error
      // path is best-effort; the HTTP-status fallback below always produces
      // a useful SkotiqError. Logging at FINE keeps the dev console
      // signal-only when servers regularly return non-JSON 5xx pages.
      // Justification: trace-level (500) — diagnostic-only for the
      // best-effort JSON decode path; HTTP-status fallback below is the
      // real error surface.
      developer.log(
        '[NetworkBackend] _parseErrorResponse JSON decode failed '
        '(status=$statusCode endpoint=$endpoint): $e',
        name: 'NetworkBackend',
        level: 500,
        error: e,
        stackTrace: stackTrace,
      );
    }

    // Fallback: create error from HTTP status
    final isTransient = _isTransientStatusCode(statusCode);
    return dart_error.SkotiqError(
      category: statusCode == 404
          ? dart_error.BackendErrorCategory.connection
          : statusCode == 400
          ? dart_error.BackendErrorCategory.validation
          : statusCode == 408 || statusCode == 504
          ? dart_error.BackendErrorCategory.timeout
          : dart_error.BackendErrorCategory.system,
      message: 'HTTP $statusCode: $method $endpoint failed',
      isRecoverable: isTransient,
      isTimeout: statusCode == 408 || statusCode == 504,
    );
  }

  /// Latch the terminal auth-rejection flags when the server definitively
  /// refuses the bearer token: a `403` whose body carries the auth
  /// middleware's "Invalid authentication token" message.
  ///
  /// This runs inside the single error choke point every JSON helper (and
  /// the raw download path) funnels through, so one dead-token response is
  /// enough — after it latches, [_retryableRequest] fails fast without
  /// touching the wire and [_connect] stops retrying, keeping a dead token
  /// from flooding the server's per-IP auth-failure limiter into a `429`
  /// lockout. Scope denials ("Insufficient scope", session-ownership 403s)
  /// carry a different message and deliberately do NOT latch: a view-scope
  /// token refused by a control endpoint is still valid for view traffic.
  void _markAuthRejectedIfTerminal(
    int statusCode,
    String responseBody,
    String method,
    String endpoint,
  ) {
    if (statusCode != HttpStatus.forbidden ||
        !responseBody.contains('Invalid authentication token')) {
      return;
    }
    _latchAuthRejection('$method $endpoint');
  }

  /// Retry a request with exponential backoff
  /// Max 3 attempts for transient failures only
  Future<T> _retryableRequest<T>(
    Future<T> Function() request, {
    int maxAttempts = 3,
    Duration? timeout,
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

        // Check if this is the last attempt
        if (attempt >= maxAttempts) {
          developer.log(
            '[NetworkBackend] Request failed after $maxAttempts attempts: $e',
            name: 'NetworkBackend',
            level: 1000,
            error: e,
          );
          rethrow;
        }

        // Only retry transient failures
        if (!_isTransientFailure(e)) {
          developer.log(
            '[NetworkBackend] Non-transient failure, not retrying: $e',
            name: 'NetworkBackend',
            level: 1000,
            error: e,
          );
          rethrow;
        }

        // Calculate backoff delay: 1s, 2s, 4s
        final delay = Duration(seconds: 1 << (attempt - 1));
        developer.log(
          '[NetworkBackend] Transient failure, retrying in ${delay.inSeconds}s (attempt $attempt/$maxAttempts): $e',
          name: 'NetworkBackend',
          level: 900,
          error: e,
        );
        await Future.delayed(delay);
      }
    }

    // The loop always returns or rethrows. Preserve any non-Exception Error as
    // well if that invariant changes, rather than masking it with a type cast.
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<Map<String, dynamic>> _get(
    String endpoint, [
    Map<String, dynamic>? queryParams,
  ]) async {
    return _retryableRequest(() async {
      final uri = _apiUri(
        endpoint,
        queryParams?.map((k, v) => MapEntry(k, v.toString())),
      );

      final response = await _sendWithAuthRefresh(
        endpoint: endpoint,
        send: (headers) => _http.get(uri, headers: headers),
      );

      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'GET',
          endpoint,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    });
  }

  Future<Map<String, dynamic>> _post(
    String endpoint, [
    Map<String, dynamic>? body,
    Map<String, String>? extraHeaders,
    int maxAttempts = 3,
    Duration? timeout,
  ]) async {
    return _retryableRequest(
      maxAttempts: maxAttempts,
      timeout: timeout,
      () async {
        final uri = _apiUri(endpoint);

        final response = await _sendWithAuthRefresh(
          endpoint: endpoint,
          jsonContent: true,
          extraHeaders: extraHeaders,
          send: (headers) => _http.post(
            uri,
            headers: headers,
            body: body == null ? null : jsonEncode(body),
          ),
        );

        if (response.statusCode != 200) {
          throw _parseErrorResponse(
            response.statusCode,
            response.body,
            'POST',
            endpoint,
          );
        }

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
      final res = await _post('ws/ticket');
      final ticket = res['ticket'];
      if (ticket is String && ticket.isNotEmpty) {
        return ticket;
      }
    } catch (e) {
      developer.log(
        'WS ticket unavailable; falling back to legacy ?token=: $e',
        name: 'NetworkBackend',
        level: 700,
      );
    }
    return null;
  }

  Future<void> _delete(String endpoint) async {
    return _retryableRequest(() async {
      final uri = _apiUri(endpoint);

      final response = await _sendWithAuthRefresh(
        endpoint: endpoint,
        send: (headers) => _http.delete(uri, headers: headers),
      );

      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'DELETE',
          endpoint,
        );
      }
    });
  }

  Future<Map<String, dynamic>> _put(
    String endpoint, [
    Map<String, dynamic>? body,
  ]) async {
    return _retryableRequest(() async {
      final uri = _apiUri(endpoint);

      final response = await _sendWithAuthRefresh(
        endpoint: endpoint,
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
          endpoint,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    });
  }

  Future<Uint8List> _downloadBytes(
    String endpoint, [
    Map<String, dynamic>? queryParams,
  ]) async {
    final downloaded = await _downloadBytesWithHeaders(endpoint, queryParams);
    return downloaded.bytes;
  }

  Future<({Uint8List bytes, Map<String, String> headers})>
  _downloadBytesWithHeaders(
    String endpoint, [
    Map<String, dynamic>? queryParams,
  ]) async {
    return _retryableRequest(() async {
      final uri = _apiUri(
        endpoint,
        queryParams?.map((k, v) => MapEntry(k, v.toString())),
      );
      final response = await _sendWithAuthRefresh(
        endpoint: endpoint,
        send: (headers) => _http.get(uri, headers: headers),
      );
      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'GET',
          endpoint,
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
    String endpoint,
    String localPath, {
    void Function(double)? onProgress,
  }) async {
    final file = File(localPath);
    await file.parent.create(recursive: true);
    final response = await _openRawGetWithAuthRefresh(endpoint);
    if (response.statusCode != HttpStatus.ok) {
      final body = await response.transform(utf8.decoder).join();
      throw _parseErrorResponse(response.statusCode, body, 'GET', endpoint);
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
        '$endpoint transfer truncated ($received of $totalLength bytes)',
      );
    }
    onProgress?.call(1);
  }

  Future<Map<String, dynamic>> _postRaw(
    String endpoint,
    Map<String, dynamic> queryParams,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
  }) async {
    return _retryableRequest(() async {
      final uri = _apiUri(
        endpoint,
        queryParams.map((key, value) => MapEntry(key, value.toString())),
      );

      final response = await _sendWithAuthRefresh(
        endpoint: endpoint,
        extraHeaders: {HttpHeaders.contentTypeHeader: contentType},
        send: (headers) => _http.post(uri, headers: headers, body: bytes),
      );

      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'POST',
          endpoint,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    });
  }

  Future<Uint8List> _postRawBytes(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    return _retryableRequest(() async {
      final uri = _apiUri(endpoint);

      final response = await _sendWithAuthRefresh(
        endpoint: endpoint,
        jsonContent: true,
        send: (headers) =>
            _http.post(uri, headers: headers, body: jsonEncode(body)),
      );
      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'POST',
          endpoint,
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

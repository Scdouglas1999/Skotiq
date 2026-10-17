part of '../headless_api_server.dart';

extension _HeadlessApiServerHttpMiddleware on HeadlessApiServer {
  // Middleware

  Middleware _requestTrackingMiddleware() {
    return (innerHandler) {
      return (request) async {
        final requestId =
            request.headers[HeadlessApiServer._requestIdHeader] ??
            _nextRequestId();
        final path = '/${request.url.path}';
        final startedAt = DateTime.now();
        final scopedRequest = request.change(
          context: {
            ...request.context,
            HeadlessApiServer._requestIdContextKey: requestId,
          },
        );

        _logInfo(
          '[REQ][$requestId] ${request.method} $path started',
          fields: {
            'requestId': requestId,
            'method': request.method,
            'path': path,
            'phase': 'started',
          },
        );
        try {
          final response = await innerHandler(scopedRequest);
          final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
          _logInfo(
            '[REQ][$requestId] ${request.method} $path completed status=${response.statusCode} ms=$elapsedMs',
            fields: {
              'requestId': requestId,
              'method': request.method,
              'path': path,
              'phase': 'completed',
              'statusCode': response.statusCode,
              'elapsedMs': elapsedMs,
            },
          );
          if (path == '/api/ws' || path == '/events') {
            return response;
          }
          return response.change(
            headers: {
              ...response.headers,
              HeadlessApiServer._requestIdHeader: requestId,
            },
          );
        } on HijackException {
          // WebSocket upgrades intentionally hijack the shelf request stream.
          // This is control flow for shelf_io, not a failed HTTP request; it
          // must escape every middleware layer untouched.
          rethrow;
        } catch (e, stackTrace) {
          final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
          _logError(
            '[REQ][$requestId] ${request.method} $path failed ms=$elapsedMs error=$e\n$stackTrace',
            fields: {
              'requestId': requestId,
              'method': request.method,
              'path': path,
              'phase': 'failed',
              'elapsedMs': elapsedMs,
              'error': e.toString(),
            },
          );
          rethrow;
        }
      };
    };
  }

  Middleware _corsMiddleware() {
    return (innerHandler) {
      return (request) async {
        final corsHeaders = _buildCorsHeaders(request);
        if (request.method == 'OPTIONS') {
          if (request.headers.containsKey('origin') && corsHeaders.isEmpty) {
            return jsonForbidden(
              {
                'error': 'origin_not_allowed',
                'message': 'Cross-origin requests are not allowed.',
              },
              headers: {'vary': 'Origin'},
            );
          }
          return Response.ok('', headers: corsHeaders);
        }

        final response = await innerHandler(request);
        final path = '/${request.url.path}';
        if (path == '/api/ws' || path == '/events') {
          return response;
        }
        if (corsHeaders.isEmpty) {
          return response;
        }
        return response.change(headers: {...response.headers, ...corsHeaders});
      };
    };
  }

  /// Header-only `Content-Length` ceiling (part 1 of 2).
  ///
  /// This runs BEFORE auth because it reads only the declared `Content-Length`
  /// header (never the body), so a declared over-limit upload is rejected with
  /// 413 (or 400 for a malformed header) cheaply and regardless of credentials.
  /// The expensive part — buffering a chunked body that omits `Content-Length`
  /// — is split into [_chunkedBodyLimitMiddleware], which runs AFTER auth so an
  /// unauthenticated client cannot force the server to buffer a body up to the
  /// per-path cap (≤1 GiB for catalog uploads) before its token is checked.
  Middleware _contentLengthLimitMiddleware() {
    return (innerHandler) {
      return (request) {
        final path = '/${request.url.path}';
        final validation = route_metadata.validateContentLength(
          method: request.method,
          path: path,
          contentLengthHeader: request.headers[HttpHeaders.contentLengthHeader],
        );
        if (validation != null) {
          return jsonResponse(
            validation['body'],
            statusCode: validation['statusCode'] as int,
          );
        }
        return innerHandler(request);
      };
    };
  }

  /// Buffer-and-cap a chunked request body.
  ///
  /// Only requests that (a) use a body-bearing method and (b) omit
  /// `Content-Length` (i.e. `Transfer-Encoding: chunked`) reach the streaming
  /// cap here. Installed AFTER [_authMiddleware] in the pipeline so an
  /// unauthenticated request to a protected path is rejected (401) before any
  /// of its body is read, which closes the pre-auth buffering vector.
  Middleware _chunkedBodyLimitMiddleware() {
    return (innerHandler) {
      return (request) async {
        if (!route_metadata.methodCanHaveBody(request.method)) {
          return innerHandler(request);
        }

        final declaredContentLength =
            request.headers[HttpHeaders.contentLengthHeader];
        if (declaredContentLength != null && declaredContentLength.isNotEmpty) {
          return innerHandler(request);
        }

        final path = '/${request.url.path}';
        final limit = route_metadata.requestBodyLimitForPath(path);
        final body = await _readRequestBodyWithinLimit(request, limit);
        if (!body.accepted) {
          final requestId = _requestIdFrom(request);
          _logWarning(
            '[REQ][$requestId] ${request.method} $path body too large '
            'received=${body.receivedBytes} max=$limit',
            fields: {
              'requestId': requestId,
              'method': request.method,
              'path': path,
              'receivedBytes': body.receivedBytes,
              'maxBytes': limit,
            },
          );
          return jsonTooLarge({
            'error': 'Request body too large',
            'maxBytes': limit,
            'receivedBytes': body.receivedBytes,
            'requestId': requestId,
          });
        }

        return innerHandler(request.change(body: body.bytes));
      };
    };
  }

  Future<_RequestBodyLimitResult> _readRequestBodyWithinLimit(
    Request request,
    int maxBytes,
  ) async {
    final bytes = BytesBuilder(copy: false);
    var receivedBytes = 0;
    var exceededLimit = false;
    await for (final chunk in request.read()) {
      receivedBytes += chunk.length;
      if (receivedBytes > maxBytes) {
        exceededLimit = true;
        continue;
      }
      if (!exceededLimit) {
        bytes.add(chunk);
      }
    }
    if (exceededLimit) {
      return _RequestBodyLimitResult.rejected(receivedBytes);
    }
    return _RequestBodyLimitResult.accepted(bytes.takeBytes(), receivedBytes);
  }

  Middleware _apiVersionMiddleware() {
    return (innerHandler) {
      return (request) async {
        final path = '/${request.url.path}';
        final isWebSocket = path == '/api/ws' || path == '/events';
        final clientVersion =
            request.headers[RemoteApiCompatibility.apiVersionHeader] ??
            (isWebSocket ? request.url.queryParameters['apiVersion'] : null);
        if ((path.startsWith('/api/') || isWebSocket) &&
            clientVersion != null &&
            clientVersion.trim().isNotEmpty) {
          final compatibility = RemoteApiCompatibility.checkClient(
            clientVersion,
          );
          if (!compatibility.isCompatible) {
            final requestId = _requestIdFrom(request);
            _logWarning(
              '[API][$requestId] Rejected incompatible client API version '
              '$clientVersion for $path: ${compatibility.code}',
            );
            return jsonUpgradeRequired(
              {
                'error': compatibility.code,
                'message': compatibility.message,
                'clientApiVersion':
                    compatibility.clientVersion ?? clientVersion,
                'serverApiVersion': RemoteApiCompatibility.serverApiVersion
                    .format(),
                'minimumSupportedApiVersion': RemoteApiCompatibility
                    .minimumSupportedVersion
                    .format(),
                'requestId': requestId,
              },
              headers: {
                HeadlessApiServer._requestIdHeader: requestId,
                ..._apiCompatibilityHeaders(),
              },
            );
          }
        }

        final response = await innerHandler(request);
        if (isWebSocket) {
          return response;
        }
        return response.change(
          headers: {...response.headers, ..._apiCompatibilityHeaders()},
        );
      };
    };
  }

  Map<String, String> _apiCompatibilityHeaders() {
    return {
      RemoteApiCompatibility.apiVersionHeader: RemoteApiCompatibility
          .serverApiVersion
          .format(),
      'x-skotiq-minimum-api-version': RemoteApiCompatibility
          .minimumSupportedVersion
          .format(),
    };
  }

  Map<String, String> _buildCorsHeaders(Request request) {
    final origin = request.headers['origin'];
    final allowedOrigin = _resolveAllowedOrigin(request, origin);
    if (allowedOrigin == null) {
      return const {};
    }
    return {
      'Access-Control-Allow-Origin': allowedOrigin,
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      // Why include the CSRF header: cookie-bearing fetches from the
      // dashboard SPA echo the server-issued CSRF token via
      // `X-Skotiq-CSRF`; without it in the allow-list the browser
      // would block the request before this middleware ever ran.
      'Access-Control-Allow-Headers':
          'Origin, Content-Type, X-Auth-Token, Authorization, '
          'X-Skotiq-API-Version, X-Request-ID, X-Skotiq-CSRF',
      // Why expose Set-Cookie on the wire but not allow-credentials: the
      // cookie is HttpOnly so the browser stores it without JS seeing it;
      // `credentials: 'include'` on the SPA fetch is what makes the cookie
      // round-trip, and that requires the next header.
      'Access-Control-Allow-Credentials': 'true',
      'Vary': 'Origin',
    };
  }

  String? _resolveAllowedOrigin(Request request, String? origin) {
    // Why delegate: reflecting any origin that matches the bound host:port
    // lets any local-loopback browser app bypass CORS from a different port.
    // [CorsAllowList] applies the explicit configured allow-list and an even
    // stricter rule for high-risk control paths; the same-origin escape hatch
    // keeps the bundled dashboard working without configuration.
    return _corsAllowList.resolve(
      requestOrigin: origin,
      requestUri: request.requestedUri,
      path: '/${request.url.path}',
    );
  }
}

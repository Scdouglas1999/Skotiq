part of '../headless_api_server.dart';

extension _HeadlessApiServerHttpMiddleware on HeadlessApiServer {
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

        // The request log is written beside the handler, never in front of
        // it: a stalled log disk must not hold up a command, Stop above all.
        final isRead = request.method == 'GET' || request.method == 'HEAD';
        if (!isRead) {
          unawaited(
            _logger.logRequest(
              LogLevel.info,
              '[REQ][$requestId] ${request.method} $path started',
              source: 'HeadlessApiServer',
              fields: {
                'requestId': requestId,
                'method': request.method,
                'path': path,
                'phase': 'started',
              },
            ),
          );
        }
        try {
          final response = await innerHandler(scopedRequest);
          final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
          if (!requestCompletionIsRoutine(
            method: request.method,
            statusCode: response.statusCode,
            elapsedMs: elapsedMs,
          )) {
            unawaited(
              _logger.logRequest(
                LogLevel.info,
                '[REQ][$requestId] ${request.method} $path completed status=${response.statusCode} ms=$elapsedMs',
                source: 'HeadlessApiServer',
                fields: {
                  'requestId': requestId,
                  'method': request.method,
                  'path': path,
                  'phase': 'completed',
                  'statusCode': response.statusCode,
                  'elapsedMs': elapsedMs,
                },
              ),
            );
          }
          if (RouteTable.of(request).isWebSocket) {
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
          unawaited(
            _logger.logRequest(
              LogLevel.error,
              '[REQ][$requestId] ${request.method} $path failed ms=$elapsedMs error=$e\n$stackTrace',
              source: 'HeadlessApiServer',
              fields: {
                'requestId': requestId,
                'method': request.method,
                'path': path,
                'phase': 'failed',
                'elapsedMs': elapsedMs,
                'error': e.toString(),
              },
            ),
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
        if (RouteTable.of(request).isWebSocket) {
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
        final validation = validateContentLength(
          method: request.method,
          limit: RouteTable.of(request).policy.maxBodyBytes,
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
        if (!methodCanHaveBody(request.method)) {
          return innerHandler(request);
        }

        final declaredContentLength =
            request.headers[HttpHeaders.contentLengthHeader];
        if (declaredContentLength != null && declaredContentLength.isNotEmpty) {
          return innerHandler(request);
        }

        final path = '/${request.url.path}';
        final limit = RouteTable.of(request).policy.maxBodyBytes;
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

  /// After a command (any non-GET request), forget the shared device status
  /// reads: a read from before the command must not answer a read after it.
  /// See [EquipmentHandlers.forgetSharedStatus].
  Middleware _statusShareMiddleware() {
    return (innerHandler) {
      return (request) async {
        final response = await innerHandler(request);
        final method = request.method;
        if (method != 'GET' && method != 'HEAD' && method != 'OPTIONS') {
          _equipmentHandlers.forgetSharedStatus();
        }
        return response;
      };
    };
  }

  /// Holds every API request to the same-release rule ([LinkVersion]).
  ///
  /// A request says which release sent it in the `x-skotiq-version` header;
  /// a WebSocket upgrade may use the `version` query parameter. A request
  /// from a page this host served (its `Origin` or `Referer` is this host)
  /// needs neither: the host serves those pages itself, so they are its own
  /// release by construction, and a browser cannot put a header on an image,
  /// a download or an event stream. Any other request that does not name its
  /// release is refused with `release_required`.
  ///
  /// A named release that is not this host's is refused with
  /// `version_mismatch`, except on the routes open to other releases
  /// ([LinkVersion.openToOtherReleases]): the host's identity and its update
  /// routes, so a newer client can update this host. `/api/info` is answered
  /// to everyone: it is how a client learns the host's release.
  Middleware _linkVersionMiddleware() {
    return (innerHandler) {
      return (request) async {
        final path = '/${request.url.path}';
        final isWebSocket = RouteTable.of(request).isWebSocket;
        if (!(path.startsWith('/api/') || isWebSocket) ||
            path == SystemApi.info.route.path) {
          return innerHandler(request);
        }
        final clientRelease =
            request.headers[LinkVersion.header] ??
            (isWebSocket
                ? request.url.queryParameters[LinkVersion.queryParameter]
                : null);
        final hostRelease = container.read(appVersionProvider).version;
        if (clientRelease == null) {
          if (_isFromThisHostsPage(request)) return innerHandler(request);
          final requestId = _requestIdFrom(request);
          _logWarning(
            '[API][$requestId] Refused $path: the request does not name its '
            'Skotiq release',
          );
          return jsonUpgradeRequired(
            {
              'code': LinkVersion.releaseRequiredCode,
              'message':
                  'This request does not say which Skotiq release sent it. Send '
                  'the header ${LinkVersion.header}: $hostRelease (the release '
                  'GET /api/info reports), or update the app on this device to '
                  'Skotiq $hostRelease.',
              'hostVersion': hostRelease,
              'requestId': requestId,
            },
            headers: {HeadlessApiServer._requestIdHeader: requestId},
          );
        }
        final mismatch = LinkVersion.check(
          host: hostRelease,
          client: clientRelease,
        );
        if (mismatch == null || LinkVersion.openToOtherReleases(path)) {
          return innerHandler(request);
        }
        final requestId = _requestIdFrom(request);
        _logWarning(
          '[API][$requestId] Refused $path from Skotiq $clientRelease: '
          '${mismatch.message}',
        );
        return jsonUpgradeRequired(
          mismatch.toErrorBody(requestId: requestId).toJson(),
          headers: {HeadlessApiServer._requestIdHeader: requestId},
        );
      };
    };
  }

  /// Whether a browser sent [request] from a page served at this request's
  /// own host and port.
  bool _isFromThisHostsPage(Request request) {
    final host = request.headers['host'];
    if (host == null || host.isEmpty) return false;
    for (final name in const ['origin', 'referer']) {
      final value = request.headers[name];
      if (value == null) continue;
      final uri = Uri.tryParse(value);
      if (uri != null && uri.hasAuthority && uri.authority == host) {
        return true;
      }
    }
    return false;
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
          'X-Skotiq-Version, X-Skotiq-Device-Id, X-Request-ID, X-Skotiq-CSRF',
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
    // [CorsAllowList] applies the configured allow-list; the same-origin
    // escape hatch keeps the bundled dashboard working without configuration.
    return _corsAllowList.resolve(
      requestOrigin: origin,
      requestUri: request.requestedUri,
    );
  }
}

/// A read that succeeded promptly is routine and is not logged: a linked
/// client polls dozens of them a minute, and two lines each filled the host's
/// log (80 MB in a day). Writes, failures and slow requests are logged.
bool requestCompletionIsRoutine({
  required String method,
  required int statusCode,
  required int elapsedMs,
}) =>
    (method == 'GET' || method == 'HEAD') &&
    statusCode < 400 &&
    elapsedMs < 2000;

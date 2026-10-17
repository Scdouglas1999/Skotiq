// Fake `http.Client` for testing `NetworkBackend` request/response paths.
//
// Why: `NetworkBackend` is 3,800+ LOC of HTTP wiring that we cannot run
// against a live headless server in unit tests. This fake records every
// outbound request and lets a test pre-configure the response, status code,
// and headers for any endpoint+method tuple. It is backed by `MockClient`
// from `package:http/testing.dart`, so it satisfies the production
// `http.Client` contract `NetworkBackend` accepts via its constructor.

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One recorded HTTP request observed by a [FakeNetworkClient].
class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    required this.bodyBytes,
  });

  /// HTTP method in uppercase (`GET`, `POST`, `PUT`, `DELETE`, ...).
  final String method;

  /// Full request URL.
  final Uri url;

  /// Request headers exactly as sent.
  final Map<String, String> headers;

  /// Decoded request body as a UTF-8 string, or `null` if the request had
  /// no body or the body was not valid UTF-8.
  final String? body;

  /// Raw request body bytes.
  final Uint8List bodyBytes;

  /// Path component of the URL with a leading slash (e.g. `/api/devices`).
  String get path => url.path;

  @override
  String toString() => '$method $url';
}

/// Canned response for a specific endpoint+method.
class _CannedResponse {
  _CannedResponse({
    required this.status,
    required this.body,
    required this.headers,
    this.bodyBytes,
  });

  final int status;
  final String body;
  final Uint8List? bodyBytes;
  final Map<String, String> headers;
}

/// Match key for canned responses. Uses (method, path) so query strings
/// don't have to be reproduced exactly by callers.
class _RouteKey {
  _RouteKey(this.method, this.path);

  final String method;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is _RouteKey && other.method == method && other.path == path;

  @override
  int get hashCode => Object.hash(method, path);

  @override
  String toString() => '$method $path';
}

/// Fake HTTP client recording requests and returning pre-configured
/// responses, intended to be injected into [NetworkBackend] under test.
///
/// Usage:
/// ```dart
/// final fake = FakeNetworkClient()
///   ..setResponse('/api/devices', method: 'GET', body: '{"devices":[]}');
/// final backend = NetworkBackend(
///   serverHost: 'example.invalid',
///   httpClient: fake,
///   autoConnectWebSocket: false,
/// );
/// // ...exercise backend...
/// expect(fake.requests, hasLength(1));
/// ```
class FakeNetworkClient implements http.Client {
  FakeNetworkClient() {
    _inner = MockClient(_handle);
  }

  late final MockClient _inner;
  final Map<_RouteKey, _CannedResponse> _routes = {};
  final Map<_RouteKey, List<_CannedResponse>> _responseSequences = {};

  /// Optional default response used when no route matches. If `null`, an
  /// unmatched request throws `StateError` to surface the bug loudly rather
  /// than letting the backend silently see a 200 from nowhere.
  _CannedResponse? _defaultResponse;

  /// Every request observed, in the order received, including retries.
  final List<RecordedRequest> requests = [];

  /// Register a canned response for a given endpoint+method.
  ///
  /// [endpoint] should be the path the backend will hit (with leading
  /// slash), e.g. `/api/devices`. [method] is case-insensitive.
  void setResponse(
    String endpoint, {
    String method = 'GET',
    int status = 200,
    String body = '{}',
    Map<String, String>? headers,
  }) {
    _routes[_RouteKey(method.toUpperCase(), endpoint)] = _CannedResponse(
      status: status,
      body: body,
      headers: headers ?? const {'content-type': 'application/json'},
    );
  }

  /// Register ordered canned responses for repeated calls to a route.
  ///
  /// Once the sequence is exhausted, the final response is reused. This keeps
  /// retry tests deterministic without requiring each retry to register a
  /// different endpoint or query string.
  void setResponseSequence(
    String endpoint, {
    String method = 'GET',
    required List<({int status, String body, Map<String, String>? headers})>
    responses,
  }) {
    if (responses.isEmpty) {
      throw ArgumentError.value(responses, 'responses', 'must not be empty');
    }
    _responseSequences[_RouteKey(method.toUpperCase(), endpoint)] = responses
        .map(
          (response) => _CannedResponse(
            status: response.status,
            body: response.body,
            headers:
                response.headers ?? const {'content-type': 'application/json'},
          ),
        )
        .toList(growable: true);
  }

  /// Register a canned binary response (e.g. JPEG download endpoints).
  void setBinaryResponse(
    String endpoint, {
    String method = 'GET',
    int status = 200,
    List<int> bodyBytes = const [],
    Map<String, String>? headers,
  }) {
    _routes[_RouteKey(method.toUpperCase(), endpoint)] = _CannedResponse(
      status: status,
      body: '',
      bodyBytes: Uint8List.fromList(bodyBytes),
      headers: headers ?? const {'content-type': 'application/octet-stream'},
    );
  }

  /// Set a default response returned when no specific route is registered.
  /// Useful for blanket-stubbing health/info endpoints.
  void setDefaultResponse({
    int status = 200,
    String body = '{}',
    Map<String, String>? headers,
  }) {
    _defaultResponse = _CannedResponse(
      status: status,
      body: body,
      headers: headers ?? const {'content-type': 'application/json'},
    );
  }

  /// Reset all recorded requests and canned responses.
  void reset() {
    requests.clear();
    _routes.clear();
    _responseSequences.clear();
    _defaultResponse = null;
  }

  /// Requests whose path equals [endpoint] (ignoring query string).
  List<RecordedRequest> requestsFor(String endpoint) =>
      requests.where((r) => r.path == endpoint).toList();

  Future<http.Response> _handle(http.Request request) async {
    String? bodyAsString;
    try {
      bodyAsString = request.body;
    } catch (_) {
      bodyAsString = null;
    }

    requests.add(
      RecordedRequest(
        method: request.method.toUpperCase(),
        url: request.url,
        headers: Map<String, String>.from(request.headers),
        body: bodyAsString,
        bodyBytes: Uint8List.fromList(request.bodyBytes),
      ),
    );

    final key = _RouteKey(request.method.toUpperCase(), request.url.path);
    final sequence = _responseSequences[key];
    final canned = sequence == null
        ? _routes[key] ?? _defaultResponse
        : sequence.length > 1
        ? sequence.removeAt(0)
        : sequence.single;
    if (canned == null) {
      throw StateError(
        'FakeNetworkClient: no canned response for '
        '${request.method.toUpperCase()} ${request.url.path}',
      );
    }

    if (canned.bodyBytes != null) {
      return http.Response.bytes(
        canned.bodyBytes!,
        canned.status,
        headers: canned.headers,
        request: request,
      );
    }

    return http.Response(
      canned.body,
      canned.status,
      headers: canned.headers,
      request: request,
    );
  }

  // ---------------------------------------------------------------------------
  // `http.Client` delegation. All real HTTP work is performed by the wrapped
  // `MockClient`; we only intercept to record the call sites we care about.
  // ---------------------------------------------------------------------------

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) =>
      _inner.get(url, headers: headers);

  @override
  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _inner.post(url, headers: headers, body: body, encoding: encoding);

  @override
  Future<http.Response> put(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _inner.put(url, headers: headers, body: body, encoding: encoding);

  @override
  Future<http.Response> patch(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _inner.patch(url, headers: headers, body: body, encoding: encoding);

  @override
  Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _inner.delete(url, headers: headers, body: body, encoding: encoding);

  @override
  Future<http.Response> head(Uri url, {Map<String, String>? headers}) =>
      _inner.head(url, headers: headers);

  @override
  Future<String> read(Uri url, {Map<String, String>? headers}) =>
      _inner.read(url, headers: headers);

  @override
  Future<Uint8List> readBytes(Uri url, {Map<String, String>? headers}) =>
      _inner.readBytes(url, headers: headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => _inner.close();
}

// Cloud backup/sync — WebDAV implementation of [SyncTarget].
//
// Works against Nextcloud / ownCloud (point the base URL at
// `https://host/remote.php/dav/files/<user>/`) and any generic WebDAV
// server. Uses only `package:http` (already a workspace dependency):
// PUT / GET / DELETE go through the normal verbs, PROPFIND and MKCOL are
// issued as custom-method [http.Request]s.
//
// The PROPFIND 207 multistatus body is parsed with a small tolerant
// scanner instead of a full XML dependency: servers disagree on the
// namespace prefix (`d:`, `D:`, `lp1:`, none at all), so we match on
// local element names with prefix-agnostic patterns. This is the same
// pragmatic trade-off most lightweight DAV clients make.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate, SocketException;

import 'package:http/http.dart' as http;

import 'sync_target.dart';

class WebDavSyncTarget implements SyncTarget {
  final Uri baseUrl;
  final String username;
  final String password;
  final http.Client _client;
  final bool _ownsClient;

  /// [client] is injectable for tests (e.g. `package:http/testing.dart`
  /// MockClient). When omitted a real client is created and owned by this
  /// instance ([close] disposes it).
  WebDavSyncTarget({
    required this.baseUrl,
    required this.username,
    required this.password,
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  void close() {
    if (_ownsClient) _client.close();
  }

  String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  /// Resolve [relPath] (slash-separated, relative to [baseUrl]) to a full
  /// URI, percent-encoding each segment. [directory] appends a trailing
  /// slash — several DAV servers 301 PROPFIND/MKCOL on collections that
  /// lack one.
  Uri _uriFor(String relPath, {bool directory = false}) {
    final segments = <String>[
      ...baseUrl.pathSegments.where((s) => s.isNotEmpty),
      ...relPath.split('/').where((s) => s.isNotEmpty),
    ];
    return baseUrl.replace(
      pathSegments: directory ? [...segments, ''] : segments,
    );
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? bodyBytes,
  }) async {
    final request = http.Request(method, uri);
    request.headers['Authorization'] = _authHeader;
    if (headers != null) request.headers.addAll(headers);
    if (bodyBytes != null) request.bodyBytes = bodyBytes;
    try {
      // Bound the request so a server that accepts the socket then stops
      // responding cannot hang the call (and pushNow) indefinitely. The
      // `on TimeoutException` arm below maps it to a network error. Generous
      // enough to cover large backup-bundle PUTs on a moderate connection.
      const requestTimeout = Duration(minutes: 5);
      final streamed = await _client.send(request).timeout(requestTimeout);
      return await http.Response.fromStream(streamed).timeout(requestTimeout);
    } on SyncTargetException {
      rethrow;
    } on SocketException catch (e) {
      throw SyncTargetException(
        'Cannot reach ${uri.host}: ${e.message}',
        kind: SyncTargetErrorKind.network,
      );
    } on http.ClientException catch (e) {
      throw SyncTargetException(
        'Request to ${uri.host} failed: ${e.message}',
        kind: SyncTargetErrorKind.network,
      );
    } on TimeoutException {
      throw SyncTargetException(
        'Request to ${uri.host} timed out',
        kind: SyncTargetErrorKind.network,
      );
    }
  }

  Never _throwForStatus(http.Response response, String operation) {
    final status = response.statusCode;
    final kind = switch (status) {
      401 || 403 => SyncTargetErrorKind.auth,
      404 => SyncTargetErrorKind.notFound,
      405 || 409 || 423 => SyncTargetErrorKind.conflict,
      >= 500 => SyncTargetErrorKind.server,
      _ => SyncTargetErrorKind.unknown,
    };
    final detail = switch (kind) {
      SyncTargetErrorKind.auth =>
        'authentication failed — check username/password',
      SyncTargetErrorKind.notFound => 'remote path not found',
      SyncTargetErrorKind.conflict => 'remote state conflict',
      SyncTargetErrorKind.server => 'server error',
      _ => 'unexpected response',
    };
    throw SyncTargetException(
      '$operation failed: $detail (HTTP $status)',
      kind: kind,
      statusCode: status,
    );
  }

  @override
  Future<void> testConnection() async {
    final response = await _send(
      'PROPFIND',
      _uriFor('', directory: true),
      headers: {'Depth': '0', 'Content-Type': 'application/xml'},
      bodyBytes: utf8.encode(_propfindBody),
    );
    if (response.statusCode == 207 || response.statusCode == 200) return;
    _throwForStatus(response, 'Connection test');
  }

  @override
  Future<void> ensureDirectory(String path) async {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    var prefix = '';
    var createdBaseAncestors = false;
    for (final segment in segments) {
      prefix = prefix.isEmpty ? segment : '$prefix/$segment';
      var response = await _send('MKCOL', _uriFor(prefix, directory: true));
      // RFC 4918 §9.3.1: MKCOL against a path whose PARENT collection does not
      // exist must answer 409. The parent of the first segment is the base
      // URL's own path, which this loop never creates — so sync pointed at
      // https://host/dav/skotiq, where `skotiq` has not been made by
      // hand, fails every push with "remote state conflict (HTTP 409)" on any
      // server that does not auto-create parents. Create the base path's own
      // collections once, then retry.
      if (response.statusCode == 409 && !createdBaseAncestors) {
        createdBaseAncestors = true;
        if (await _createBaseAncestors()) {
          response = await _send('MKCOL', _uriFor(prefix, directory: true));
        }
      }
      final status = response.statusCode;
      // 201 = created, 405 = already exists. Some servers answer 200/204.
      if (status == 201 || status == 405 || status == 200 || status == 204) {
        continue;
      }
      _throwForStatus(response, 'Create directory "$prefix"');
    }
  }

  /// MKCOL each collection in [baseUrl]'s own path, shallowest first.
  ///
  /// Returns true when every hop either existed or was created, i.e. when the
  /// caller's retry is worth issuing. Failures are swallowed deliberately: on
  /// a hosted DAV mount the upper hops (`/remote.php/dav/files/me`) are not
  /// creatable and answer 403/405, which is fine — the caller's retry then
  /// reports the real error against the directory it actually wanted.
  Future<bool> _createBaseAncestors() async {
    final segments = baseUrl.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) return false;
    for (var i = 1; i <= segments.length; i++) {
      final uri = baseUrl.replace(pathSegments: [...segments.take(i), '']);
      final response = await _send('MKCOL', uri);
      final status = response.statusCode;
      final ok =
          status == 201 ||
          status == 405 ||
          status == 200 ||
          status == 204 ||
          // Already-existing mount roots we may not create are not an error
          // for our purposes; only a missing parent (409) breaks the chain.
          status == 403;
      if (!ok) return false;
    }
    return true;
  }

  @override
  Future<void> uploadFile(String path, List<int> bytes) async {
    final response = await _send(
      'PUT',
      _uriFor(path),
      headers: {'Content-Type': 'application/octet-stream'},
      bodyBytes: bytes,
    );
    final status = response.statusCode;
    if (status == 200 || status == 201 || status == 204) return;
    _throwForStatus(response, 'Upload "$path"');
  }

  @override
  Future<List<int>> downloadFile(String path) async {
    final response = await _send('GET', _uriFor(path));
    if (response.statusCode == 200) return response.bodyBytes;
    _throwForStatus(response, 'Download "$path"');
  }

  @override
  Future<void> deleteFile(String path) async {
    final response = await _send('DELETE', _uriFor(path));
    final status = response.statusCode;
    // Deleting a missing file is a declared no-op.
    if (status == 200 || status == 204 || status == 404) return;
    _throwForStatus(response, 'Delete "$path"');
  }

  @override
  Future<List<SyncRemoteEntry>> listDirectory(String path) async {
    final uri = _uriFor(path, directory: true);
    final response = await _send(
      'PROPFIND',
      uri,
      headers: {'Depth': '1', 'Content-Type': 'application/xml'},
      bodyBytes: utf8.encode(_propfindBody),
    );
    if (response.statusCode != 207 && response.statusCode != 200) {
      _throwForStatus(response, 'List "$path"');
    }
    return _parseMultistatus(response.body, requestUri: uri);
  }

  static const String _propfindBody =
      '<?xml version="1.0"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>'
      '</d:prop></d:propfind>';

  // Multistatus parsing (prefix-agnostic, no XML dependency)

  static final RegExp _responseBlock = RegExp(
    r'<(?:[A-Za-z0-9_-]+:)?response[\s>].*?</(?:[A-Za-z0-9_-]+:)?response>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _hrefPattern = _elementText('href');
  static final RegExp _lengthPattern = _elementText('getcontentlength');
  static final RegExp _modifiedPattern = _elementText('getlastmodified');
  static final RegExp _collectionPattern = RegExp(
    r'<(?:[A-Za-z0-9_-]+:)?collection[\s/>]',
    caseSensitive: false,
  );

  static RegExp _elementText(String localName) => RegExp(
    '<(?:[A-Za-z0-9_-]+:)?$localName[^>]*>(.*?)'
    '</(?:[A-Za-z0-9_-]+:)?$localName>',
    dotAll: true,
    caseSensitive: false,
  );

  static String _xmlUnescape(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  List<SyncRemoteEntry> _parseMultistatus(
    String body, {
    required Uri requestUri,
  }) {
    String normalize(String p) {
      var out = p;
      while (out.endsWith('/')) {
        out = out.substring(0, out.length - 1);
      }
      return out;
    }

    // Decoded request path ("/remote.php/dav/files/u/skotiq-sync") used
    // to skip the multistatus entry describing the listed directory itself.
    // Uri.pathSegments is already percent-decoded; hrefs are decoded the
    // same way below so the comparison is encoding-agnostic.
    final selfPath = normalize(
      '/${requestUri.pathSegments.where((s) => s.isNotEmpty).join('/')}',
    );

    final entries = <SyncRemoteEntry>[];
    for (final match in _responseBlock.allMatches(body)) {
      final block = match.group(0)!;
      final hrefMatch = _hrefPattern.firstMatch(block);
      if (hrefMatch == null) continue;

      var href = _xmlUnescape(hrefMatch.group(1)!.trim());
      // Some servers return absolute URLs in <href>.
      final hrefUri = Uri.tryParse(href);
      final hrefPath = hrefUri != null && hrefUri.hasScheme
          ? hrefUri.path
          : (hrefUri?.path ?? href);

      final decodedPath = normalize(
        hrefPath
            .split('/')
            .map((s) {
              try {
                return Uri.decodeComponent(s);
              } on ArgumentError {
                return s;
              }
            })
            .join('/'),
      );

      // Skip the entry describing the listed directory itself.
      if (decodedPath == selfPath || decodedPath.isEmpty) {
        continue;
      }

      final name = decodedPath.split('/').where((s) => s.isNotEmpty).last;
      final isDirectory =
          _collectionPattern.hasMatch(block) || hrefPath.endsWith('/');

      int? sizeBytes;
      final lengthMatch = _lengthPattern.firstMatch(block);
      if (lengthMatch != null) {
        sizeBytes = int.tryParse(lengthMatch.group(1)!.trim());
      }

      DateTime? modified;
      final modifiedMatch = _modifiedPattern.firstMatch(block);
      if (modifiedMatch != null) {
        try {
          modified = HttpDate.parse(modifiedMatch.group(1)!.trim());
        } catch (_) {
          modified = null;
        }
      }

      entries.add(
        SyncRemoteEntry(
          name: name,
          isDirectory: isDirectory,
          sizeBytes: sizeBytes,
          modified: modified,
        ),
      );
    }
    return entries;
  }
}

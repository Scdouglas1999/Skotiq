// Cloud backup/sync — S3-compatible implementation of [SyncTarget].
//
// Works against AWS S3, MinIO and Backblaze B2 (and any service that
// speaks the S3 REST API). Uses only `package:http` (the same client
// WebDavSyncTarget uses) and `package:crypto` (already a workspace
// dependency) — no AWS SDK is pulled in. Requests are signed with AWS
// Signature Version 4 (AWS4-HMAC-SHA256), hand-rolled here on top of
// crypto's HMAC-SHA256 / SHA-256 primitives.
//
// Object-store semantics differ from a real filesystem, so a few of the
// [SyncTarget] verbs map onto S3 in non-obvious ways:
//
//   * ensureDirectory is a NO-OP. Object stores have no directory
//     objects: a "directory" is just a key prefix that springs into
//     existence the moment the first key under it is PUT, and a
//     list-objects-v2 call with a delimiter synthesizes the directory
//     listing (CommonPrefixes) from the keys. Writing a zero-byte
//     prefix marker would be dead weight the sync layer never reads.
//   * deleteFile of a missing key is naturally a no-op — S3 answers 204
//     "No Content" whether or not the key existed.
//   * listDirectory issues list-objects-v2 with `prefix=<path>/` and
//     `delimiter=/`, mapping CommonPrefixes -> directory entries and
//     Contents -> file entries, and follows NextContinuationToken so a
//     prefix with more than 1000 keys is not silently truncated.
//   * testConnection issues list-objects-v2 with `max-keys=0`, which
//     validates reachability, credentials and bucket existence in one
//     call and behaves consistently across AWS / MinIO / B2.
//
// The list-objects-v2 XML body is parsed with the same small tolerant
// element scanner WebDavSyncTarget uses for PROPFIND multistatus, so we
// avoid taking a full XML dependency and stay agnostic to an (unusual
// but legal) namespace prefix.
//
// Credentials are never logged: this class emits no log output, and
// thrown [SyncTargetException] messages reference only the request host
// and the operation name — never the access key, secret, or signature.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'sync_target.dart';

/// Result of an AWS Signature Version 4 computation. Exposed (alongside
/// [S3SyncTarget.computeSigV4]) as a testable seam so the signing chain
/// can be asserted directly against AWS's published example vectors.
@immutable
class SigV4Signature {
  /// Full value for the `Authorization` request header.
  final String authorization;

  /// Lowercase hex signature (the `Signature=` field).
  final String signature;

  /// `;`-joined sorted list of signed header names.
  final String signedHeaders;

  /// `<date>/<region>/<service>/aws4_request` credential scope.
  final String credentialScope;

  /// The canonical request that was hashed (test/diagnostic aid).
  final String canonicalRequest;

  /// The string-to-sign that was HMAC'd with the signing key.
  final String stringToSign;

  const SigV4Signature({
    required this.authorization,
    required this.signature,
    required this.signedHeaders,
    required this.credentialScope,
    required this.canonicalRequest,
    required this.stringToSign,
  });
}

class S3SyncTarget implements SyncTarget {
  /// Service endpoint, e.g. `https://s3.us-east-1.amazonaws.com` (AWS),
  /// `http://localhost:9000` (MinIO) or `https://s3.us-west-002.backblazeb2.com`.
  final Uri endpoint;
  final String region;
  final String bucket;
  final String accessKey;
  final String secretKey;

  /// Path-style addressing (`<endpoint>/<bucket>/<key>`) instead of the
  /// default virtual-host style (`<bucket>.<endpoint>/<key>`). MinIO and
  /// some self-hosted gateways require path-style.
  final bool pathStyle;

  final http.Client _client;
  final bool _ownsClient;

  /// [client] is injectable for tests (e.g. `package:http/testing.dart`
  /// MockClient). When omitted a real client is created and owned by this
  /// instance ([close] disposes it).
  S3SyncTarget({
    required this.endpoint,
    required this.region,
    required this.bucket,
    required this.accessKey,
    required this.secretKey,
    this.pathStyle = false,
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  void close() {
    if (_ownsClient) _client.close();
  }

  static const String _service = 's3';
  static const String _algorithm = 'AWS4-HMAC-SHA256';

  /// SHA-256 of the empty payload — the `x-amz-content-sha256` value for
  /// bodyless requests (GET / DELETE / HEAD / list).
  static const String _emptyPayloadSha256 =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  // URI construction

  /// Build the request URI for [key] (slash-separated object key, may be
  /// empty for bucket-scoped requests) with optional [query] parameters.
  Uri _bucketUri({String key = '', Map<String, String>? query}) {
    final keySegments = key.split('/').where((s) => s.isNotEmpty).toList();
    final segments = pathStyle ? <String>[bucket, ...keySegments] : keySegments;
    final host = pathStyle ? endpoint.host : '$bucket.${endpoint.host}';
    final base = endpoint.replace(host: host, pathSegments: segments);
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: query);
  }

  /// The `Host` header value `package:http` will send for [uri] — host,
  /// plus `:port` when it differs from the scheme default. The signed
  /// host header must match the transmitted one byte-for-byte.
  static String _hostHeader(Uri uri) {
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    if (uri.hasPort && uri.port != 0 && uri.port != defaultPort) {
      return '${uri.host}:${uri.port}';
    }
    return uri.host;
  }

  // AWS Signature Version 4

  /// RFC 3986 percent-encoding per AWS's `UriEncode`: unreserved chars
  /// (`A-Z a-z 0-9 - _ . ~`) pass through, everything else is %-encoded
  /// with uppercase hex. `/` is preserved when [encodeSlash] is false
  /// (object key paths) and encoded when true (query components).
  static String _uriEncode(String input, {required bool encodeSlash}) {
    final out = StringBuffer();
    for (final byte in utf8.encode(input)) {
      final isUnreserved =
          (byte >= 0x41 && byte <= 0x5A) || // A-Z
          (byte >= 0x61 && byte <= 0x7A) || // a-z
          (byte >= 0x30 && byte <= 0x39) || // 0-9
          byte == 0x2D || // -
          byte == 0x5F || // _
          byte == 0x2E || // .
          byte == 0x7E; // ~
      if (isUnreserved) {
        out.writeCharCode(byte);
      } else if (byte == 0x2F && !encodeSlash) {
        out.writeCharCode(byte); // '/'
      } else {
        out.write('%');
        out.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return out.toString();
  }

  static String _canonicalUri(Uri uri) {
    final segments = uri.pathSegments;
    if (segments.where((s) => s.isNotEmpty).isEmpty) return '/';
    return '/${segments.map((s) => _uriEncode(s, encodeSlash: true)).join('/')}';
  }

  static String _canonicalQuery(Uri uri) {
    if (uri.query.isEmpty) return '';
    final pairs = <MapEntry<String, String>>[];
    uri.queryParametersAll.forEach((key, values) {
      final encKey = _uriEncode(key, encodeSlash: true);
      for (final value in values) {
        pairs.add(MapEntry(encKey, _uriEncode(value, encodeSlash: true)));
      }
    });
    pairs.sort((a, b) {
      final byKey = a.key.compareTo(b.key);
      return byKey != 0 ? byKey : a.value.compareTo(b.value);
    });
    return pairs.map((e) => '${e.key}=${e.value}').join('&');
  }

  /// Format [time] as an ISO-8601 basic UTC timestamp (`20130524T000000Z`).
  static String _amzDate(DateTime time) {
    final u = time.toUtc();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}${p2(u.month)}${p2(u.day)}'
        'T${p2(u.hour)}${p2(u.minute)}${p2(u.second)}Z';
  }

  static List<int> _hmacBytes(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  static String _hmacHex(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).toString();

  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  /// Compute the AWS4-HMAC-SHA256 signature for a request.
  ///
  /// [headers] is the exact set of headers to sign (names are lowercased
  /// and trimmed); [payloadHash] is the hex `x-amz-content-sha256` value.
  /// Exposed for unit tests that pin AWS's published example vectors.
  @visibleForTesting
  static SigV4Signature computeSigV4({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required String payloadHash,
    required String accessKey,
    required String secretKey,
    required String region,
    required DateTime time,
    String service = _service,
  }) {
    final amzDate = _amzDate(time);
    final dateStamp = amzDate.substring(0, 8);

    final canonicalHeaderEntries =
        headers.entries
            .map((e) => MapEntry(e.key.toLowerCase().trim(), e.value.trim()))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    final canonicalHeaders = canonicalHeaderEntries
        .map((e) => '${e.key}:${e.value}\n')
        .join();
    final signedHeaders = canonicalHeaderEntries.map((e) => e.key).join(';');

    final canonicalRequest = [
      method,
      _canonicalUri(uri),
      _canonicalQuery(uri),
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final credentialScope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = [
      _algorithm,
      amzDate,
      credentialScope,
      _sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    final kDate = _hmacBytes(utf8.encode('AWS4$secretKey'), dateStamp);
    final kRegion = _hmacBytes(kDate, region);
    final kService = _hmacBytes(kRegion, service);
    final kSigning = _hmacBytes(kService, 'aws4_request');
    final signature = _hmacHex(kSigning, stringToSign);

    final authorization =
        '$_algorithm Credential=$accessKey/$credentialScope, '
        'SignedHeaders=$signedHeaders, Signature=$signature';

    return SigV4Signature(
      authorization: authorization,
      signature: signature,
      signedHeaders: signedHeaders,
      credentialScope: credentialScope,
      canonicalRequest: canonicalRequest,
      stringToSign: stringToSign,
    );
  }

  // Signed transport

  /// Sign and send [method] [uri]. [extraHeaders] (e.g. `Content-Type`)
  /// are transmitted but intentionally not signed — S3 only requires the
  /// declared SignedHeaders (host, x-amz-date, x-amz-content-sha256) to
  /// match. Network-layer failures are mapped to
  /// [SyncTargetErrorKind.network].
  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? extraHeaders,
    List<int>? bodyBytes,
  }) async {
    final payloadHash = bodyBytes == null
        ? _emptyPayloadSha256
        : _sha256Hex(bodyBytes);
    final now = DateTime.now().toUtc();
    final amzDate = _amzDate(now);
    final signedHeaders = <String, String>{
      'host': _hostHeader(uri),
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
    };
    final signature = computeSigV4(
      method: method,
      uri: uri,
      headers: signedHeaders,
      payloadHash: payloadHash,
      accessKey: accessKey,
      secretKey: secretKey,
      region: region,
      time: now,
    );

    final request = http.Request(method, uri);
    request.headers['x-amz-date'] = amzDate;
    request.headers['x-amz-content-sha256'] = payloadHash;
    request.headers['Authorization'] = signature.authorization;
    if (extraHeaders != null) request.headers.addAll(extraHeaders);
    if (bodyBytes != null) request.bodyBytes = bodyBytes;

    try {
      final streamed = await _client.send(request);
      return http.Response.fromStream(streamed);
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
        'authentication failed — check access key/secret and permissions',
      SyncTargetErrorKind.notFound => 'remote key or bucket not found',
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

  // SyncTarget contract

  /// No-op: object stores have no directory objects (see the file-level
  /// doc). A prefix exists implicitly once a key under it is written.
  @override
  Future<void> ensureDirectory(String path) async {}

  @override
  Future<void> uploadFile(String path, List<int> bytes) async {
    final response = await _send(
      'PUT',
      _bucketUri(key: path),
      extraHeaders: {'Content-Type': 'application/octet-stream'},
      bodyBytes: bytes,
    );
    final status = response.statusCode;
    if (status == 200 || status == 201 || status == 204) return;
    _throwForStatus(response, 'Upload "$path"');
  }

  @override
  Future<List<int>> downloadFile(String path) async {
    final response = await _send('GET', _bucketUri(key: path));
    if (response.statusCode == 200) return response.bodyBytes;
    _throwForStatus(response, 'Download "$path"');
  }

  @override
  Future<void> deleteFile(String path) async {
    final response = await _send('DELETE', _bucketUri(key: path));
    final status = response.statusCode;
    // S3 answers 204 whether or not the key existed; a missing-key delete
    // is therefore a natural no-op. 200 is accepted defensively.
    if (status == 200 || status == 204 || status == 404) return;
    _throwForStatus(response, 'Delete "$path"');
  }

  @override
  Future<void> testConnection() async {
    final response = await _send(
      'GET',
      _bucketUri(query: {'list-type': '2', 'max-keys': '0'}),
    );
    if (response.statusCode == 200) return;
    _throwForStatus(response, 'Connection test');
  }

  @override
  Future<List<SyncRemoteEntry>> listDirectory(String path) async {
    final normalized = path.split('/').where((s) => s.isNotEmpty).join('/');
    final prefix = normalized.isEmpty ? '' : '$normalized/';

    final entries = <SyncRemoteEntry>[];
    String? continuationToken;
    do {
      final query = <String, String>{
        'list-type': '2',
        'delimiter': '/',
        if (prefix.isNotEmpty) 'prefix': prefix,
        if (continuationToken != null) 'continuation-token': continuationToken,
      };
      final response = await _send('GET', _bucketUri(query: query));
      if (response.statusCode != 200) {
        _throwForStatus(response, 'List "$path"');
      }
      final body = response.body;

      for (final match in _contentsBlock.allMatches(body)) {
        final block = match.group(0)!;
        final keyMatch = _element('Key').firstMatch(block);
        if (keyMatch == null) continue;
        final key = _xmlUnescape(keyMatch.group(1)!.trim());
        // Skip the zero-byte prefix marker that represents the directory
        // itself (a key exactly equal to the prefix).
        if (key.isEmpty || key == prefix) continue;
        final name = key.split('/').where((s) => s.isNotEmpty).last;

        int? sizeBytes;
        final sizeMatch = _element('Size').firstMatch(block);
        if (sizeMatch != null) {
          sizeBytes = int.tryParse(sizeMatch.group(1)!.trim());
        }

        DateTime? modified;
        final modifiedMatch = _element('LastModified').firstMatch(block);
        if (modifiedMatch != null) {
          modified = DateTime.tryParse(modifiedMatch.group(1)!.trim())?.toUtc();
        }

        entries.add(
          SyncRemoteEntry(
            name: name,
            isDirectory: false,
            sizeBytes: sizeBytes,
            modified: modified,
          ),
        );
      }

      for (final match in _commonPrefixesBlock.allMatches(body)) {
        final block = match.group(0)!;
        final prefixMatch = _element('Prefix').firstMatch(block);
        if (prefixMatch == null) continue;
        var sub = _xmlUnescape(prefixMatch.group(1)!.trim());
        while (sub.endsWith('/')) {
          sub = sub.substring(0, sub.length - 1);
        }
        if (sub.isEmpty) continue;
        final name = sub.split('/').where((s) => s.isNotEmpty).last;
        entries.add(SyncRemoteEntry(name: name, isDirectory: true));
      }

      final truncatedMatch = _element('IsTruncated').firstMatch(body);
      final truncated =
          truncatedMatch != null &&
          truncatedMatch.group(1)!.trim().toLowerCase() == 'true';
      if (truncated) {
        final tokenMatch = _element('NextContinuationToken').firstMatch(body);
        continuationToken = tokenMatch != null
            ? _xmlUnescape(tokenMatch.group(1)!.trim())
            : null;
      } else {
        continuationToken = null;
      }
    } while (continuationToken != null);

    return entries;
  }

  // List-objects-v2 XML parsing (tolerant element scanner, no XML dep)

  static final RegExp _contentsBlock = RegExp(
    r'<(?:[A-Za-z0-9_-]+:)?Contents[\s>].*?</(?:[A-Za-z0-9_-]+:)?Contents>',
    dotAll: true,
  );
  static final RegExp _commonPrefixesBlock = RegExp(
    r'<(?:[A-Za-z0-9_-]+:)?CommonPrefixes[\s>].*?'
    r'</(?:[A-Za-z0-9_-]+:)?CommonPrefixes>',
    dotAll: true,
  );

  static RegExp _element(String localName) => RegExp(
    '<(?:[A-Za-z0-9_-]+:)?$localName[^>]*>(.*?)'
    '</(?:[A-Za-z0-9_-]+:)?$localName>',
    dotAll: true,
  );

  static String _xmlUnescape(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

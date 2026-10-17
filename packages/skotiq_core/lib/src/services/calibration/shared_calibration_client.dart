// HTTP client for a hub's shared calibration library
// (`/v1/calibration/masters`).
//
// Mirrors [ConstellationClient]'s transport verbatim: nothing but
// `package:http`, a single `_send` / `_sendFile` choke point mapping
// `SocketException`/`ClientException`/timeouts onto a typed
// [ConstellationException], and a `_throwForStatus` that classifies the HTTP
// status. The calibration tuple + license ride as query params, the
// `Provenance` JSON as the base64-encoded `x-provenance-json` header (ASCII-safe
// so non-Latin-1 attribution survives dart:io's header validation), and the
// master FITS as the `application/octet-stream` body (streamed from disk on
// publish), exactly as the hub's handlers expect.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, SocketException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/calibration/calibration_library_models.dart';
import '../../models/calibration/shared_calibration_models.dart';
import '../../models/collaboration/collaboration_models.dart';
import '../constellation/constellation_models.dart';

/// One downloaded shared master: its FITS [bytes] plus the hub's AUTHORITATIVE
/// record of what those bytes are ([master]).
///
/// The two travel together deliberately. The bytes alone say nothing about the
/// capture tuple they must be filed under, and the caller's copy of that tuple
/// is untrustworthy (it round-trips through a REST client). [master] is the
/// hub's own row, so the accepting device can file the master under the tuple
/// the producer actually published. It is null only when the hub sent no
/// `x-master-meta` header.
class SharedCalibrationDownload {
  const SharedCalibrationDownload({required this.bytes, this.master});

  /// The master FITS bytes.
  final Uint8List bytes;

  /// The hub's authoritative row for this master, or null when the hub did not
  /// supply one.
  final SharedCalibrationMaster? master;
}

/// Thin REST client for one hub's shared calibration library (one account /
/// bearer token).
class SharedCalibrationClient {
  /// Hub root, e.g. `https://hub.example.org` or `http://192.168.1.20:8088`.
  /// The `/v1` base path is appended internally.
  final Uri hubBaseUrl;

  /// Account bearer token (scopes `contribute` / `read`, plus the per-action
  /// `calibration.publish` / `calibration.download` grants).
  final String bearerToken;

  final http.Client _client;
  final bool _ownsClient;
  final Duration _timeout;

  /// [client] is injectable for tests (`package:http/testing.dart` MockClient).
  SharedCalibrationClient({
    required this.hubBaseUrl,
    required this.bearerToken,
    http.Client? client,
    Duration timeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _timeout = timeout;

  void close() {
    if (_ownsClient) _client.close();
  }

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer $bearerToken',
  };

  Uri _v1(String relPath, [Map<String, String>? query]) {
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

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? bodyBytes,
  }) async {
    final request = http.Request(method, uri);
    request.headers.addAll(_authHeaders);
    if (headers != null) request.headers.addAll(headers);
    if (bodyBytes != null) request.bodyBytes = bodyBytes;
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      return await http.Response.fromStream(streamed);
    } on ConstellationException {
      rethrow;
    } on SocketException catch (e) {
      throw ConstellationException(
        'Cannot reach ${uri.host}: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on http.ClientException catch (e) {
      throw ConstellationException(
        'Request to ${uri.host} failed: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on TimeoutException {
      throw ConstellationException(
        'Request to ${uri.host} timed out',
        kind: ConstellationErrorKind.network,
      );
    }
  }

  Future<http.Response> _sendFile(
    String method,
    Uri uri,
    File file, {
    Map<String, String>? headers,
  }) async {
    final length = await file.length();
    final request = http.StreamedRequest(method, uri);
    request.headers.addAll(_authHeaders);
    if (headers != null) request.headers.addAll(headers);
    request.contentLength = length;
    unawaited(
      file
          .openRead()
          .forEach(request.sink.add)
          .whenComplete(request.sink.close),
    );
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      return await http.Response.fromStream(streamed);
    } on ConstellationException {
      rethrow;
    } on SocketException catch (e) {
      throw ConstellationException(
        'Cannot reach ${uri.host}: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on http.ClientException catch (e) {
      throw ConstellationException(
        'Request to ${uri.host} failed: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on TimeoutException {
      throw ConstellationException(
        'Request to ${uri.host} timed out',
        kind: ConstellationErrorKind.network,
      );
    }
  }

  Never _throwForStatus(http.Response response, String operation) {
    final status = response.statusCode;
    final kind = switch (status) {
      401 || 403 => ConstellationErrorKind.auth,
      404 => ConstellationErrorKind.notFound,
      405 || 423 => ConstellationErrorKind.conflict,
      400 || 409 => ConstellationErrorKind.protocol,
      >= 500 => ConstellationErrorKind.server,
      _ => ConstellationErrorKind.unknown,
    };
    final body = response.body.trim();
    throw ConstellationException(
      '$operation failed (HTTP $status)'
      '${body.isEmpty ? '' : ' — $body'}',
      kind: kind,
      statusCode: status,
    );
  }

  Map<String, dynamic> _decodeJson(http.Response response, String operation) {
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

  // Endpoints

  /// `GET /v1/calibration/masters` — ranked remote masters matching [context]'s
  /// sensor + capture tuple. The hub returns the coarse sensor-keyed set; the
  /// caller re-scores + applies the full quality gate. [masterType] optionally
  /// narrows to one type (`dark` | `bias` | `flat`).
  Future<List<SharedCalibrationMaster>> queryMasters(
    LightFrameContext context, {
    String? masterType,
    int limit = 50,
  }) async {
    final query = <String, String>{
      if (context.cameraId != null && context.cameraId!.trim().isNotEmpty)
        'camera': context.cameraId!.trim(),
      // A gain/offset the lights never recorded is omitted rather than sent as
      // 0: the hub would otherwise return the gain-0 shelf as if that were what
      // was asked for. Omitted, the hub's coarse set stays unnarrowed on that
      // dimension and the local re-score reports it unverified.
      if (context.gain != null) 'gain': '${context.gain}',
      if (context.offset != null) 'offset': '${context.offset}',
      'binX': '${context.binX}',
      'binY': '${context.binY}',
      'limit': '$limit',
      if (masterType != null && masterType.isNotEmpty) 'masterType': masterType,
    };
    final response = await _send('GET', _v1('calibration/masters', query));
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Query calibration masters');
    }
    final body = _decodeJson(response, 'Query calibration masters');
    final list = body['masters'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(SharedCalibrationMaster.fromJson)
        .toList(growable: false);
  }

  /// `POST /v1/calibration/masters` — publish a master (consent-gated by the
  /// shareable [license]). Streams [filePath]'s bytes; the tuple rides as query
  /// params and the [provenance] JSON as the base64-encoded `x-provenance-json`
  /// header (ASCII-safe; the hub re-stamps its identity fields from the
  /// authenticated principal).
  Future<SharedCalibrationMaster> publishMaster({
    required String masterType,
    required String cameraModel,
    required ContributionLicense license,
    required String filePath,
    required Provenance provenance,
    int sensorWidth = 0,
    int sensorHeight = 0,
    int gain = 0,
    int offset = 0,
    double exposureSeconds = 0,
    double? temperatureC,
    int binX = 1,
    int binY = 1,
    String? filter,
    String? opticalTrain,
    int frameCount = 0,
    double? darkCurrent,
  }) async {
    final metadataProblems = <String>[
      if (cameraModel.trim().isEmpty) 'camera model is missing',
      if (sensorWidth <= 0 || sensorHeight <= 0)
        'sensor dimensions must be positive',
      if (binX <= 0 || binY <= 0) 'binning must be positive',
      if (frameCount <= 0) 'frame count must be positive',
      if (!exposureSeconds.isFinite || exposureSeconds < 0)
        'exposure must be a finite non-negative value',
      if ((masterType == 'dark' || masterType == 'flat') &&
          exposureSeconds <= 0)
        '$masterType exposure must be greater than zero',
      if (gain < 0) 'gain cannot be negative',
      if (offset < 0) 'offset cannot be negative',
    ];
    if (metadataProblems.isNotEmpty) {
      throw ConstellationException(
        'Cannot publish calibration master: ${metadataProblems.join('; ')}.',
        kind: ConstellationErrorKind.protocol,
      );
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      throw ConstellationException(
        'Master not found: $filePath',
        kind: ConstellationErrorKind.notFound,
      );
    }
    final query = <String, String>{
      'masterType': masterType,
      'camera': cameraModel,
      'license': license.wireName,
      'sensorWidth': '$sensorWidth',
      'sensorHeight': '$sensorHeight',
      'gain': '$gain',
      'offset': '$offset',
      'exposureSeconds': '$exposureSeconds',
      if (temperatureC != null) 'temperatureC': '$temperatureC',
      'binX': '$binX',
      'binY': '$binY',
      if (filter != null && filter.isNotEmpty) 'filter': filter,
      if (opticalTrain != null && opticalTrain.isNotEmpty)
        'opticalTrain': opticalTrain,
      'frameCount': '$frameCount',
      if (darkCurrent != null) 'darkCurrent': '$darkCurrent',
    };
    final response = await _sendFile(
      'POST',
      _v1('calibration/masters', query),
      file,
      headers: {
        'Content-Type': 'application/octet-stream',
        // Transport the provenance JSON as base64(utf8(...)) so a non-Latin-1
        // attribution / camera model / notes value (CJK, emoji, …) survives
        // dart:io's ASCII-only HTTP header validation — a raw jsonEncode is NOT
        // header-safe and dart:io throws `FormatException: Invalid HTTP header
        // field value` on it. The hub base64-decodes it before stamping.
        'x-provenance-json': base64.encode(
          utf8.encode(provenance.toJsonString()),
        ),
      },
    );
    final status = response.statusCode;
    if (status != 200 && status != 201) {
      _throwForStatus(response, 'Publish calibration master');
    }
    return SharedCalibrationMaster.fromJson(
      _decodeJson(response, 'Publish calibration master'),
    );
  }

  /// `GET /v1/calibration/masters/<id>/file` — download a chosen master's bytes
  /// (download-on-accept), together with the hub's AUTHORITATIVE record of the
  /// master's matching tuple from the `x-master-meta` header.
  ///
  /// The metadata is what makes the download trustworthy: the caller's copy of
  /// the record travelled through an untrusted round trip (a REST client posts
  /// the match result back to `/api/calibration-library/accept`), so the tuple
  /// the bytes are FILED under must come from the hub, not from the caller.
  /// [SharedCalibrationDownload.master] is null only when the hub sent no
  /// `x-master-meta` (or an unparseable one); callers that use the tuple must
  /// treat that as a refusal rather than falling back to the caller's copy.
  Future<SharedCalibrationDownload> downloadMasterBytes(String remoteId) async {
    final response = await _send(
      'GET',
      _v1('calibration/masters/$remoteId/file'),
    );
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Download calibration master $remoteId');
    }
    return SharedCalibrationDownload(
      bytes: response.bodyBytes,
      master: _decodeMasterMeta(response.headers['x-master-meta']),
    );
  }

  /// Decode the `x-master-meta` header (base64(utf8(json)) of the hub's
  /// authoritative master row) into a [SharedCalibrationMaster], or null when
  /// the header is absent / not decodable.
  static SharedCalibrationMaster? _decodeMasterMeta(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(base64.decode(raw)));
      if (decoded is! Map) return null;
      return SharedCalibrationMaster.fromJson(decoded.cast<String, dynamic>());
    } on Object {
      return null;
    }
  }

  /// `DELETE /v1/calibration/masters/<id>` — retract a published master.
  Future<void> deleteMaster(String remoteId) async {
    final response = await _send(
      'DELETE',
      _v1('calibration/masters/$remoteId'),
    );
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Delete calibration master $remoteId');
    }
  }
}

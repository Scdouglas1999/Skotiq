import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:skotiq_remote_protocol/wire.dart';

const jsonContentType = 'application/json';
const jsonResponseHeaders = {'content-type': jsonContentType};

/// Indicates whether an idempotent stop or abort changed an active operation.
/// Existing `status` fields remain unchanged for wire compatibility.
const String kWasRunningField = 'wasRunning';

/// Maps non-finite numbers, which JSON cannot represent, to `null`.
/// Other custom objects retain `jsonEncode`'s normal `toJson` behavior.
Object? _jsonSafe(Object? value) {
  if (value is double && !value.isFinite) return null;
  return (value as dynamic).toJson();
}

Response jsonResponse(
  Object? body, {
  int statusCode = 200,
  Map<String, String>? headers,
}) {
  return Response(
    statusCode,
    body: jsonEncode(body, toEncodable: _jsonSafe),
    headers: {...jsonResponseHeaders, if (headers != null) ...headers},
  );
}

Response jsonOk(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, headers: headers);
}

Response jsonCreated(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 201, headers: headers);
}

Response jsonBadRequest(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 400, headers: headers);
}

Response jsonUnauthorized(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 401, headers: headers);
}

Response jsonForbidden(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 403, headers: headers);
}

Response jsonNotFound(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 404, headers: headers);
}

Response jsonConflict(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 409, headers: headers);
}

Response jsonTooLarge(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 413, headers: headers);
}

Response jsonUpgradeRequired(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 426, headers: headers);
}

Response jsonRateLimited(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 429, headers: headers);
}

Response jsonInternalServerError(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 500, headers: headers);
}

Response jsonNotImplemented(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 501, headers: headers);
}

Response jsonServiceUnavailable(Object? body, {Map<String, String>? headers}) {
  return jsonResponse(body, statusCode: 503, headers: headers);
}

/// Emits the legacy `error` field alongside canonical `code` and `message`.
/// Canonical keys override collisions in [details].
Response jsonError({
  required String code,
  required String message,
  Map<String, dynamic>? details,
  int statusCode = 500,
  Map<String, String>? headers,
}) {
  return jsonResponse(
    ApiErrorBody(code: code, message: message, details: details).toJson(),
    statusCode: statusCode,
    headers: headers,
  );
}

Response contentResponse(
  Object? body, {
  required String contentType,
  int? contentLength,
  Map<String, String>? headers,
}) {
  return Response.ok(
    body,
    headers: {
      'content-type': contentType,
      if (contentLength != null) 'content-length': contentLength.toString(),
      if (headers != null) ...headers,
    },
  );
}

Response streamResponse(
  Object? body, {
  required String contentType,
  int? contentLength,
  Map<String, String>? headers,
  Map<String, Object>? context,
}) {
  return Response.ok(
    body,
    headers: {
      'content-type': contentType,
      if (contentLength != null) 'content-length': contentLength.toString(),
      if (headers != null) ...headers,
    },
    context: context,
  );
}

Response noContentResponse({Map<String, String>? headers}) {
  return Response(204, headers: headers);
}

Response attachmentResponse(
  Object? body, {
  required String fileName,
  required String contentType,
  int? contentLength,
  Map<String, String>? headers,
}) {
  return contentResponse(
    body,
    contentType: contentType,
    contentLength: contentLength,
    headers: {
      'content-disposition': attachmentDisposition(fileName),
      if (headers != null) ...headers,
    },
  );
}

/// 206 Partial Content response for HTTP Range requests (RFC 7233).
///
/// [body] is the stream/bytes covering exactly the requested byte range.
/// [start] / [end] are inclusive byte offsets within the full resource;
/// [totalLength] is the full resource size (NOT the slice length). The
/// returned slice length is `end - start + 1` and must match what [body]
/// emits or the client will see a truncated download.
Response partialContentResponse(
  Object? body, {
  required int start,
  required int end,
  required int totalLength,
  required String contentType,
  String? fileName,
  Map<String, String>? headers,
}) {
  final sliceLength = end - start + 1;
  return Response(
    206,
    body: body,
    headers: {
      'content-type': contentType,
      'content-length': sliceLength.toString(),
      'content-range': 'bytes $start-$end/$totalLength',
      'accept-ranges': 'bytes',
      if (fileName != null)
        'content-disposition': attachmentDisposition(fileName),
      if (headers != null) ...headers,
    },
  );
}

/// 416 Requested Range Not Satisfiable per RFC 7233 §4.4. The
/// `content-range: bytes */N` header tells the client the resource size
/// so they can re-issue a valid range request.
Response rangeNotSatisfiableResponse(int totalLength, {String? reason}) {
  return Response(
    416,
    body: jsonEncode({
      'error': 'range_not_satisfiable',
      'totalLength': totalLength,
      if (reason != null) 'reason': reason,
    }),
    headers: {
      'content-type': jsonContentType,
      'content-range': 'bytes */$totalLength',
      'accept-ranges': 'bytes',
    },
  );
}

/// Parse an RFC 7233 `Range` header value. Returns `null` if the header
/// is absent. Throws [FormatException] for any malformed/unsupported
/// shape (multi-range, non-bytes unit, missing bounds, etc.) so callers
/// can map to 416. Returns the resolved inclusive `[start, end]` pair
/// against [totalLength].
({int start, int end}) parseRangeHeader(String headerValue, int totalLength) {
  final value = headerValue.trim();
  if (!value.startsWith('bytes=')) {
    throw const FormatException('Range unit must be "bytes"');
  }
  final spec = value.substring('bytes='.length).trim();
  if (spec.isEmpty) {
    throw const FormatException('Range header has no byte spec');
  }
  if (spec.contains(',')) {
    // Multi-range requests are explicitly out of scope.
    throw const FormatException('Multi-range requests are not supported');
  }
  final dashIdx = spec.indexOf('-');
  if (dashIdx < 0) {
    throw const FormatException('Range spec missing "-" separator');
  }
  final startStr = spec.substring(0, dashIdx).trim();
  final endStr = spec.substring(dashIdx + 1).trim();

  int start;
  int end;
  if (startStr.isEmpty) {
    // Suffix range: "bytes=-N" — last N bytes.
    if (endStr.isEmpty) {
      throw const FormatException('Range spec must specify start or suffix');
    }
    final suffix = int.tryParse(endStr);
    if (suffix == null || suffix <= 0) {
      throw const FormatException('Invalid suffix length');
    }
    if (suffix >= totalLength) {
      // Suffix >= total means the entire resource.
      start = 0;
      end = totalLength - 1;
    } else {
      start = totalLength - suffix;
      end = totalLength - 1;
    }
  } else {
    final parsedStart = int.tryParse(startStr);
    if (parsedStart == null || parsedStart < 0) {
      throw const FormatException('Invalid range start');
    }
    start = parsedStart;
    if (endStr.isEmpty) {
      // Open-ended: "bytes=START-" — from START to EOF.
      end = totalLength - 1;
    } else {
      final parsedEnd = int.tryParse(endStr);
      if (parsedEnd == null || parsedEnd < 0) {
        throw const FormatException('Invalid range end');
      }
      end = parsedEnd;
    }
    if (end >= totalLength) {
      // Per RFC 7233 §2.1, an end value >= length is clamped to length-1
      // when start is satisfiable. This is the standard "be liberal in
      // what you accept" handling.
      end = totalLength - 1;
    }
    if (start > end) {
      throw const FormatException('Range start exceeds end');
    }
  }

  if (start >= totalLength) {
    throw const FormatException('Range start beyond resource length');
  }
  return (start: start, end: end);
}

String attachmentDisposition(String fileName) {
  return 'attachment; filename="${safeAttachmentFilename(fileName)}"';
}

String safeAttachmentFilename(String fileName, {String fallback = 'download'}) {
  final leaf = fileName.split(RegExp(r'[\\/]')).last.trim();
  final source = leaf.isEmpty ? fallback : leaf;
  final sanitized = source
      .replaceAll(RegExp(r'[\x00-\x1F\x7F"]'), '_')
      .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_')
      .replaceAll(RegExp(r'\s+'), '_');
  final withoutDots = sanitized.replaceAll(RegExp(r'^\.+'), '');
  final result = withoutDots.isEmpty ? fallback : withoutDots;
  return result.length <= 120 ? result : result.substring(result.length - 120);
}

import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Structured JSON error envelope, mirroring `headless_api/response_helpers.dart`
/// conventions. Every non-2xx hub response carries `{ "error": { "code", …,
/// "message" }, "requestId" }` so clients can branch on a stable machine code.
class HubError {
  const HubError(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  Response toResponse({String? requestId, Map<String, String>? headers}) {
    return Response(
      statusCode,
      body: jsonEncode(<String, Object?>{
        'error': <String, Object?>{'code': code, 'message': message},
        if (requestId != null) 'requestId': requestId,
      }),
      headers: <String, String>{
        'content-type': 'application/json',
        if (headers != null) ...headers,
      },
    );
  }

  static HubError badRequest(String message) =>
      HubError(400, 'badRequest', message);
  static HubError unauthorized(String message) =>
      HubError(401, 'unauthorized', message);
  static HubError forbidden(String message) =>
      HubError(403, 'forbidden', message);
  static HubError notFound(String message) =>
      HubError(404, 'notFound', message);
  static HubError conflict(String code, String message) =>
      HubError(409, code, message);
  static HubError payloadTooLarge(String message) =>
      HubError(413, 'payloadTooLarge', message);
  static HubError rateLimited(String message) =>
      HubError(429, 'rateLimited', message);
  static HubError internal(String message) =>
      HubError(500, 'internal', message);
}

/// A 200/201 JSON response with the hub's standard content type.
Response hubJson(
  Object? body, {
  int statusCode = 200,
  Map<String, String>? headers,
}) {
  return Response(
    statusCode,
    body: jsonEncode(body),
    headers: <String, String>{
      'content-type': 'application/json',
      if (headers != null) ...headers,
    },
  );
}

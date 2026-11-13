import 'package:skotiq_remote_protocol/wire.dart' show ApiErrorBody;

/// A failure the host answered a request with: the wire error body
/// ([ApiErrorBody]) and the HTTP status it came with.
class ServerError implements Exception {
  /// Machine-readable error code (e.g. 'pairing_required',
  /// 'rate_limited', 'device_busy'). Lower-snake_case by convention.
  final String code;

  /// Human-readable message intended for direct display.
  final String message;

  /// HTTP status code the response carried. Null when [ServerError] was
  /// constructed from a non-HTTP source (e.g. a WebSocket error frame
  /// that uses the same envelope shape).
  final int? httpStatus;

  /// Optional structured details map. Free-form per-endpoint, but always
  /// JSON-serializable so it can be logged and round-tripped over the
  /// wire intact.
  final Map<String, dynamic>? details;

  const ServerError({
    required this.code,
    required this.message,
    this.httpStatus,
    this.details,
  });

  /// The error in [json], or null when [json] is not an error body.
  static ServerError? tryFromJson(
    Map<String, dynamic> json, {
    int? httpStatus,
  }) {
    final body = ApiErrorBody.tryParse(json, httpStatus: httpStatus);
    if (body == null) return null;
    return ServerError(
      code: body.code,
      message: body.message,
      httpStatus: httpStatus,
      details: body.details?.cast<String, dynamic>(),
    );
  }

  /// True if the underlying status code indicates a client-side problem
  /// (auth, validation, rate limit, etc.). Used by the mobile SnackBar
  /// helper to choose an amber tint over the harsher red.
  bool get isClientError {
    final status = httpStatus;
    return status != null && status >= 400 && status < 500;
  }

  /// True if the underlying status code indicates a server-side failure.
  bool get isServerError {
    final status = httpStatus;
    return status != null && status >= 500;
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    if (httpStatus != null) 'httpStatus': httpStatus,
    if (details != null) 'details': details,
  };

  @override
  String toString() {
    final statusSuffix = httpStatus != null ? ' [HTTP $httpStatus]' : '';
    return '$message ($code)$statusSuffix';
  }
}

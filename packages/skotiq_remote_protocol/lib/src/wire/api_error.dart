/// The body of an error response from the host.
library;

/// How an error is laid out on the wire. Four layouts are in service and
/// clients in the field read each of them, so the host keeps writing the one
/// a route has always written; a reader accepts all four.
enum ApiErrorLayout {
  /// `{error: <code>, code, message, requestId?, ...details}`: thrown
  /// failures.
  codeAsError,

  /// `{...details, error: <message>, code, message}`: `error` repeats the
  /// message for clients that only display it.
  messageAsError,

  /// `{error: <code>, message, ...details}` with no `code` key. A few of
  /// these routes write a short summary under `error` ("Access denied")
  /// where the others write a code; it is read as the code all the same.
  errorAsCode,

  /// `{error: <message>}` with no code: the oldest bodies.
  prose,
}

class ApiErrorBody {
  const ApiErrorBody({
    required this.code,
    required this.message,
    this.layout = ApiErrorLayout.messageAsError,
    this.requestId,
    this.details,
  });

  /// Reads any of the four layouts. Returns null when [json] is not an
  /// error body: no text under `message` or `error`.
  ///
  /// A body that names no code is given one from [httpStatus].
  static ApiErrorBody? tryParse(Map<String, dynamic> json, {int? httpStatus}) {
    final explicitCode = _nonEmpty(json['code']);
    final messageField = _nonEmpty(json['message']);
    final errorField = _nonEmpty(json['error']);
    final message = messageField ?? errorField;
    if (message == null) return null;

    final ApiErrorLayout layout;
    final String code;
    if (explicitCode != null) {
      code = explicitCode;
      layout = errorField == explicitCode
          ? ApiErrorLayout.codeAsError
          : ApiErrorLayout.messageAsError;
    } else if (messageField != null && errorField != null) {
      code = errorField;
      layout = ApiErrorLayout.errorAsCode;
    } else {
      code = codeForStatus(httpStatus);
      layout = ApiErrorLayout.prose;
    }

    final rawDetails = json['details'];
    return ApiErrorBody(
      code: code,
      message: message,
      layout: layout,
      requestId: _nonEmpty(json['requestId']),
      details: rawDetails is Map ? rawDetails.cast<String, dynamic>() : null,
    );
  }

  /// The message of the 403 the host answers when a token is not one it
  /// knows. A client reads it to tell "re-pair" from a scope refusal, which
  /// is also a 403.
  static const String invalidTokenMessage = 'Invalid authentication token';

  /// Machine-readable name of the failure.
  final String code;

  /// What happened, written for the operator.
  final String message;

  final ApiErrorLayout layout;
  final String? requestId;

  /// Extra fields merged into the top level of the body.
  final Map<String, Object?>? details;

  Map<String, Object?> toJson() => switch (layout) {
    ApiErrorLayout.codeAsError => {
      'error': code,
      'code': code,
      'message': message,
      if (requestId != null) 'requestId': requestId,
      if (details != null) ...details!,
    },
    ApiErrorLayout.messageAsError => {
      if (details != null) ...details!,
      'error': message,
      'code': code,
      'message': message,
    },
    ApiErrorLayout.errorAsCode => {
      'error': code,
      'message': message,
      if (details != null) ...details!,
    },
    ApiErrorLayout.prose => {'error': message},
  };

  /// The code a prose body is given, from the status it came with.
  static String codeForStatus(int? httpStatus) => switch (httpStatus) {
    400 => 'bad_request',
    401 => 'unauthorized',
    403 => 'forbidden',
    404 => 'not_found',
    409 => 'conflict',
    413 => 'payload_too_large',
    426 => 'upgrade_required',
    429 => 'rate_limited',
    500 => 'internal_error',
    501 => 'not_implemented',
    503 => 'service_unavailable',
    _ => 'error',
  };

  static String? _nonEmpty(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

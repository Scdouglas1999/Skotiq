/// Request-body size ceilings and the Content-Length gate that enforces them.
library;

import 'dart:io';

bool methodCanHaveBody(String method) {
  return method == 'POST' || method == 'PUT' || method == 'PATCH';
}

Map<String, dynamic>? validateContentLength({
  required String method,
  required int limit,
  required String? contentLengthHeader,
}) {
  if (!methodCanHaveBody(method)) {
    return null;
  }

  if (contentLengthHeader == null || contentLengthHeader.isEmpty) {
    return null;
  }

  final contentLength = int.tryParse(contentLengthHeader);
  if (contentLength == null || contentLength < 0) {
    return {
      'statusCode': HttpStatus.badRequest,
      'body': {'error': 'Invalid Content-Length header'},
    };
  }

  if (contentLength <= limit) {
    return null;
  }

  return {
    'statusCode': HttpStatus.requestEntityTooLarge,
    'body': {
      'error': 'Request body too large',
      'maxBytes': limit,
      'contentLength': contentLength,
    },
  };
}

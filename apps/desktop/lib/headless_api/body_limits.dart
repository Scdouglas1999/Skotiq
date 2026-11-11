/// Request-body size ceilings and the Content-Length gate that enforces them.
library;

import 'dart:io';

const int oneMiB = 1024 * 1024;
const int defaultMaxRequestBodyBytes = oneMiB;
const int imageProcessingMaxRequestBodyBytes = 64 * oneMiB;
const int backupUploadMaxRequestBodyBytes = 256 * oneMiB;
// catalog archives are capped at 1 GiB per audit. HYG is
// ~35 MB decompressed, GLADE+ complete is ~2 GB so the cap rejects the
// full GLADE+ tier (operators must use the standard tier or stage the
// file out-of-band).
const int catalogUploadMaxRequestBodyBytes = 1024 * oneMiB;

bool methodCanHaveBody(String method) {
  return method == 'POST' || method == 'PUT' || method == 'PATCH';
}

int requestBodyLimitForPath(String path) {
  if (path == '/api/backup/upload-restore') {
    return backupUploadMaxRequestBodyBytes;
  }

  // calibration dark upload may carry a master dark up to ~200 MB
  // from a full-frame camera. Share the backup-upload cap so a single
  // ceiling governs all multipart-style uploads.
  if (path == '/api/calibration/darks/upload') {
    return backupUploadMaxRequestBodyBytes;
  }

  // catalog upload (air-gap install path).
  if (path == '/api/catalog/upload') {
    return catalogUploadMaxRequestBodyBytes;
  }

  // plugin archives are small (manifests + small code bundles),
  // but a few MB ceiling is reasonable so the operator can ship
  // assets alongside. Share the backup-upload cap.
  if (path == '/api/plugins/upload') {
    return backupUploadMaxRequestBodyBytes;
  }

  if (path == '/api/imaging/stats' ||
      path == '/api/imaging/stretch' ||
      path == '/api/imaging/debayer' ||
      path == '/api/imaging/save-fits') {
    return imageProcessingMaxRequestBodyBytes;
  }

  return defaultMaxRequestBodyBytes;
}

Map<String, dynamic>? validateContentLength({
  required String method,
  required String path,
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

  final limit = requestBodyLimitForPath(path);
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

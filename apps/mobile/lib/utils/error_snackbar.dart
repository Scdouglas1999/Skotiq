// Mobile SnackBar helper that knows how to render the headless server's
// structured error envelope.
//
// A catch block must route through here rather than rendering `Text('$e')`,
// which shows the operator an opaque string like "Exception: 502 status code
// from /api/x". [NetworkBackend] decodes the {code, message} envelope into a
// typed [ServerError]; this helper renders both halves with a
// severity-appropriate tint, so recoverable (amber 4xx) reads differently from
// broken (red 5xx).
//
// Usage pattern:
//
//     try { await someBackendCall(); }
//     catch (e) {
//       if (context.mounted) showApiError(context, e);
//     }
//
// The helper is null-safe against a disposed context (the caller must
// have checked `context.mounted` before invoking) but does NOT itself
// guard mounted state — that's the caller's responsibility because the
// helper has no way to recover from a tear-down race.

import 'package:flutter/material.dart';
import 'package:skotiq_app/utils/snackbar_helper.dart';
import 'package:skotiq_core/models.dart';

/// Show a SnackBar describing an API error.
///
/// When [error] is a [ServerError] the SnackBar renders
/// `"<message> (<code>)"` as a warning for 4xx and an error for 5xx (or
/// unknown status). Any other exception type falls back to
/// `error.toString()` as an error.
///
/// Duration scales with severity: 5xx/unknown stays visible for 6
/// seconds so the operator has time to read a critical failure; 4xx
/// fades after 4 seconds because those are often expected (rate limit,
/// pairing required) and the operator just needs the cue.
void showApiError(BuildContext context, Object error) {
  // Replace any in-flight error so a rapid burst of failures doesn't
  // stack up an unreadable queue.
  ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  if (error is ServerError) {
    final text = '${error.message} (${error.code})';
    if (error.isClientError) {
      context.showWarningSnackBar(text, duration: const Duration(seconds: 4));
    } else {
      context.showErrorSnackBar(text, duration: const Duration(seconds: 6));
    }
    return;
  }
  // The request never reached the structured-error path (a socket error,
  // a timeout, a local exception before the backend received it); the
  // operator still sees what happened.
  context.showErrorSnackBar(
    error.toString(),
    duration: const Duration(seconds: 6),
  );
}

/// Show a prefixed API error: `"<prefix>: <message> (<code>)"`.
///
/// Useful when the operator needs additional context that isn't in the
/// server's message ("Capture failed: rate limited (rate_limited)"). For
/// non-[ServerError] inputs, formats as `"<prefix>: <error>"`.
void showApiErrorWithPrefix(BuildContext context, String prefix, Object error) {
  if (error is ServerError) {
    showApiError(
      context,
      ServerError(
        code: error.code,
        message: '$prefix: ${error.message}',
        httpStatus: error.httpStatus,
        details: error.details,
      ),
    );
    return;
  }
  ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  context.showErrorSnackBar(
    '$prefix: $error',
    duration: const Duration(seconds: 6),
  );
}

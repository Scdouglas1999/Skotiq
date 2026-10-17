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
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Show a SnackBar describing an API error.
///
/// When [error] is a [ServerError] the SnackBar renders
/// `"<message> (<code>)"` with an amber background for 4xx and a red for
/// 5xx (or unknown status). Any other exception type falls back to
/// `error.toString()` with the generic red tint.
///
/// Duration scales with severity: 5xx/unknown stays visible for 6
/// seconds so the operator has time to read a critical failure; 4xx
/// fades after 4 seconds because those are often expected (rate limit,
/// pairing required) and the operator just needs the cue.
void showApiError(BuildContext context, Object error) {
  final colors = Theme.of(context).extension<SkotiqColors>();
  final theme = Theme.of(context);

  final String text;
  final Color background;
  final Color foreground;
  final Duration duration;

  if (error is ServerError) {
    text = '${error.message} (${error.code})';
    if (error.isClientError) {
      background = colors?.warning ?? const Color(0xFFFFA000);
      foreground = colors?.background ?? const Color(0xFF000000);
      duration = const Duration(seconds: 4);
    } else {
      background = colors?.error ?? theme.colorScheme.error;
      foreground = theme.colorScheme.onError;
      duration = const Duration(seconds: 6);
    }
  } else {
    // Why: the fallback path covers cases where the request never
    // reached the structured-error code path — socket errors, timeouts,
    // local exceptions thrown by Dart code before the backend even
    // received the request. We still want the operator to see what
    // happened, so fall back to the exception's own stringification.
    text = error.toString();
    background = colors?.error ?? theme.colorScheme.error;
    foreground = theme.colorScheme.onError;
    duration = const Duration(seconds: 6);
  }

  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    // No ScaffoldMessenger ancestor — caller is rendering inside a
    // dialog or outside the Material tree. Surfacing a SnackBar isn't
    // possible from here; the catch block must use a different
    // affordance (status text in the dialog body, for instance). Bail
    // silently rather than throwing.
    return;
  }
  // Replace any in-flight error so a rapid burst of failures doesn't
  // stack up an unreadable queue.
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: background,
      content: Text(text, style: TextStyle(color: foreground)),
      duration: duration,
    ),
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
  // Wrap a generic exception so the prefix lands in the text path of
  // showApiError too. We don't mutate `error` — Exception is opaque, so
  // we just stringify here.
  final colors = Theme.of(context).extension<SkotiqColors>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: colors?.error ?? Theme.of(context).colorScheme.error,
      content: Text(
        '$prefix: $error',
        style: TextStyle(color: Theme.of(context).colorScheme.onError),
      ),
      duration: const Duration(seconds: 6),
    ),
  );
}

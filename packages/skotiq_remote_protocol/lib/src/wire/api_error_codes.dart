/// The error codes a client acts on, declared once for the host, the Dart
/// clients and the browser pages.
library;

import 'dart:convert';

/// [ApiErrorBody.code]s a client branches on. The host writes them, the Dart
/// clients compare against them, and the browser pages read the same table
/// from `js/wire-errors.js` ([javaScript]).
abstract final class ApiErrorCodes {
  /// A 401 for a request that presents no credential.
  static const authRequired = 'auth_required';

  /// A 401 for an Authorization header that is not `Bearer <token>`.
  static const invalidAuthHeader = 'invalid_auth_header';

  /// A 401 for a socket ticket that is unknown, used or expired, or whose
  /// token no longer exists.
  static const invalidTicket = 'invalid_ticket';

  /// A 403 for a token the host does not know: the client has to pair again.
  static const invalidToken = 'invalid_token';

  /// A 403 for a token the host knows whose access level does not cover the
  /// route. The token still works for what it does cover.
  static const insufficientScope = 'insufficient_scope';

  /// A 426 for a request from another Skotiq release.
  static const versionMismatch = 'version_mismatch';

  /// A 426 for an API request that does not say which release sent it.
  static const releaseRequired = 'release_required';

  /// A 409 for a mount move refused because the guider does not answer.
  static const guiderNotAnswering = 'guider_not_answering';

  /// A 409 from the embedded API of a window that is linked to another host:
  /// the request belongs to that host.
  static const linkedToHost = 'linked_to_host';

  /// A 409 for a stop or pause with no sequence running.
  static const sequencerNotRunning = 'sequencer_not_running';

  /// A 409 for a resume or skip of a run a manual action holds paused: only
  /// the action's own release lets the run go on.
  static const runHeldByAction = 'run_held_by_action';

  /// A 409 for a manual action's release whose run another pause took over
  /// while the action held it: the hold is released and the run stays
  /// paused. `details.pausedBy` names that pause.
  static const runStillPaused = 'run_still_paused';

  /// Pairing refusals.
  static const invalidPairingCode = 'invalid_pairing_code';
  static const pairingCodeExpired = 'pairing_code_expired';
  static const pairingCodeAlreadyUsed = 'pairing_code_already_used';

  /// Every code above, by the name a page reads it under.
  static const Map<String, String> all = {
    'authRequired': authRequired,
    'invalidAuthHeader': invalidAuthHeader,
    'invalidTicket': invalidTicket,
    'invalidToken': invalidToken,
    'insufficientScope': insufficientScope,
    'versionMismatch': versionMismatch,
    'releaseRequired': releaseRequired,
    'guiderNotAnswering': guiderNotAnswering,
    'linkedToHost': linkedToHost,
    'sequencerNotRunning': sequencerNotRunning,
    'runHeldByAction': runHeldByAction,
    'runStillPaused': runStillPaused,
    'invalidPairingCode': invalidPairingCode,
    'pairingCodeExpired': pairingCodeExpired,
    'pairingCodeAlreadyUsed': pairingCodeAlreadyUsed,
  };

  /// The table as a browser script: `WIRE_ERROR_CODES.<name>`.
  static String javaScript() {
    final entries = [
      for (final MapEntry(:key, :value) in all.entries)
        '  $key: ${jsonEncode(value)},',
    ].join('\n');
    return "'use strict';\n\n"
        '// The error codes a page acts on, served by the host from\n'
        '// ApiErrorCodes (skotiq_remote_protocol). Do not copy them.\n'
        'const WIRE_ERROR_CODES = Object.freeze({\n$entries\n});\n';
  }
}

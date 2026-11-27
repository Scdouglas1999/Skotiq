'use strict';

// The error codes a page acts on, served by the host from
// ApiErrorCodes (skotiq_remote_protocol). Do not copy them.
const WIRE_ERROR_CODES = Object.freeze({
  authRequired: "auth_required",
  invalidAuthHeader: "invalid_auth_header",
  invalidTicket: "invalid_ticket",
  invalidToken: "invalid_token",
  insufficientScope: "insufficient_scope",
  versionMismatch: "version_mismatch",
  releaseRequired: "release_required",
  guiderNotAnswering: "guider_not_answering",
  linkedToHost: "linked_to_host",
  sequencerNotRunning: "sequencer_not_running",
  runHeldByAction: "run_held_by_action",
  runStillPaused: "run_still_paused",
  invalidPairingCode: "invalid_pairing_code",
  pairingCodeExpired: "pairing_code_expired",
  pairingCodeAlreadyUsed: "pairing_code_already_used",
});

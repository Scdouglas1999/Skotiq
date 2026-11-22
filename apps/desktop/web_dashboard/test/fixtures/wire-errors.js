'use strict';

// The error codes a page acts on, served by the host from
// ApiErrorCodes (skotiq_remote_protocol). Do not copy them.
const WIRE_ERROR_CODES = Object.freeze({
  invalidToken: "invalid_token",
  insufficientScope: "insufficient_scope",
  versionMismatch: "version_mismatch",
  releaseRequired: "release_required",
  guiderNotAnswering: "guider_not_answering",
  sequencerNotRunning: "sequencer_not_running",
  invalidPairingCode: "invalid_pairing_code",
  pairingCodeExpired: "pairing_code_expired",
  pairingCodeAlreadyUsed: "pairing_code_already_used",
});

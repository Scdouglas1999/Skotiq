/// Declarative route table for the sequencer / automation surface.
///
/// Counterpart to `handlers/sequencer_handlers.dart`. Covers the
/// canonical `/api/sequencer/*` action surface, the recovery
/// remote-control endpoints, and the cloud-motion / adaptive-
/// swap endpoints. CRUD on stored sequence definitions lives in
/// `sequence_management_routes.dart`.
library;

import '../handlers/sequencer_handlers.dart';
import 'headless_route.dart';

/// Build the declarative route table for [SequencerHandlers].
List<HeadlessRoute> buildSequencerRoutes(
  SequencerHandlers h,
) => <HeadlessRoute>[
  // Sequencing (extended)
  HeadlessRoute(
    HttpMethod.get,
    '/api/sequencer/status',
    h.handleSequencerStatus,
  ),
  // G2 (remote hydration): the master's currently-open editor canvas, in the
  // same payload shape the live WS editor mirror emits.
  HeadlessRoute(
    HttpMethod.get,
    '/api/sequencer/editor-sequence',
    h.handleSequencerEditorSequence,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/start',
    h.handleSequencerStart,
  ),
  HeadlessRoute(HttpMethod.post, '/api/sequencer/stop', h.handleSequencerStop),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/pause',
    h.handleSequencerPause,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/resume',
    h.handleSequencerResume,
  ),
  HeadlessRoute(HttpMethod.post, '/api/sequencer/skip', h.handleSequencerSkip),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/skip-to-node',
    h.handleSequencerSkipToNode,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/plugin-node-finished',
    h.handleSequencerPluginNodeFinished,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/reset',
    h.handleSequencerReset,
  ),
  HeadlessRoute(HttpMethod.post, '/api/sequencer/load', h.handleSequencerLoad),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/load-and-start',
    h.handleSequencerLoadAndStart,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/simulation',
    h.handleSequencerSetSimulationMode,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/devices',
    h.handleSequencerSetDevices,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/safety-fail-mode',
    h.handleSequencerSetSafetyFailMode,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/park-policy',
    h.handleSequencerSetParkPolicy,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/quality-policy',
    h.handleSequencerSetQualityPolicy,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/safety-check-interval',
    h.handleSequencerSetSafetyCheckInterval,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/save-path',
    h.handleSequencerSetSavePath,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/active-sequence-run-id',
    h.handleSequencerSetActiveSequenceRunId,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/decision-logging-enabled',
    h.handleSequencerSetDecisionLoggingEnabled,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-dither-config',
    h.handleSequencerUpdateDitherConfig,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-meridian-flip-config',
    h.handleSequencerUpdateMeridianFlipConfig,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-location',
    h.handleSequencerUpdateLocation,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-filter-offsets',
    h.handleSequencerUpdateFilterOffsets,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-pending-integration-carry-over',
    h.handleSequencerUpdatePendingIntegrationCarryOver,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-autofocus-interval',
    h.handleSequencerUpdateAutofocusInterval,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-autofocus-config',
    h.handleSequencerUpdateAutofocusConfig,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-default-quality-check',
    h.handleSequencerUpdateDefaultQualityCheck,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-reject-folder-path',
    h.handleSequencerUpdateRejectFolderPath,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-observer-profile',
    h.handleSequencerUpdateObserverProfile,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-sky-brightness',
    h.handleSequencerUpdateSkyBrightness,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-default-adaptive-exposure',
    h.handleSequencerUpdateDefaultAdaptiveExposure,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/clear-default-adaptive-exposure',
    h.handleSequencerClearDefaultAdaptiveExposure,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/checkpoint/dir',
    h.handleSequencerSetCheckpointDir,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/sequencer/checkpoint/has',
    h.handleSequencerHasCheckpoint,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/sequencer/checkpoint/info',
    h.handleSequencerGetCheckpointInfo,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/checkpoint/resume',
    h.handleSequencerResumeFromCheckpoint,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/checkpoint/discard',
    h.handleSequencerDiscardCheckpoint,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/checkpoint/save',
    h.handleSequencerSaveCheckpoint,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/meridian-flip',
    h.handlePerformMeridianFlip,
  ),

  // Recovery Mode — remote-control endpoints used by the
  // mobile companion / web dashboard. Wire shape matches
  // NetworkBackend's recovery POSTs/GETs (see
  // packages/nightshade_core/.../network_backend.dart).
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/recovery/try-now',
    h.handleSequencerRecoveryTryNow,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/recovery/abort',
    h.handleSequencerRecoveryAbort,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/recovery/update-config',
    h.handleSequencerUpdateRecoveryConfig,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/sequencer/recovery/current',
    h.handleSequencerGetCurrentRecovery,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/sequencer/recovery/history',
    h.handleSequencerGetRecoveryHistory,
  ),

  // cloud-motion forwarding from a remote controller.
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-cloud-motion',
    h.handleSequencerUpdateCloudMotion,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/sequencer/cloud-motion',
    h.handleSequencerGetCloudMotion,
  ),
  // Full-night audit 2026-06-04 (defense-in-depth) — weather-safety verdict
  // forwarding from a remote controller into the local executor.
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-weather-verdict',
    h.handleSequencerUpdateWeatherVerdict,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/update-conditions-score',
    h.handleSequencerUpdateConditionsScore,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/sequencer/adaptive-swap',
    h.handleSequencerGetAdaptiveSwap,
  ),

  // Dual-rig / secondary (piggyback) camera — monitor + control.
  HeadlessRoute(
    HttpMethod.get,
    '/api/sequencer/secondary-rig',
    h.handleSecondaryRigStatus,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/secondary-rig/start',
    h.handleSecondaryRigStart,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/sequencer/secondary-rig/stop',
    h.handleSecondaryRigStop,
  ),
];

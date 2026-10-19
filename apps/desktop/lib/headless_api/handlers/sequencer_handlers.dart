import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_api;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../../headless/host_checkpoint_directory.dart';
import '../command_correlator.dart';
import '../response_helpers.dart';
import '../sequence_wire_validation.dart';
import '../validation.dart';

part 'sequencer/sequencer_lifecycle_handlers.dart';
part 'sequencer/sequencer_start_preflight.dart';
part 'sequencer/sequencer_config_handlers.dart';
part 'sequencer/sequencer_checkpoint_handlers.dart';
part 'sequencer/sequencer_recovery_handlers.dart';
part 'sequencer/sequencer_conditions_handlers.dart';
part 'sequencer/sequencer_secondary_rig_handlers.dart';
part 'sequencer/wire_sequence_summary.dart';

/// Handlers for sequencer control endpoints
class SequencerHandlers {
  final ProviderContainer container;

  /// optional command correlator. When set, every action POST
  /// generates a UUID v4 commandId and includes it in the response.
  final CommandCorrelator? commandCorrelator;

  SequencerHandlers(this.container, {this.commandCorrelator});

  /// Device ids a caller assigned on purpose through
  /// `POST /api/sequencer/devices`, keyed by type. `null` records an explicit
  /// clear, which is why absence and `null` are kept distinct.
  ///
  /// Only that endpoint writes here — never the start-time wiring below. The
  /// map therefore holds *instructions*, not observations: "use this camera",
  /// not "this camera happened to be connected last time". Feeding wiring
  /// results back in would let a camera the operator has since unplugged
  /// survive as a phantom assignment.
  final Map<DeviceType, String?> _explicitlyAssignedDeviceIds = {};

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'SequencerHandlers');

  void _logWarning(String message) =>
      _logger.warning(message, source: 'SequencerHandlers');

  /// Metadata from the most recent `POST /api/sequencer/load`, used to open the
  /// `imaging_sessions` row for a headless run. Null before the first load.
  _WireSequenceSummary? _lastLoadedWire;

  // Routed entry points. Each forwards to the implementation in the part
  // file named above; the public method must live on the class itself
  // because `routes/sequencer_routes.dart` tears these off from another
  // library, where a library-private extension is invisible.
  Future<Response> handleSequencerStatus(Request request) =>
      _handleSequencerStatus(request);
  Future<Response> handleSequencerEditorSequence(Request request) =>
      _handleSequencerEditorSequence(request);
  Future<Response> handleSequencerStart(Request request) =>
      _handleSequencerStart(request);
  Future<Response> handleSequencerStop(Request request) =>
      _handleSequencerStop(request);
  Future<Response> handleSequencerPause(Request request) =>
      _handleSequencerPause(request);
  Future<Response> handleSequencerResume(Request request) =>
      _handleSequencerResume(request);
  Future<Response> handleSequencerSkip(Request request) =>
      _handleSequencerSkip(request);
  Future<Response> handleSequencerSkipToNode(Request request) =>
      _handleSequencerSkipToNode(request);
  Future<Response> handleSequencerPluginNodeFinished(Request request) =>
      _handleSequencerPluginNodeFinished(request);
  Future<Response> handleSequencerReset(Request request) =>
      _handleSequencerReset(request);
  Future<Response> handleSequencerLoad(Request request) =>
      _handleSequencerLoad(request);
  Future<Response> handleSequencerLoadAndStart(Request request) =>
      _handleSequencerLoadAndStart(request);
  Future<Response> handleSequencerSetSimulationMode(Request request) =>
      _handleSequencerSetSimulationMode(request);
  Future<Response> handleSequencerSetDevices(Request request) =>
      _handleSequencerSetDevices(request);
  Future<Response> handleSequencerSetSafetyFailMode(Request request) =>
      _handleSequencerSetSafetyFailMode(request);
  Future<Response> handleSequencerSetParkPolicy(Request request) =>
      _handleSequencerSetParkPolicy(request);
  Future<Response> handleSequencerSetDeviceRetries(Request request) =>
      _handleSequencerSetDeviceRetries(request);
  Future<Response> handleSequencerSetQualityPolicy(Request request) =>
      _handleSequencerSetQualityPolicy(request);
  Future<Response> handleSequencerSetSafetyCheckInterval(Request request) =>
      _handleSequencerSetSafetyCheckInterval(request);
  Future<Response> handleSequencerSetSavePath(Request request) =>
      _handleSequencerSetSavePath(request);
  Future<Response> handleSequencerSetActiveSequenceRunId(Request request) =>
      _handleSequencerSetActiveSequenceRunId(request);
  Future<Response> handleSequencerSetDecisionLoggingEnabled(Request request) =>
      _handleSequencerSetDecisionLoggingEnabled(request);
  Future<Response> handleSequencerUpdateDitherConfig(Request request) =>
      _handleSequencerUpdateDitherConfig(request);
  Future<Response> handleSequencerUpdateMeridianFlipConfig(Request request) =>
      _handleSequencerUpdateMeridianFlipConfig(request);
  Future<Response> handleSequencerUpdateLocation(Request request) =>
      _handleSequencerUpdateLocation(request);
  Future<Response> handleSequencerUpdateFilterOffsets(Request request) =>
      _handleSequencerUpdateFilterOffsets(request);
  Future<Response> handleSequencerUpdatePendingIntegrationCarryOver(
    Request request,
  ) => _handleSequencerUpdatePendingIntegrationCarryOver(request);
  Future<Response> handleSequencerUpdateAutofocusInterval(Request request) =>
      _handleSequencerUpdateAutofocusInterval(request);
  Future<Response> handleSequencerUpdateAutofocusConfig(Request request) =>
      _handleSequencerUpdateAutofocusConfig(request);
  Future<Response> handleSequencerUpdateDefaultQualityCheck(Request request) =>
      _handleSequencerUpdateDefaultQualityCheck(request);
  Future<Response> handleSequencerUpdateRejectFolderPath(Request request) =>
      _handleSequencerUpdateRejectFolderPath(request);
  Future<Response> handleSequencerUpdateObserverProfile(Request request) =>
      _handleSequencerUpdateObserverProfile(request);
  Future<Response> handleSequencerUpdateSkyBrightness(Request request) =>
      _handleSequencerUpdateSkyBrightness(request);
  Future<Response> handleSequencerUpdateDefaultAdaptiveExposure(
    Request request,
  ) => _handleSequencerUpdateDefaultAdaptiveExposure(request);
  Future<Response> handleSequencerClearDefaultAdaptiveExposure(
    Request request,
  ) => _handleSequencerClearDefaultAdaptiveExposure(request);
  Future<Response> handleSequencerSetCheckpointDir(Request request) =>
      _handleSequencerSetCheckpointDir(request);
  Future<Response> handleSequencerHasCheckpoint(Request request) =>
      _handleSequencerHasCheckpoint(request);
  Future<Response> handleSequencerGetCheckpointInfo(Request request) =>
      _handleSequencerGetCheckpointInfo(request);
  Future<Response> handleSequencerResumeFromCheckpoint(Request request) =>
      _handleSequencerResumeFromCheckpoint(request);
  Future<Response> handlePerformMeridianFlip(Request request) =>
      _handlePerformMeridianFlip(request);
  Future<Response> handleSequencerRequestMeridianFlip(Request request) =>
      _handleSequencerRequestMeridianFlip(request);
  Future<Response> handleSequencerDiscardCheckpoint(Request request) =>
      _handleSequencerDiscardCheckpoint(request);
  Future<Response> handleSequencerSaveCheckpoint(Request request) =>
      _handleSequencerSaveCheckpoint(request);
  Future<Response> handleSequencerRecoveryTryNow(Request request) =>
      _handleSequencerRecoveryTryNow(request);
  Future<Response> handleSequencerRecoveryAbort(Request request) =>
      _handleSequencerRecoveryAbort(request);
  Future<Response> handleSequencerUpdateRecoveryConfig(Request request) =>
      _handleSequencerUpdateRecoveryConfig(request);
  Future<Response> handleSequencerGetCurrentRecovery(Request request) =>
      _handleSequencerGetCurrentRecovery(request);
  Future<Response> handleSequencerGetRecoveryHistory(Request request) =>
      _handleSequencerGetRecoveryHistory(request);
  Future<Response> handleSequencerUpdateCloudMotion(Request request) =>
      _handleSequencerUpdateCloudMotion(request);
  Future<Response> handleSequencerUpdateWeatherVerdict(Request request) =>
      _handleSequencerUpdateWeatherVerdict(request);
  Future<Response> handleSequencerGetCloudMotion(Request request) =>
      _handleSequencerGetCloudMotion(request);
  Future<Response> handleSequencerUpdateConditionsScore(Request request) =>
      _handleSequencerUpdateConditionsScore(request);
  Future<Response> handleSequencerGetAdaptiveSwap(Request request) =>
      _handleSequencerGetAdaptiveSwap(request);
  Future<Response> handleSecondaryRigStatus(Request request) =>
      _handleSecondaryRigStatus(request);
  Future<Response> handleSecondaryRigStart(Request request) =>
      _handleSecondaryRigStart(request);
  Future<Response> handleSecondaryRigStop(Request request) =>
      _handleSecondaryRigStop(request);
}

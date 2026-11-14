import '../api_route.dart';

enum SequencerApi implements ApiEndpoint {
  status(
    ApiRoute.get('/api/sequencer/status', resource: ApiResource.sequencer),
  ),
  editorSequence(
    ApiRoute.get(
      '/api/sequencer/editor-sequence',
      resource: ApiResource.sequencer,
    ),
  ),
  putEditorSequence(
    ApiRoute.put(
      '/api/sequencer/editor-sequence',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  start(
    ApiRoute.post(
      '/api/sequencer/start',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.highRisk,
      audit: 'sequence_start',
      sessionOwner: true,
    ),
  ),
  stop(
    ApiRoute.post(
      '/api/sequencer/stop',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.highRisk,
      audit: 'sequence_stop',
      sessionOwner: true,
    ),
  ),
  getScheduledStart(
    ApiRoute.get('/api/night/scheduled-start', resource: ApiResource.system),
  ),
  armScheduledStart(
    ApiRoute.post(
      '/api/night/scheduled-start',
      resource: ApiResource.system,
      sessionOwner: true,
    ),
  ),
  cancelScheduledStart(
    ApiRoute.post(
      '/api/night/scheduled-start/cancel',
      resource: ApiResource.system,
      sessionOwner: true,
    ),
  ),
  pause(
    ApiRoute.post(
      '/api/sequencer/pause',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  resume(
    ApiRoute.post(
      '/api/sequencer/resume',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.highRisk,
      audit: 'sequence_resume',
      sessionOwner: true,
    ),
  ),
  skip(
    ApiRoute.post(
      '/api/sequencer/skip',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  skipToNode(
    ApiRoute.post(
      '/api/sequencer/skip-to-node',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  pluginNodeFinished(
    ApiRoute.post(
      '/api/sequencer/plugin-node-finished',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  reset(
    ApiRoute.post(
      '/api/sequencer/reset',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  load(
    ApiRoute.post(
      '/api/sequencer/load',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  loadAndStart(
    ApiRoute.post(
      '/api/sequencer/load-and-start',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  setSimulationMode(
    ApiRoute.post(
      '/api/sequencer/simulation',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  setDevices(
    ApiRoute.post(
      '/api/sequencer/devices',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  setSavePath(
    ApiRoute.post(
      '/api/sequencer/save-path',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  setActiveSequenceRunId(
    ApiRoute.post(
      '/api/sequencer/active-sequence-run-id',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  updatePendingIntegrationCarryOver(
    ApiRoute.post(
      '/api/sequencer/update-pending-integration-carry-over',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  updateSkyBrightness(
    ApiRoute.post(
      '/api/sequencer/update-sky-brightness',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  setCheckpointDir(
    ApiRoute.post(
      '/api/sequencer/checkpoint/dir',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  hasCheckpoint(
    ApiRoute.get(
      '/api/sequencer/checkpoint/has',
      resource: ApiResource.sequencer,
    ),
  ),
  getCheckpointInfo(
    ApiRoute.get(
      '/api/sequencer/checkpoint/info',
      resource: ApiResource.sequencer,
    ),
  ),
  resumeFromCheckpoint(
    ApiRoute.post(
      '/api/sequencer/checkpoint/resume',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  discardCheckpoint(
    ApiRoute.post(
      '/api/sequencer/checkpoint/discard',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  saveCheckpoint(
    ApiRoute.post(
      '/api/sequencer/checkpoint/save',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  performMeridianFlip(
    ApiRoute.post(
      '/api/sequencer/meridian-flip',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  requestMeridianFlip(
    ApiRoute.post(
      '/api/sequencer/request-meridian-flip',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.highRisk,
      audit: 'sequence_request_meridian_flip',
      sessionOwner: true,
    ),
  ),
  recoveryTryNow(
    ApiRoute.post(
      '/api/sequencer/recovery/try-now',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  recoveryAbort(
    ApiRoute.post(
      '/api/sequencer/recovery/abort',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  getCurrentRecovery(
    ApiRoute.get(
      '/api/sequencer/recovery/current',
      resource: ApiResource.sequencer,
    ),
  ),
  getRecoveryHistory(
    ApiRoute.get(
      '/api/sequencer/recovery/history',
      resource: ApiResource.sequencer,
    ),
  ),
  updateCloudMotion(
    ApiRoute.post(
      '/api/sequencer/update-cloud-motion',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  getCloudMotion(
    ApiRoute.get(
      '/api/sequencer/cloud-motion',
      resource: ApiResource.sequencer,
    ),
  ),
  updateWeatherVerdict(
    ApiRoute.post(
      '/api/sequencer/update-weather-verdict',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  weatherOperatorClear(
    ApiRoute.post(
      '/api/sequencer/weather-operator-clear',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  updateConditionsScore(
    ApiRoute.post(
      '/api/sequencer/update-conditions-score',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  getAdaptiveSwap(
    ApiRoute.get(
      '/api/sequencer/adaptive-swap',
      resource: ApiResource.sequencer,
    ),
  ),
  secondaryRigStatus(
    ApiRoute.get(
      '/api/sequencer/secondary-rig',
      resource: ApiResource.sequencer,
    ),
  ),
  secondaryRigStart(
    ApiRoute.post(
      '/api/sequencer/secondary-rig/start',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  secondaryRigStop(
    ApiRoute.post(
      '/api/sequencer/secondary-rig/stop',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  );

  const SequencerApi(this.route);

  @override
  final ApiRoute route;
}

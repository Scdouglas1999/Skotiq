import '../api_route.dart';

enum ReplayDebugApi implements ApiEndpoint {
  countDecisions(
    ApiRoute.get(
      '/api/sequencer/replay-debug/decisions/count',
      resource: ApiResource.sequencer,
    ),
  ),
  listDecisions(
    ApiRoute.get(
      '/api/sequencer/replay-debug/decisions',
      resource: ApiResource.sequencer,
    ),
  ),
  setEnabled(
    ApiRoute.post(
      '/api/sequencer/replay-debug/settings/enabled',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  setRetention(
    ApiRoute.post(
      '/api/sequencer/replay-debug/settings/retention',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  ),
  getSettings(
    ApiRoute.get(
      '/api/sequencer/replay-debug/settings',
      resource: ApiResource.sequencer,
    ),
  ),
  clear(
    ApiRoute.post(
      '/api/sequencer/replay-debug/clear',
      resource: ApiResource.sequencer,
      rate: ApiRateTier.control,
    ),
  );

  const ReplayDebugApi(this.route);

  @override
  final ApiRoute route;
}

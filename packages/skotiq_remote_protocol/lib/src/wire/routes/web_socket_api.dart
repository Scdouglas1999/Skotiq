import '../api_route.dart';

enum WebSocketApi implements ApiEndpoint {
  events(ApiRoute.ws('/api/ws', resource: ApiResource.system)),
  eventsLegacyPath(ApiRoute.ws('/events', resource: ApiResource.system)),
  liveView(ApiRoute.ws('/ws/live-view', resource: ApiResource.system));

  const WebSocketApi(this.route);

  @override
  final ApiRoute route;
}

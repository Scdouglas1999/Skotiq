import '../api_route.dart';

enum NarratorApi implements ApiEndpoint {
  feed(ApiRoute.get('/api/narrator/feed', resource: ApiResource.system)),
  recent(ApiRoute.get('/api/narrator/recent', resource: ApiResource.system));

  const NarratorApi(this.route);

  @override
  final ApiRoute route;
}

import '../api_route.dart';

enum PairingApi implements ApiEndpoint {
  start(
    ApiRoute.post(
      '/api/pairing/start',
      resource: ApiResource.system,
      scope: ApiScope.public,
      rate: ApiRateTier.control,
    ),
  ),
  verify(
    ApiRoute.post(
      '/api/pairing/verify',
      resource: ApiResource.system,
      scope: ApiScope.public,
      rate: ApiRateTier.control,
    ),
  ),
  lanClaim(
    ApiRoute.post(
      '/api/pairing/lan-claim',
      resource: ApiResource.system,
      scope: ApiScope.public,
      rate: ApiRateTier.control,
    ),
  ),
  activeList(
    ApiRoute.get(
      '/api/pairing/active',
      resource: ApiResource.system,
      scope: ApiScope.admin,
    ),
  );

  const PairingApi(this.route);

  @override
  final ApiRoute route;
}

import '../api_route.dart';

enum FileSystemApi implements ApiEndpoint {
  browseDirectories(
    ApiRoute.get(
      '/api/files/browse',
      resource: ApiResource.filesystem,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
      audit: 'file_browse',
    ),
  ),
  validateDirectory(
    ApiRoute.post(
      '/api/files/validate',
      resource: ApiResource.filesystem,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
    ),
  );

  const FileSystemApi(this.route);

  @override
  final ApiRoute route;
}

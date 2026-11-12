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

  /// Whether one folder exists and can be written, for the capture, flat
  /// and setup checks a linked client makes; it lists and reads nothing.
  validateDirectory(
    ApiRoute.post(
      '/api/files/validate',
      resource: ApiResource.filesystem,
      scope: ApiScope.control,
      rate: ApiRateTier.control,
    ),
  );

  const FileSystemApi(this.route);

  @override
  final ApiRoute route;
}

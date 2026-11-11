import '../api_route.dart';

enum PluginApi implements ApiEndpoint {
  listPlugins(
    ApiRoute.get(
      '/api/plugins',
      resource: ApiResource.system,
      scope: ApiScope.admin,
    ),
  ),
  uploadPlugin(
    ApiRoute.post(
      '/api/plugins/upload',
      resource: ApiResource.plugins,
      scope: ApiScope.admin,
      maxBodyBytes: ApiBodyLimit.archive,
    ),
  ),
  enablePlugin(
    ApiRoute.post(
      '/api/plugins/<pluginId>/enable',
      resource: ApiResource.plugins,
      scope: ApiScope.admin,
    ),
  ),
  disablePlugin(
    ApiRoute.post(
      '/api/plugins/<pluginId>/disable',
      resource: ApiResource.plugins,
      scope: ApiScope.admin,
    ),
  ),
  uninstallPlugin(
    ApiRoute.delete(
      '/api/plugins/<pluginId>',
      resource: ApiResource.plugins,
      scope: ApiScope.admin,
    ),
  );

  const PluginApi(this.route);

  @override
  final ApiRoute route;
}

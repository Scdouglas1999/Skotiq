import '../api_route.dart';

enum LogApi implements ApiEndpoint {
  listFiles(ApiRoute.get('/api/logs', resource: ApiResource.system)),
  recent(ApiRoute.get('/api/logs/recent', resource: ApiResource.system)),
  downloadFile(
    ApiRoute.get(
      '/api/logs/files/<filename>/download',
      resource: ApiResource.system,
      audit: 'log_download',
      timeout: ApiTimeout.slowRead,
      bucket: ApiBucket.imageDownload,
    ),
  ),
  tail(
    ApiRoute.get(
      '/api/logs/tail',
      resource: ApiResource.system,
      timeout: ApiTimeout.openEnded,
      queryToken: true,
    ),
  ),
  clear(
    ApiRoute.post(
      '/api/logs/clear',
      resource: ApiResource.system,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'log_clear',
    ),
  ),
  testEntry(
    ApiRoute.post(
      '/api/logs/test-entry',
      resource: ApiResource.system,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'log_test_entry',
    ),
  );

  const LogApi(this.route);

  @override
  final ApiRoute route;
}

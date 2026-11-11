import '../api_route.dart';

enum CatalogApi implements ApiEndpoint {
  status(ApiRoute.get('/api/catalog/status', resource: ApiResource.catalog)),
  available(
    ApiRoute.get('/api/catalog/available', resource: ApiResource.catalog),
  ),
  download(
    ApiRoute.post(
      '/api/catalog/download',
      resource: ApiResource.catalog,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'catalog_download',
    ),
  ),
  upload(
    ApiRoute.post(
      '/api/catalog/upload',
      resource: ApiResource.catalog,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'catalog_upload',
      maxBodyBytes: ApiBodyLimit.catalog,
    ),
  ),
  verify(
    ApiRoute.post(
      '/api/catalog/verify',
      resource: ApiResource.catalog,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'catalog_verify',
    ),
  ),
  reload(
    ApiRoute.post(
      '/api/catalog/reload',
      resource: ApiResource.catalog,
      scope: ApiScope.admin,
    ),
  ),
  delete(
    ApiRoute.delete(
      '/api/catalog/<name>',
      resource: ApiResource.catalog,
      scope: ApiScope.admin,
      audit: 'catalog_delete',
    ),
  );

  const CatalogApi(this.route);

  @override
  final ApiRoute route;
}

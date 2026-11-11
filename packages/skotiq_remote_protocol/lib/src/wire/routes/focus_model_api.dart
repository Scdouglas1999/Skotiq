import '../api_route.dart';

enum FocusModelApi implements ApiEndpoint {
  getFocusData(
    ApiRoute.get('/api/focus-model/data', resource: ApiResource.system),
  ),
  addFocusPoint(
    ApiRoute.post('/api/focus-model/add-point', resource: ApiResource.system),
  ),
  clearFocusData(
    ApiRoute.delete('/api/focus-model/clear', resource: ApiResource.system),
  ),
  getFocusModel(
    ApiRoute.get('/api/focus-model/model', resource: ApiResource.system),
  ),
  predictFocus(
    ApiRoute.get('/api/focus-model/predict', resource: ApiResource.system),
  ),
  getFilterOffsets(
    ApiRoute.get(
      '/api/focus-model/filter-offsets',
      resource: ApiResource.system,
    ),
  ),
  setFilterOffsets(
    ApiRoute.post(
      '/api/focus-model/filter-offsets',
      resource: ApiResource.system,
    ),
  ),
  shouldRefocus(
    ApiRoute.get(
      '/api/focus-model/should-refocus',
      resource: ApiResource.system,
    ),
  ),
  exportFocusData(
    ApiRoute.get(
      '/api/focus-model/export',
      resource: ApiResource.system,
      timeout: ApiTimeout.slowRead,
    ),
  ),
  importFocusData(
    ApiRoute.post('/api/focus-model/import', resource: ApiResource.system),
  ),
  getPredictiveSettings(
    ApiRoute.get('/api/focus-model/predictive', resource: ApiResource.system),
  ),
  updatePredictiveConfig(
    ApiRoute.post(
      '/api/focus-model/predictive/config',
      resource: ApiResource.system,
    ),
  ),
  clearPredictiveSamples(
    ApiRoute.post(
      '/api/focus-model/predictive/clear-samples',
      resource: ApiResource.system,
    ),
  ),
  exportPredictiveModel(
    ApiRoute.get(
      '/api/focus-model/predictive/export',
      resource: ApiResource.system,
      timeout: ApiTimeout.slowRead,
    ),
  );

  const FocusModelApi(this.route);

  @override
  final ApiRoute route;
}

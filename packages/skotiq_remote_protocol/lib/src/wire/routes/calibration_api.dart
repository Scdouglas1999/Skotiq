import '../api_route.dart';

enum CalibrationApi implements ApiEndpoint {
  getCalibrationSettings(
    ApiRoute.get(
      '/api/calibration/settings',
      resource: ApiResource.calibration,
    ),
  ),
  updateCalibrationSettings(
    ApiRoute.post(
      '/api/calibration/settings',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  getEndOfNight(
    ApiRoute.get(
      '/api/calibration/end-of-night',
      resource: ApiResource.calibration,
    ),
  ),
  updateEndOfNightSettings(
    ApiRoute.post(
      '/api/calibration/end-of-night/settings',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  startEndOfNight(
    ApiRoute.post(
      '/api/calibration/end-of-night/start',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  endOfNightImagingEnded(
    ApiRoute.post(
      '/api/calibration/end-of-night/imaging-ended',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  confirmEndOfNightCapped(
    ApiRoute.post(
      '/api/calibration/end-of-night/confirm-capped',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  cancelEndOfNight(
    ApiRoute.post(
      '/api/calibration/end-of-night/cancel',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  matchDark(
    ApiRoute.post(
      '/api/calibration/match-dark',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  listDarks(
    ApiRoute.get('/api/calibration/darks', resource: ApiResource.calibration),
  ),
  registerDark(
    ApiRoute.post(
      '/api/calibration/darks',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  uploadDark(
    ApiRoute.post(
      '/api/calibration/darks/upload',
      resource: ApiResource.calibration,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'calibration_dark_upload',
      maxBodyBytes: ApiBodyLimit.archive,
    ),
  ),
  findMatchingDark(
    ApiRoute.post(
      '/api/calibration/darks/find-match',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  verifyDarkSizes(
    ApiRoute.post(
      '/api/calibration/darks/backfill-sizes',
      resource: ApiResource.calibration,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'calibration_backfill',
    ),
  ),
  getDarkSettings(
    ApiRoute.get(
      '/api/calibration/darks/settings',
      resource: ApiResource.calibration,
    ),
  ),
  updateDarkSettings(
    ApiRoute.post(
      '/api/calibration/darks/settings',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  createMasterDark(
    ApiRoute.post(
      '/api/calibration/darks/create-master',
      resource: ApiResource.calibration,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'calibration_dark_create_master',
    ),
  ),
  cleanDarkOrphans(
    ApiRoute.post(
      '/api/calibration/darks/clean-orphans',
      resource: ApiResource.calibration,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'calibration_dark_clean_orphans',
    ),
  ),
  clearDarkLibrary(
    ApiRoute.post(
      '/api/calibration/darks/clear',
      resource: ApiResource.calibration,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'calibration_dark_clear',
    ),
  ),
  deleteDarkGroup(
    ApiRoute.post(
      '/api/calibration/darks/delete-group',
      resource: ApiResource.calibration,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'calibration_dark_delete_group',
    ),
  ),
  getDark(
    ApiRoute.get(
      '/api/calibration/darks/<id>',
      resource: ApiResource.calibration,
    ),
  ),
  downloadDark(
    ApiRoute.get(
      '/api/calibration/darks/<id>/download',
      resource: ApiResource.calibration,
      timeout: ApiTimeout.slowRead,
      bucket: ApiBucket.imageDownload,
    ),
  ),
  deleteDark(
    ApiRoute.delete(
      '/api/calibration/darks/<id>',
      resource: ApiResource.calibration,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
      audit: 'calibration_dark_delete',
    ),
  ),
  listFlats(
    ApiRoute.get('/api/calibration/flats', resource: ApiResource.calibration),
  ),
  recordFlat(
    ApiRoute.post(
      '/api/calibration/flats',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  flatRecommendation(
    ApiRoute.get(
      '/api/calibration/flats/recommendation',
      resource: ApiResource.calibration,
    ),
  ),
  getFlat(
    ApiRoute.get(
      '/api/calibration/flats/<id>',
      resource: ApiResource.calibration,
    ),
  ),
  deleteFlat(
    ApiRoute.delete(
      '/api/calibration/flats/<id>',
      resource: ApiResource.calibration,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
      audit: 'calibration_flat_delete',
    ),
  ),
  listDefectMaps(
    ApiRoute.get(
      '/api/calibration/defect-maps',
      resource: ApiResource.calibration,
    ),
  ),
  registerDefectMap(
    ApiRoute.post(
      '/api/calibration/defect-maps',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  buildDefectMap(
    ApiRoute.post(
      '/api/calibration/defect-maps/build',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  getDefectMapStatus(
    ApiRoute.get(
      '/api/calibration/defect-maps/status',
      resource: ApiResource.calibration,
    ),
  ),
  getDefectMapSettings(
    ApiRoute.get(
      '/api/calibration/defect-maps/settings',
      resource: ApiResource.calibration,
    ),
  ),
  updateDefectMapSettings(
    ApiRoute.post(
      '/api/calibration/defect-maps/settings',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  clearDefectMap(
    ApiRoute.post(
      '/api/calibration/defect-maps/clear',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  applyDefectMapToSequencer(
    ApiRoute.post(
      '/api/calibration/defect-maps/sequencer-apply',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  getDefectMap(
    ApiRoute.get(
      '/api/calibration/defect-maps/<id>',
      resource: ApiResource.calibration,
    ),
  ),
  deleteDefectMap(
    ApiRoute.delete(
      '/api/calibration/defect-maps/<id>',
      resource: ApiResource.calibration,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
      audit: 'calibration_defect_map_delete',
    ),
  ),
  regenerateDefectMap(
    ApiRoute.post(
      '/api/calibration/defect-maps/<id>/regenerate',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  );

  const CalibrationApi(this.route);

  @override
  final ApiRoute route;
}

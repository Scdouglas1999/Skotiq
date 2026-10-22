/// Declarative route table for the calibration-library surface
/// (darks, flats, defect maps).
///
/// Counterpart to `handlers/calibration_handlers.dart`. Order constraint
/// inside each sub-prefix: the literal sub-paths (`upload`, `find-match`,
/// `backfill-sizes`, `recommendation`) MUST register before the
/// `<id>`-parameterised route on the same prefix.
library;

import '../handlers/calibration_handlers.dart';
import 'headless_route.dart';

/// Build the declarative route table for [CalibrationHandlers].
List<HeadlessRoute> buildCalibrationRoutes(
  CalibrationHandlers h,
) => <HeadlessRoute>[
  HeadlessRoute(
    HttpMethod.get,
    '/api/calibration/settings',
    h.handleGetCalibrationSettings,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/settings',
    h.handleUpdateCalibrationSettings,
  ),

  // End-of-night calibration: darks and bias after the night's imaging.
  HeadlessRoute(
    HttpMethod.get,
    '/api/calibration/end-of-night',
    h.handleGetEndOfNight,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/end-of-night/settings',
    h.handleUpdateEndOfNightSettings,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/end-of-night/start',
    h.handleStartEndOfNight,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/end-of-night/imaging-ended',
    h.handleEndOfNightImagingEnded,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/end-of-night/confirm-capped',
    h.handleConfirmEndOfNightCapped,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/end-of-night/cancel',
    h.handleCancelEndOfNight,
  ),

  // Remote dark-library auto-match for frame calibration. A remote client
  // can't run the matcher locally (the library lives on the host), so it
  // posts the light frame's capture params here and gets back the matched
  // dark's on-host path (or null) to feed to /api/imaging/calibrate-file.
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/match-dark',
    h.handleMatchDark,
  ),

  // Darks
  HeadlessRoute(HttpMethod.get, '/api/calibration/darks', h.handleListDarks),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/darks',
    h.handleRegisterDark,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/darks/upload',
    h.handleUploadDark,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/darks/find-match',
    h.handleFindMatchingDark,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/darks/backfill-sizes',
    h.handleVerifyDarkSizes,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/calibration/darks/settings',
    h.handleGetDarkSettings,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/darks/settings',
    h.handleUpdateDarkSettings,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/darks/create-master',
    h.handleCreateMasterDark,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/darks/clean-orphans',
    h.handleCleanDarkOrphans,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/darks/clear',
    h.handleClearDarkLibrary,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/darks/delete-group',
    h.handleDeleteDarkGroup,
  ),
  HeadlessRoute(HttpMethod.get, '/api/calibration/darks/<id>', h.handleGetDark),
  HeadlessRoute(
    HttpMethod.get,
    '/api/calibration/darks/<id>/download',
    h.handleDownloadDark,
  ),
  HeadlessRoute(
    HttpMethod.delete,
    '/api/calibration/darks/<id>',
    h.handleDeleteDark,
  ),

  // Flats
  HeadlessRoute(HttpMethod.get, '/api/calibration/flats', h.handleListFlats),
  HeadlessRoute(HttpMethod.post, '/api/calibration/flats', h.handleRecordFlat),
  HeadlessRoute(
    HttpMethod.get,
    '/api/calibration/flats/recommendation',
    h.handleFlatRecommendation,
  ),
  HeadlessRoute(HttpMethod.get, '/api/calibration/flats/<id>', h.handleGetFlat),
  HeadlessRoute(
    HttpMethod.delete,
    '/api/calibration/flats/<id>',
    h.handleDeleteFlat,
  ),

  // Defect maps
  HeadlessRoute(
    HttpMethod.get,
    '/api/calibration/defect-maps',
    h.handleListDefectMaps,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/defect-maps',
    h.handleRegisterDefectMap,
  ),
  // Literal sub-paths MUST register before the `<id>` route below.
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/defect-maps/build',
    h.handleBuildDefectMap,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/defect-maps/apply',
    h.handleApplyDefectMap,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/calibration/defect-maps/status',
    h.handleGetDefectMapStatus,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/calibration/defect-maps/settings',
    h.handleGetDefectMapSettings,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/defect-maps/settings',
    h.handleUpdateDefectMapSettings,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/defect-maps/clear',
    h.handleClearDefectMap,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/defect-maps/sequencer-apply',
    h.handleApplyDefectMapToSequencer,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/calibration/defect-maps/<id>',
    h.handleGetDefectMap,
  ),
  HeadlessRoute(
    HttpMethod.delete,
    '/api/calibration/defect-maps/<id>',
    h.handleDeleteDefectMap,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/calibration/defect-maps/<id>/regenerate',
    h.handleRegenerateDefectMap,
  ),
];

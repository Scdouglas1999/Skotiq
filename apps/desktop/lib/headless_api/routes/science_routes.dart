/// Declarative route table for the science / photometry surface.
///
/// Counterpart to `handlers/science_handlers.dart`. Covers session
/// bundles, reprocessing a recorded session, photometric calibration, line-ratio products, AAVSO export,
/// and the PDF observation report. The sessionless-recent endpoint
/// surfaces measurements that landed before a session was open (rare
/// but real).
library;

import '../handlers/science_handlers.dart';
import 'headless_route.dart';

/// Build the declarative route table for [ScienceHandlers].
List<HeadlessRoute> buildScienceRoutes(ScienceHandlers h) => <HeadlessRoute>[
  HeadlessRoute(
    HttpMethod.get,
    '/api/science/session/<sessionId>/bundle',
    h.handleGetSessionBundle,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/science/session/<sessionId>/reprocess',
    h.handleStartSessionReprocess,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/science/session/<sessionId>/reprocess',
    h.handleGetSessionReprocess,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/science/sessionless/recent',
    h.handleGetSessionlessBundle,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/science/settings',
    h.handleGetScienceSettings,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/science/settings',
    h.handleUpdateScienceSettings,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/smart-night/settings',
    h.handleGetSmartNightSettings,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/smart-night/settings',
    h.handleUpdateSmartNightSettings,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/science/session/<sessionId>/config',
    h.handleGetSessionConfig,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/science/session/<sessionId>/config',
    h.handleUpdateSessionConfig,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/science/transforms',
    h.handleGetPhotometricTransforms,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/science/calibration/image/<imageId>/match-stars',
    h.handleMatchPhotometricCalibrationStars,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/science/calibration/compute-transform',
    h.handleComputePhotometricTransform,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/science/calibration/save-transform',
    h.handleSavePhotometricTransform,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/science/session/<sessionId>/generate-line-ratios',
    h.handleGenerateLineRatios,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/science/session/<sessionId>/export/aavso',
    h.handleExportAavso,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/science/session/<sessionId>/report/pdf',
    h.handleGenerateObservationReport,
  ),
];

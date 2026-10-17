/// Barrel file for backend model types.
///
/// Import this file to get all backend-related types:
/// ```dart
/// import 'package:skotiq_core/src/models/backend/backend_types.dart';
/// ```
library;

export 'autofocus_result.dart';
export 'builtin_guider_config.dart';
export 'device_capabilities.dart';
export 'device_info.dart';
export 'device_status.dart';
export 'device_types.dart';
export 'event_types.dart';
export 'fits_header.dart';
export 'image_result.dart';
export 'platform_capabilities.dart';
export 'phd2_status.dart';
// PlateSolveResult comes from the FRB-canonical type
// (`package:skotiq_bridge/src/api/plate_solve.dart`); re-exported through
// `skotiq_core.dart`'s `skotiq_bridge` re-export.
export 'remote_api_compatibility.dart';
export 'sequencer_status.dart';
export '../errors/skotiq_error.dart';
// Error parsing: surface the headless-envelope ServerError so
// mobile (and any other client) can pattern-match on `code` + `message`
// instead of stringifying opaque exceptions.
export '../errors/server_error.dart';

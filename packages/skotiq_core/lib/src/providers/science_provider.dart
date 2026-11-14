import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart'
    show
        PhotometryMeasurementRow,
        FramePhotometricCalibrationRow,
        TransparencySampleRow,
        PsfFieldTileRow,
        ScienceFrameQualityMetricsRow,
        ScienceTileMetricRow,
        AstrometryResidualVectorRow,
        MovingObjectCandidateRow,
        LineRatioProductRow;
import '../models/science/science_models.dart';
import '../services/science/frame_grade_rules.dart';
import '../services/science/photometric_catalog_service.dart';
import '../services/science/science_camera_auto_config.dart';
import '../services/sky_atlas/sky_atlas_service.dart' show parseSkyAtlasLimitGb;
import 'async_scope.dart';
import 'backend_provider.dart';
import 'host_role.dart';
import 'database_provider.dart';
import '../backend/roles/host_data/science_products.dart';
import 'session_provider.dart';
import 'settings_provider.dart';
import '../settings/app_settings_state.g.dart';
import '../settings/setting.dart';
import '../settings/store_settings.dart';
import 'science/science_camera_auto_config_provider.dart';
import '../services/logging_service.dart';

part 'science_provider/settings.dart';
part 'science_provider/photometry_selection.dart';
part 'science_provider/visualization_prefs.dart';
part 'science_provider/session_products.dart';

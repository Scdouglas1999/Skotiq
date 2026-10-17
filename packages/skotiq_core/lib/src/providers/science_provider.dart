import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show listEquals, mapEquals;
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
import '../database/daos/settings_dao.dart';
import '../models/science/science_models.dart';
import '../services/science/frame_grade_rules.dart';
import '../services/science/photometric_catalog_service.dart';
import '../services/science/science_camera_auto_config.dart';
import '../utils/resilient_poll_stream.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import '../backend/network_backend.dart';
import 'session_provider.dart';
import 'settings_provider.dart';

part 'science_provider/settings.dart';
part 'science_provider/photometry_selection.dart';
part 'science_provider/visualization_prefs.dart';
part 'science_provider/session_products.dart';

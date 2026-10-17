import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    hide
        BuiltinGuiderConfig,
        EventCategory,
        Phd2StarImage,
        Phd2CalibrationData,
        SkotiqEvent;
import '../backend/ffi_backend.dart';
import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../models/equipment/equipment_models.dart';
import '../models/phd2_models.dart';
import '../services/device_exceptions.dart';
import '../services/device_service.dart';
import '../services/logging_service.dart';
import '../services/phd2_status_poll.dart';
import '../utils/device_id.dart';
import 'backend_provider.dart';
import 'equipment_provider.dart';
import 'ui_notification_provider.dart';

part 'guiding_provider/stats_and_graph.dart';
part 'guiding_provider/controller.dart';
part 'guiding_provider/star_image_and_history.dart';
part 'guiding_provider/brain_and_calibration.dart';
part 'guiding_provider/lock_and_builtin.dart';

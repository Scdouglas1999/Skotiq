import 'package:drift/drift.dart';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import '../backend/network_backend.dart';
import '../database/database.dart';
import '../models/backend/device_capabilities.dart';
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/equipment_profile.dart' as remote_profile;
import '../models/optical_config.dart';
import '../utils/json_validation.dart';
import 'backend_provider.dart';
import 'capability_provider.dart';
import 'database_provider.dart';
import 'equipment_provider.dart';
import 'profile_activation_writethrough.dart';
import '../services/logging_service.dart';
import '../services/profile_service.dart';
import '../services/optical_train_limits.dart';

part 'profiles/equipment_profile_model.dart';
part 'profiles/equipment_profiles_notifier.dart';
part 'profiles/profile_derived_providers.dart';

final _log = Logger('ProfilesProvider');

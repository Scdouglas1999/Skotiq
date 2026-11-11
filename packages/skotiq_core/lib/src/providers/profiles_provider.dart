import 'package:drift/drift.dart';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import '../backend/remote_host.dart';
import '../backend/skotiq_backend.dart' show SkotiqBackend;
import '../database/database.dart';
import '../models/backend/device_capabilities.dart';
import '../models/backend/device_types.dart' show DeviceType;
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/equipment_profile.dart' as remote_profile;
import '../models/backend/host_mutation_event.dart';
import '../models/optical_config.dart';
import '../utils/device_id.dart' show isPhd2DeviceId;
import '../utils/json_validation.dart';
import 'backend_provider.dart';
import 'capability_provider.dart';
import 'database_provider.dart';
import 'equipment_provider.dart';
import 'host_mutation_event_provider.dart';
import '../services/host_mutation_event_hub.dart' show HostMutationEventHub;
import 'profile_activation_writethrough.dart';
import '../services/logging_service.dart';
import '../services/profile_service.dart';
import '../services/optical_train_limits.dart';

part 'profiles/equipment_profile_model.dart';
part 'profiles/equipment_profiles_notifier.dart';
part 'profiles/profile_derived_providers.dart';

final _log = Logger('ProfilesProvider');

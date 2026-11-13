import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../database/daos/settings_dao.dart';
import '../models/alerts/transient_alert.dart';
import '../models/target/target_models.dart';
import '../services/logging_service.dart';
import '../services/notification/secrets_store.dart';
import '../services/transients/transient_alert_mapper.dart';
import '../settings/setting.dart';
import '../settings/store_settings.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'notification_router_provider.dart';
import 'science_provider.dart';
import 'transient_detections_provider.dart';
import 'ui_notification_provider.dart';
import 'logging_service_provider.dart';
import 'target_library_service_provider.dart';
import 'transient_alert_service_provider.dart';

part 'transient_alerts/transient_alert_settings.dart';
part 'transient_alerts/transient_alert_feed.dart';
part 'transient_alerts/transient_alert_parsing.dart';
part 'transient_alerts/transient_alert_states.dart';
part 'transient_alerts/transient_queue_flights.dart';

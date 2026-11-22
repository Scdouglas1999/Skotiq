import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/predictive_af_service.dart';
import 'database_provider.dart';
import 'host_role.dart';

final predictiveAfServiceProvider = Provider<PredictiveAfService>((ref) {
  final database = ref.watch(databaseProvider);
  final settingsDao = ref.watch(settingsDaoProvider);
  final service = PredictiveAfService(database, settingsDao: settingsDao);
  unawaited(service.hydrateFromSettings());
  ref.onDispose(() async {
    await service.dispose();
  });
  return service;
});

final predictiveAfSettingsControllerProvider =
    hostRoleProvider<PredictiveAfSettingsController>(
      here: (ref) =>
          LocalPredictiveAfSettings(ref.watch(predictiveAfServiceProvider)),
      linked: (ref, host) => HostPredictiveAfSettings(host.focusModels),
    );

/// See [PredictiveAfStatus].
final lastPredictiveAfStatusProvider = StateProvider<PredictiveAfStatus?>(
  (ref) => null,
);

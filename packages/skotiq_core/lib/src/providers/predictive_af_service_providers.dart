import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/predictive_af_service.dart';
import 'host_role.dart';

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

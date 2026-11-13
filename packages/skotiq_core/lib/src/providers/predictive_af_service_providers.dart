import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import '../services/predictive_af_service.dart';

final predictiveAfSettingsControllerProvider =
    Provider<PredictiveAfSettingsController>((ref) {
      final backend = ref.watch(backendProvider);
      return PredictiveAfSettingsController(ref, backend);
    });

/// See [PredictiveAfStatus].
final lastPredictiveAfStatusProvider = StateProvider<PredictiveAfStatus?>(
  (ref) => null,
);

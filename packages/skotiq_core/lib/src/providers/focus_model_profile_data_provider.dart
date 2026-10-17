import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../services/focus_model_service.dart';
import 'backend_provider.dart';

/// Persisted focus history for [profileId] from whichever process currently
/// owns the imaging rig. Unlike reading [FocusModelService.getProfileData]
/// directly, the local branch waits for its disk hydrate to finish, so the
/// first card build cannot permanently mistake "still loading" for no data.
final focusProfileDataProvider = FutureProvider.autoDispose
    .family<ProfileFocusData?, String>((ref, profileId) async {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        final responses = await Future.wait<Map<String, dynamic>>([
          backend.getFocusModelData(),
          backend.getFocusModel(),
        ]);
        if (!identical(ref.read(backendProvider), backend)) return null;
        return parseRemoteFocusProfileData(responses[0], responses[1]);
      }

      final service = ref.watch(focusModelServiceProvider);
      await service.initialize();
      if (!identical(ref.read(backendProvider), backend) ||
          !identical(ref.read(focusModelServiceProvider), service)) {
        return null;
      }
      return service.getProfileData(profileId);
    });

/// Combines the host's split focus-history and fitted-model response shapes
/// into the same value object local UI already consumes.
ProfileFocusData parseRemoteFocusProfileData(
  Map<String, dynamic> dataResponse,
  Map<String, dynamic> modelResponse,
) {
  final profileId =
      dataResponse['profileId'] ?? modelResponse['profileId'] ?? '';
  final rawPoints = dataResponse['dataPoints'];
  final points = rawPoints is List
      ? rawPoints
            .whereType<Map>()
            .map((point) => Map<String, dynamic>.from(point))
            .toList(growable: false)
      : const <Map<String, dynamic>>[];
  final rawModel = modelResponse['hasModel'] == true
      ? modelResponse['model']
      : null;

  return ProfileFocusData.fromJson({
    'profileId': profileId.toString(),
    'dataPoints': points,
    'temperatureModel': rawModel is Map
        ? Map<String, dynamic>.from(rawModel)
        : null,
    'referenceFilter': dataResponse['referenceFilter'] as String?,
  });
}

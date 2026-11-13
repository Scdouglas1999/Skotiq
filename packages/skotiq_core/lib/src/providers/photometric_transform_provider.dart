import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart' show PhotometricTransformRow;
import 'database_provider.dart';
import 'science_provider.dart' show scienceProductsProvider;

/// Watches transforms relevant to the current equipment profile.
final activeProfileTransformsProvider =
    StreamProvider<List<PhotometricTransformRow>>(
      (ref) => ref
          .watch(scienceProductsProvider)
          .watchTransformsForProfile(
            ref.watch(activeEquipmentProfileIdProvider),
          ),
    );

final activeEquipmentProfileIdProvider = Provider<int?>((ref) {
  final profile = ref.watch(activeProfileProvider).valueOrNull;
  return profile?.id;
});

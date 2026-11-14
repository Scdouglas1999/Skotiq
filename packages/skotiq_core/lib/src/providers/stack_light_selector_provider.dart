import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import '../services/stack_light_selector.dart';

/// Provider for the [StackLightSelector]. Reads the image / session / target
/// DAOs from the shared database providers so it transparently follows the same
/// Drift instance the rest of the app uses.
final stackLightSelectorProvider = Provider<StackLightSelector>((ref) {
  return StackLightSelector(
    imagesDao: ref.watch(imagesDaoProvider),
    sessionsDao: ref.watch(sessionsDaoProvider),
    targetsDao: ref.watch(targetsDaoProvider),
  );
});

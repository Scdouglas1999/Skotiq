import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../catalogs/variable_star_catalog.dart';

// Variable star toggle provider

/// Whether variable star overlay is enabled
final showVariableStarsProvider = StateProvider<bool>((ref) => false);

// Variable star data provider

/// Provides the full list of variable stars from the embedded catalog.
/// Only returns data when the toggle is enabled.
final variableStarDataProvider = Provider<List<VariableStarData>>((ref) {
  final show = ref.watch(showVariableStarsProvider);
  if (!show) return [];
  return VariableStarCatalog.stars;
});

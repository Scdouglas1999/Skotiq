import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show TargetVisibilityInfo;

import '../models/planning/target_suggestion.dart';
import '../services/smart_night_models.dart';
import 'database_provider.dart';
import 'equipment/filter_wheel_state_provider.dart';
import 'profiles_provider.dart';
import 'session_optimizer_provider.dart';
import 'target_suggestion_provider.dart';

/// Skotiq's filter choice for [target] on this rig
/// ([SmartNightService.chooseFilters]): from its catalog type, the filters
/// on the wheel, the camera's color and the emission catalogued inside it.
final targetFilterChoiceProvider = FutureProvider.autoDispose
    .family<SmartNightFilterChoice, TargetSuggestion>((ref, target) async {
      final exposureContext = await ref.watch(
        smartNightExposureContextProvider.future,
      );
      return ref
          .watch(smartNightServiceProvider)
          .chooseFilters(
            suggestion: target,
            availableFilters: smartNightPlanningFilters(
              ref.watch(effectiveFiltersProvider),
            ),
            exposureContext: exposureContext,
          );
    });

/// The filter set [target]'s plans image through: the set the user picked
/// for it ([filterSetPreferencesProvider]), else Skotiq's choice.
final targetFilterSetProvider = FutureProvider.autoDispose
    .family<FilterSet, TargetSuggestion>((ref, target) async {
      final choice = await ref.watch(targetFilterChoiceProvider(target).future);
      final prefs = await ref.watch(filterSetPreferencesProvider.future);
      return prefs.setFor(
        target,
        sets: choice.sets(saved: prefs.custom),
        recommended: choice.recommended,
      );
    });

/// The active equipment profile's Filters picker state: the filter sets the
/// user saved and the set picked for each target ([FilterSetPreferences]).
/// Every screen that lets the user change a plan's filters reads and writes
/// it here. Kept in settings under `filter_sets.<profile id>`, so a linked
/// client works on the host's.
final filterSetPreferencesProvider =
    AsyncNotifierProvider<FilterSetPreferencesNotifier, FilterSetPreferences>(
      FilterSetPreferencesNotifier.new,
    );

class FilterSetPreferencesNotifier extends AsyncNotifier<FilterSetPreferences> {
  int? _profileId;

  @override
  Future<FilterSetPreferences> build() async {
    _profileId = ref.watch(
      activeEquipmentProfileProvider.select((profile) => profile?.id),
    );
    final dao = ref.watch(settingsDaoProvider);
    final id = _profileId;
    if (id == null) return const FilterSetPreferences();
    final raw = await dao.getSetting(_settingKey(id));
    if (raw == null || raw.isEmpty) return const FilterSetPreferences();
    return FilterSetPreferences.fromJson(
      (jsonDecode(raw) as Map).cast<String, dynamic>(),
    );
  }

  /// Remembers [set] for [target]; [recommended] (Skotiq's choice) forgets
  /// the target's choice instead.
  Future<void> choose(
    TargetSuggestion target,
    FilterSet set, {
    required FilterSet recommended,
  }) => _update((prefs) => prefs.choose(target, set, recommended: recommended));

  /// Saves [set], replacing a saved set of the same name.
  Future<void> save(CustomFilterSet set) => _update((prefs) => prefs.save(set));

  /// Deletes the saved set [name].
  Future<void> delete(String name) => _update((prefs) => prefs.delete(name));

  Future<void> _update(
    FilterSetPreferences Function(FilterSetPreferences) change,
  ) async {
    final id = _profileId;
    if (id == null) {
      throw StateError('Select an equipment profile first.');
    }
    final next = change(await future);
    await ref
        .read(settingsDaoProvider)
        .setSetting(_settingKey(id), jsonEncode(next.toJson()));
    state = AsyncData(next);
  }

  static String _settingKey(int profileId) => 'filter_sets.$profileId';
}

/// A sequence's target step, as [sequenceTargetSuggestionProvider] keys it.
typedef SequenceTargetKey = ({
  String name,
  double raHours,
  double decDegrees,
  int? libraryId,
});

/// The target of a sequence's target step as the filter choice reads it.
/// Its target-library row (by id, else by name, as a run binds the step)
/// gives the object type and size; without a row the type is unknown.
final sequenceTargetSuggestionProvider = FutureProvider.autoDispose
    .family<TargetSuggestion, SequenceTargetKey>((ref, key) async {
      final dao = ref.watch(targetsDaoProvider);
      final libraryId = key.libraryId;
      final row = libraryId != null
          ? await dao.getTargetById(libraryId)
          : await dao.getTargetByName(key.name);
      return TargetSuggestion(
        targetId: row?.id ?? key.name.hashCode,
        targetName: key.name,
        catalogId: row?.catalogId,
        raHours: key.raHours,
        decDegrees: key.decDegrees,
        totalScore: 0,
        objectType: row?.objectType,
        sizeArcmin: row?.sizeArcmin,
        visibility: const TargetVisibilityInfo(
          currentAltitude: 0,
          currentAzimuth: 0,
          airmass: 0,
          moonDistance: 0,
        ),
      );
    });

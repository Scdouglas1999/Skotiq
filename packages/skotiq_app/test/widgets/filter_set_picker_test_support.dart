import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

/// [filterSetPreferencesProvider] kept in memory, starting from [initial].
class MemoryFilterSetPreferences extends FilterSetPreferencesNotifier {
  MemoryFilterSetPreferences([this.initial = const FilterSetPreferences()]);

  final FilterSetPreferences initial;

  @override
  Future<FilterSetPreferences> build() async => initial;

  @override
  Future<void> pick(
    TargetSuggestion target,
    FilterSet set,
    SmartNightFilterChoice choice,
  ) async =>
      state = AsyncData(
          (await future).choose(target, set, recommended: choice.recommended));

  @override
  Future<void> save(CustomFilterSet set) async =>
      state = AsyncData((await future).save(set));

  @override
  Future<void> delete(String name) async =>
      state = AsyncData((await future).delete(name));
}

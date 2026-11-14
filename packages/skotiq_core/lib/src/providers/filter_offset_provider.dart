import 'focus_model_profile_data_provider.dart';
import '../errors/error_text.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'profiles_provider.dart';

/// Filter offset state for the current profile
class FilterOffsetState {
  final Map<String, int> offsets; // filterName -> offset in steps
  final String? referenceFilter;
  final bool isLoading;
  final String? error;

  const FilterOffsetState({
    this.offsets = const {},
    this.referenceFilter,
    this.isLoading = false,
    this.error,
  });

  FilterOffsetState copyWith({
    Map<String, int>? offsets,
    String? referenceFilter,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return FilterOffsetState(
      offsets: offsets ?? this.offsets,
      referenceFilter: referenceFilter ?? this.referenceFilter,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class FilterOffsetNotifier extends StateNotifier<FilterOffsetState> {
  final Ref _ref;
  String? _currentProfileId;
  int _loadGeneration = 0;
  int _authorityGeneration = 0;
  int _mutationGeneration = 0;

  FilterOffsetNotifier(this._ref)
    : super(const FilterOffsetState(isLoading: true)) {
    unawaited(_init());
    _ref.listen(activeEquipmentProfileProvider, (_, __) {
      if (!mounted) return;
      _mutationGeneration++;
      unawaited(_loadOffsetsForActiveProfile());
    });
    _ref.listen(focusHistoryProvider, (previous, next) {
      if (!mounted || identical(previous, next)) return;
      _authorityGeneration++;
      _mutationGeneration++;
      unawaited(_loadOffsetsForActiveProfile());
    });
  }

  bool _isCurrentLoad(int generation) =>
      mounted && generation == _loadGeneration;

  @override
  void dispose() {
    _loadGeneration++;
    super.dispose();
  }

  Future<void> _init() async {
    await _loadOffsetsForActiveProfile();
  }

  Future<void> _loadOffsetsForActiveProfile() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final activeProfile = _ref.read(activeEquipmentProfileProvider);
      if (activeProfile == null) {
        _currentProfileId = null;
        if (_isCurrentLoad(generation)) {
          state = const FilterOffsetState();
        }
        return;
      }

      final profileId = activeProfile.id.toString();
      _currentProfileId = profileId;

      final (:offsets, :referenceFilter) = await _ref
          .read(focusHistoryProvider)
          .filterOffsets(profileId);
      if (_isCurrentLoad(generation)) {
        state = FilterOffsetState(
          offsets: offsets,
          referenceFilter: referenceFilter,
          isLoading: false,
        );
      }
    } catch (e) {
      if (_isCurrentLoad(generation)) {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load filter offsets: ${userFacingError(e)}',
        );
      }
    }
  }

  Future<void> setFilterOffset(String filterName, int offsetSteps) async {
    if (!mounted) return;
    final profileId = _currentProfileId;
    if (profileId == null) return;
    final history = _ref.read(focusHistoryProvider);
    final authority = _authorityGeneration;
    final mutation = ++_mutationGeneration;
    final previous = state;

    try {
      final newOffsets = Map<String, int>.from(state.offsets);
      newOffsets[filterName] = offsetSteps;
      final referenceFilter = state.referenceFilter ?? filterName;

      state = state.copyWith(
        offsets: newOffsets,
        referenceFilter: referenceFilter,
        clearError: true,
      );

      await history.setFilterOffset(
        profileId: profileId,
        referenceFilter: referenceFilter,
        changed: MapEntry(filterName, offsetSteps),
        all: newOffsets,
      );
    } catch (e) {
      if (_isCurrentMutation(mutation, authority, history, profileId)) {
        state = previous.copyWith(
          error: 'Failed to save filter offset: ${userFacingError(e)}',
        );
      }
    }
  }

  Future<void> adjustFilterOffset(String filterName, int delta) async {
    if (!mounted) return;
    final currentOffset = state.offsets[filterName] ?? 0;
    await setFilterOffset(filterName, currentOffset + delta);
  }

  /// Set the reference filter (all offsets are relative to this)
  Future<void> setReferenceFilter(String filterName) async {
    if (!mounted) return;
    final profileId = _currentProfileId;
    if (profileId == null) return;
    final history = _ref.read(focusHistoryProvider);
    final authority = _authorityGeneration;
    final mutation = ++_mutationGeneration;

    try {
      await history.setReferenceFilter(profileId, filterName);

      if (!_isCurrentMutation(mutation, authority, history, profileId)) return;
      state = state.copyWith(referenceFilter: filterName);

      await _loadOffsetsForActiveProfile();
    } catch (e) {
      if (_isCurrentMutation(mutation, authority, history, profileId)) {
        state = state.copyWith(
          error: 'Failed to set reference filter: ${userFacingError(e)}',
        );
      }
    }
  }

  Future<void> clearAllOffsets() async {
    if (!mounted) return;
    final profileId = _currentProfileId;
    if (profileId == null) return;
    final history = _ref.read(focusHistoryProvider);
    final authority = _authorityGeneration;
    final mutation = ++_mutationGeneration;
    final previous = state;

    try {
      await history.clear(profileId);

      if (!_isCurrentMutation(mutation, authority, history, profileId)) return;
      state = FilterOffsetState(
        offsets: {},
        referenceFilter: state.referenceFilter,
        isLoading: false,
      );
    } catch (e) {
      if (_isCurrentMutation(mutation, authority, history, profileId)) {
        state = previous.copyWith(
          error: 'Failed to clear offsets: ${userFacingError(e)}',
        );
      }
    }
  }

  bool _isCurrentMutation(
    int mutation,
    int authority,
    FocusHistory history,
    String profileId,
  ) {
    return mounted &&
        mutation == _mutationGeneration &&
        authority == _authorityGeneration &&
        identical(history, _ref.read(focusHistoryProvider)) &&
        profileId == _currentProfileId;
  }

  int getOffset(String filterName) {
    return state.offsets[filterName] ?? 0;
  }

  /// Reload offsets (call this when profile changes)
  Future<void> reload() async {
    if (!mounted) return;
    await _loadOffsetsForActiveProfile();
  }
}

final filterOffsetProvider =
    StateNotifierProvider<FilterOffsetNotifier, FilterOffsetState>((ref) {
      return FilterOffsetNotifier(ref);
    });

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/network_backend.dart';
import '../services/focus_model_service.dart';
import 'backend_provider.dart';
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

/// Notifier for managing filter offsets
class FilterOffsetNotifier extends StateNotifier<FilterOffsetState> {
  final Ref _ref;
  String? _currentProfileId;
  int _loadGeneration = 0;
  int _authorityGeneration = 0;
  int _mutationGeneration = 0;

  FilterOffsetNotifier(this._ref)
    : super(const FilterOffsetState(isLoading: true)) {
    unawaited(_init());
    // Reload offsets whenever the active equipment profile changes
    _ref.listen(activeEquipmentProfileProvider, (_, __) {
      if (!mounted) return;
      _mutationGeneration++;
      unawaited(_loadOffsetsForActiveProfile());
    });
    _ref.listen(backendProvider, (previous, next) {
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

  /// Initialize by loading offsets for active profile
  Future<void> _init() async {
    await _loadOffsetsForActiveProfile();
  }

  /// Load offsets for the currently active profile
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

      // On a slave (NetworkBackend) the autofocus-derived focus model lives in
      // local JSON files on the master's disk, never on this client. Fetch the
      // rig's per-filter offsets over REST instead of reading the empty local
      // store (which would render the "no filter offsets yet" empty-state even
      // when the master has a full model).
      final backend = _ref.read(backendProvider);
      if (backend is NetworkBackend) {
        await _loadOffsetsFromRemote(backend, generation);
        return;
      }

      // Get focus data from service
      final focusService = _ref.read(focusModelServiceProvider);
      await focusService.initialize();
      if (!_isCurrentLoad(generation)) return;

      final focusData = focusService.getProfileData(profileId);

      if (focusData == null) {
        if (_isCurrentLoad(generation)) {
          state = const FilterOffsetState(
            offsets: {},
            referenceFilter: null,
            isLoading: false,
          );
        }
        return;
      }

      final offsetMap = <String, int>{};

      for (final entry in focusData.filterOffsets.entries) {
        offsetMap[entry.key] = entry.value.offsetSteps;
      }

      if (_isCurrentLoad(generation)) {
        state = FilterOffsetState(
          offsets: offsetMap,
          referenceFilter: focusData.referenceFilter,
          isLoading: false,
        );
      }
    } catch (e) {
      if (_isCurrentLoad(generation)) {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load filter offsets: $e',
        );
      }
    }
  }

  /// Load offsets for the active profile from the connected rig over REST.
  ///
  /// Mirrors [_loadOffsetsForActiveProfile]'s offset-mode handling but sources
  /// the relative per-filter model from the host (where autofocus runs and the
  /// focus-model JSON store lives) instead of the empty local store. Absolute
  /// mode still derives from the per-filter AF configs in AppSettings.
  Future<void> _loadOffsetsFromRemote(
    NetworkBackend backend,
    int generation,
  ) async {
    final offsetMap = <String, int>{};
    final response = await backend.getFilterFocusOffsets();
    final referenceFilter = response['referenceFilter'] as String?;
    final offsets = response['offsets'];
    if (offsets is Map) {
      for (final entry in offsets.entries) {
        final value = entry.value;
        if (value is Map && value['offsetSteps'] is num) {
          offsetMap[entry.key.toString()] = (value['offsetSteps'] as num)
              .toInt();
        }
      }
    }

    if (_isCurrentLoad(generation)) {
      state = FilterOffsetState(
        offsets: offsetMap,
        referenceFilter: referenceFilter,
        isLoading: false,
      );
    }
  }

  /// Set offset for a specific filter
  Future<void> setFilterOffset(String filterName, int offsetSteps) async {
    if (!mounted) return;
    final profileId = _currentProfileId;
    if (profileId == null) return;
    final backend = _ref.read(backendProvider);
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

      if (backend is NetworkBackend) {
        await backend.setFilterFocusOffsets(
          referenceFilter: referenceFilter,
          offsets: {filterName: offsetSteps},
        );
      } else {
        await _saveOffsetsToService(
          profileId: profileId,
          offsets: newOffsets,
          referenceFilter: referenceFilter,
        );
      }
    } catch (e) {
      if (_isCurrentMutation(mutation, authority, backend, profileId)) {
        state = previous.copyWith(error: 'Failed to save filter offset: $e');
      }
    }
  }

  /// Adjust offset by a delta amount
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
    final backend = _ref.read(backendProvider);
    final authority = _authorityGeneration;
    final mutation = ++_mutationGeneration;

    try {
      if (backend is NetworkBackend) {
        await backend.setFilterFocusOffsets(
          referenceFilter: filterName,
          offsets: const {},
        );
      } else {
        final focusService = _ref.read(focusModelServiceProvider);
        await focusService.setReferenceFilter(profileId, filterName);
      }

      if (!_isCurrentMutation(mutation, authority, backend, profileId)) return;
      state = state.copyWith(referenceFilter: filterName);

      // Reload offsets after changing reference
      await _loadOffsetsForActiveProfile();
    } catch (e) {
      if (_isCurrentMutation(mutation, authority, backend, profileId)) {
        state = state.copyWith(error: 'Failed to set reference filter: $e');
      }
    }
  }

  /// Clear all offsets
  Future<void> clearAllOffsets() async {
    if (!mounted) return;
    final profileId = _currentProfileId;
    if (profileId == null) return;
    final backend = _ref.read(backendProvider);
    final authority = _authorityGeneration;
    final mutation = ++_mutationGeneration;
    final previous = state;

    try {
      if (backend is NetworkBackend) {
        await backend.clearFocusModelData();
      } else {
        final focusService = _ref.read(focusModelServiceProvider);
        await focusService.clearProfileData(profileId);
      }

      if (!_isCurrentMutation(mutation, authority, backend, profileId)) return;
      state = FilterOffsetState(
        offsets: {},
        referenceFilter: state.referenceFilter,
        isLoading: false,
      );
    } catch (e) {
      if (_isCurrentMutation(mutation, authority, backend, profileId)) {
        state = previous.copyWith(error: 'Failed to clear offsets: $e');
      }
    }
  }

  bool _isCurrentMutation(
    int mutation,
    int authority,
    Object backend,
    String profileId,
  ) {
    return mounted &&
        mutation == _mutationGeneration &&
        authority == _authorityGeneration &&
        identical(backend, _ref.read(backendProvider)) &&
        profileId == _currentProfileId;
  }

  /// Get offset for a specific filter
  int getOffset(String filterName) {
    return state.offsets[filterName] ?? 0;
  }

  /// Save current offsets to focus model service and persist to disk
  Future<void> _saveOffsetsToService({
    required String profileId,
    required Map<String, int> offsets,
    required String? referenceFilter,
  }) async {
    final focusService = _ref.read(focusModelServiceProvider);

    // Build FilterOffset map from current state
    final updatedOffsets = <String, FilterOffset>{};
    for (final entry in offsets.entries) {
      updatedOffsets[entry.key] = FilterOffset(
        filterName: entry.key,
        referenceFilter: referenceFilter ?? 'L',
        offsetSteps: entry.value,
        measurementCount: 1,
        confidence: 1.0,
      );
    }

    await focusService.updateFilterOffsets(
      profileId,
      updatedOffsets,
      referenceFilter: referenceFilter,
    );
  }

  /// Reload offsets (call this when profile changes)
  Future<void> reload() async {
    if (!mounted) return;
    await _loadOffsetsForActiveProfile();
  }
}

/// Provider for filter offsets
final filterOffsetProvider =
    StateNotifierProvider<FilterOffsetNotifier, FilterOffsetState>((ref) {
      return FilterOffsetNotifier(ref);
    });

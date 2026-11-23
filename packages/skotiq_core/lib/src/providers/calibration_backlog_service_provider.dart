import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../services/calibration/calibration_frame_groups.dart';
import 'backend_provider.dart';
import '../services/calibration_backlog_service.dart';
import 'calibration_library_service_providers.dart';
import 'calibration_master_builder_provider.dart';
import 'dark_library_provider.dart';
import 'database_provider.dart';
import 'flat_library_service_provider.dart';

final calibrationBacklogProvider =
    StateNotifierProvider<CalibrationBacklogNotifier, CalibrationBacklogState>((
      ref,
    ) {
      final remote = ref.watch(isRemoteModeProvider);
      return CalibrationBacklogNotifier(ref, remote: remote);
    });

final calibrationBacklogServiceProvider = Provider<CalibrationBacklogService>((
  ref,
) {
  return CalibrationBacklogService(
    db: ref.watch(databaseProvider),
    library: ref.watch(calibrationLibraryProvider),
    darkLibrary: ref.watch(darkLibraryServiceProvider),
    flatLibrary: ref.watch(flatLibraryServiceProvider),
    buildMaster: ref.watch(calibrationMasterBuildProvider),
    settings: ref.watch(settingsDaoProvider),
    temperatureToleranceC: () => loadedDarkTemperatureToleranceC(ref),
  );
});

/// Bumped whenever a master is added to or removed from the calibration
/// library from this app. Panels that list or match masters watch it to
/// reload.
final calibrationLibraryRevisionProvider = StateProvider<int>((ref) => 0);

/// What the Calibration tab shows about the backlog.
class CalibrationBacklogState {
  const CalibrationBacklogState({
    this.groups = const AsyncValue.loading(),
    this.builds = const {},
    this.remote = false,
    this.scheduled = const {},
  });

  final AsyncValue<List<CalibrationBacklogGroup>> groups;

  /// Build progress by [CalibrationBacklogGroup.key]. Finished builds stay
  /// here so the result reads in place after the group leaves the list.
  final Map<String, CalibrationBuildStatus> builds;

  /// This app drives a remote imaging computer, whose frames it cannot build.
  final bool remote;
  final Set<String> scheduled;

  CalibrationBacklogState copyWith({
    AsyncValue<List<CalibrationBacklogGroup>>? groups,
    Map<String, CalibrationBuildStatus>? builds,
    Set<String>? scheduled,
  }) => CalibrationBacklogState(
    groups: groups ?? this.groups,
    builds: builds ?? this.builds,
    remote: remote,
    scheduled: scheduled ?? this.scheduled,
  );
}

/// Runs backlog builds one at a time (each holds full frames in native
/// memory) and keeps their progress across tab switches.
class CalibrationBacklogNotifier
    extends StateNotifier<CalibrationBacklogState> {
  CalibrationBacklogNotifier(this._ref, {required bool remote})
    : super(CalibrationBacklogState(remote: remote)) {
    if (remote) {
      state = state.copyWith(groups: const AsyncValue.data([]));
    } else {
      refresh();
    }
  }

  final Ref _ref;
  final List<CalibrationBacklogGroup> _queue = [];
  bool _draining = false;
  final Map<String, Completer<CalibrationBuildStatus>> _completion = {};

  CalibrationBacklogService get _service =>
      _ref.read(calibrationBacklogServiceProvider);

  Future<void> refresh() async {
    if (state.remote) return;
    if (!state.groups.hasValue) {
      state = state.copyWith(groups: const AsyncValue.loading());
    }
    try {
      final groups = await _service.pending();
      final scheduled = (await _service.scheduledFlats()).keys.toSet();
      if (!mounted) return;
      state = state.copyWith(
        groups: AsyncValue.data(groups),
        scheduled: scheduled,
      );
    } catch (e, st) {
      if (!mounted) return;
      state = state.copyWith(groups: AsyncValue.error(e, st));
    }
  }

  /// Queue [group]'s build. A group already queued or building is ignored.
  void build(CalibrationBacklogGroup group) {
    final current = state.builds[group.key]?.phase;
    if (current == CalibrationBuildPhase.queued ||
        current == CalibrationBuildPhase.building) {
      return;
    }
    _completion[group.key] = Completer<CalibrationBuildStatus>();
    _queue.add(group);
    _set(group.key, const CalibrationBuildStatus(CalibrationBuildPhase.queued));
    _drain();
  }

  Future<void> scheduleFlat(CalibrationBacklogGroup group, bool on) async {
    try {
      await _service.scheduleFlat(group, on);
      await refresh();
    } catch (e) {
      _set(
        group.key,
        CalibrationBuildStatus(
          CalibrationBuildPhase.failed,
          error: 'Could not save the night-end selection: $e',
        ),
      );
    }
  }

  Future<void> unscheduleFlat(String key) async {
    try {
      await _service.unscheduleFlat(key);
      await refresh();
    } catch (e) {
      _set(
        key,
        CalibrationBuildStatus(
          CalibrationBuildPhase.failed,
          error: 'Could not remove the night-end selection: $e',
        ),
      );
    }
  }

  Future<Map<String, String>> prepareForLights(
    List<DbCapturedImage> lights,
  ) async {
    if (state.remote) {
      throw StateError('Build calibration on the imaging computer.');
    }
    final masters = <String, String>{};
    for (final group in await _service.scheduledForLights(lights)) {
      var path = await _service.scheduledMaster(group);
      if (path == null) {
        build(group);
        final result = await _completion[group.key]!.future;
        if (result.phase != CalibrationBuildPhase.built) {
          throw CalibrationBacklogException('${group.title}: ${result.error}');
        }
        path = result.build!.outputPath;
      }
      masters[flatSetupKey(
            group.filter,
            group.gain,
            group.offset,
            group.binX,
            group.binY,
          )] =
          path;
    }
    return masters;
  }

  /// Queue every buildable group, oldest first so bias lands before the
  /// flats that need it.
  void buildAll() {
    final groups = state.groups.valueOrNull ?? const [];
    final order = [...groups.where((g) => g.buildable)]
      ..sort((a, b) {
        final rank = _kindRank(a.kind).compareTo(_kindRank(b.kind));
        return rank != 0 ? rank : a.lastCapturedAt.compareTo(b.lastCapturedAt);
      });
    for (final g in order) {
      build(g);
    }
  }

  static int _kindRank(CalibrationFrameKind kind) => switch (kind) {
    CalibrationFrameKind.bias => 0,
    CalibrationFrameKind.dark => 1,
    CalibrationFrameKind.flat => 2,
  };

  Future<void> dismiss(CalibrationBacklogGroup group) async {
    await _service.dismiss(group.key);
    await refresh();
  }

  void clearResult(String key) {
    final next = {...state.builds}..remove(key);
    state = state.copyWith(builds: next);
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && mounted) {
        final group = _queue.removeAt(0);
        _set(
          group.key,
          const CalibrationBuildStatus(CalibrationBuildPhase.building),
        );
        try {
          final built = await _service.build(group);
          if (!mounted) return;
          _set(
            group.key,
            CalibrationBuildStatus(CalibrationBuildPhase.built, build: built),
          );
          _ref.read(calibrationLibraryRevisionProvider.notifier).state++;
        } catch (e) {
          if (!mounted) return;
          _set(
            group.key,
            CalibrationBuildStatus(
              CalibrationBuildPhase.failed,
              error: e is CalibrationBacklogException ? e.message : '$e',
            ),
          );
        }
        _completion.remove(group.key)?.complete(state.builds[group.key]!);
        await refresh();
      }
    } finally {
      _draining = false;
    }
  }

  void _set(String key, CalibrationBuildStatus status) {
    state = state.copyWith(builds: {...state.builds, key: status});
  }
}

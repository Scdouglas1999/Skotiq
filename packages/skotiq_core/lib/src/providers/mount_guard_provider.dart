import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/roles/mount_guard_backend.dart';
import '../models/backend/event_types.dart';
import '../models/mount_guard.dart';
import 'backend_provider.dart';
import 'critical_alert_provider.dart';
import 'settings_provider.dart';

/// The safety events the host's mount guard publishes.
const mountGuardEventTypes = {
  'MountMotionFault',
  'MountPositionUnknown',
  'MountGuardCleared',
};

/// How often the guard is read while a fault is open: the stop attempts and
/// "still moving" change between events.
const _openPoll = Duration(seconds: 3);

/// How often it is read otherwise, so a client that missed an event (it
/// linked later, or its socket dropped) still catches up.
const _quietPoll = Duration(seconds: 30);

/// Every mount with an open motion fault or an unknown position, on the host
/// and on linked clients alike.
///
/// The host's native guard is the source of truth; this reads it through the
/// backend (FFI on the host, REST on a client) on every guard event and on a
/// poll.
class MountGuardNotifier extends Notifier<List<MountGuardEntry>> {
  Timer? _timer;
  StreamSubscription<SkotiqEvent>? _events;
  bool _refreshing = false;

  @override
  List<MountGuardEntry> build() {
    final backend = ref.watch(backendProvider);
    ref.onDispose(() {
      _timer?.cancel();
      _events?.cancel();
    });
    if (backend is! MountGuardBackend) return const [];
    _events = backend.eventStream
        .where(
          (e) =>
              e.category == EventCategory.safety &&
              mountGuardEventTypes.contains(e.eventType),
        )
        .listen((_) => refresh());
    _schedule(_quietPoll);
    Future.microtask(refresh);
    return const [];
  }

  MountGuardBackend? get _guard {
    final backend = ref.read(backendProvider);
    return backend is MountGuardBackend ? backend as MountGuardBackend : null;
  }

  void _schedule(Duration every) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => refresh());
  }

  /// Read the guard now.
  Future<void> refresh() async {
    final guard = _guard;
    if (guard == null || _refreshing) return;
    _refreshing = true;
    try {
      final entries = await guard.mountGuardState();
      state = entries;
      _schedule(entries.isEmpty ? _quietPoll : _openPoll);
    } catch (_) {
      // A client between connections reads nothing; the next poll or event
      // tries again. The last state stays on screen meanwhile, because an
      // open fault must not vanish just because one read failed.
    } finally {
      _refreshing = false;
    }
  }

  Future<void> acknowledgeFault(String deviceId) async {
    await _guard?.mountGuardAcknowledgeFault(deviceId);
    await refresh();
  }

  Future<void> confirmRehomed(String deviceId) async {
    await _guard?.mountGuardConfirmRehomed(deviceId);
    await refresh();
  }

  Future<MountGuardSolveResult> solve(
    String deviceId, {
    String? cameraId,
    double exposureSecs = 5,
  }) async {
    final guard = _guard;
    if (guard == null) {
      throw StateError('This backend has no mount guard.');
    }
    return guard.mountGuardSolve(
      deviceId,
      cameraId: cameraId,
      exposureSecs: exposureSecs,
    );
  }

  Future<void> recoverySync(
    String deviceId,
    double raHours,
    double decDegrees,
  ) async {
    await _guard?.mountGuardRecoverySync(deviceId, raHours, decDegrees);
    await refresh();
  }
}

final mountGuardProvider =
    NotifierProvider<MountGuardNotifier, List<MountGuardEntry>>(
      MountGuardNotifier.new,
    );

/// The guard entry for one mount, if it has an open fault or unknown
/// position.
final mountGuardEntryProvider = Provider.family<MountGuardEntry?, String?>((
  ref,
  deviceId,
) {
  final entries = ref.watch(mountGuardProvider);
  if (deviceId == null) return entries.isEmpty ? null : entries.first;
  for (final e in entries) {
    if (e.deviceId == deviceId) return e;
  }
  return null;
});

/// Sounds the alarm the first time each fault or lost position appears, on
/// whatever screen is showing. Watched from the app shell, so it runs on the
/// host and on linked clients. The toast comes from the notification router
/// and the banner from the screens.
final mountGuardAlarmProvider = Provider<void>((ref) {
  final announced = <String>{};
  ref.listen<List<MountGuardEntry>>(mountGuardProvider, (previous, next) {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    final sound = settings?.criticalAlertSound ?? 'systemBell';
    for (final entry in next) {
      final fault = entry.fault;
      if (fault != null) {
        final key = '${entry.deviceId}/fault/${fault.detectedAt}';
        if (announced.add(key)) {
          unawaited(ref.read(criticalAlertPlayerProvider).play(sound: sound));
        }
      }
      final lost = entry.positionUnknown;
      if (lost != null) {
        final key = '${entry.deviceId}/lost/${lost.flaggedAt}';
        if (announced.add(key)) {
          unawaited(ref.read(criticalAlertPlayerProvider).play(sound: sound));
        }
      }
    }
  }, fireImmediately: true);
});

/// Pushes the operator's "solve, sync and resume on its own" choice to the
/// host's native guard. Host only: a client's settings are the host's,
/// mirrored, and the host pushes them itself.
final mountGuardSettingsSyncProvider = Provider<void>((ref) {
  if (ref.watch(isRemoteClientProvider)) return;
  final enabled = ref.watch(
    appSettingsProvider.select(
      (s) => s.valueOrNull?.mountGuardAutoSyncResume ?? false,
    ),
  );
  final backend = ref.watch(backendProvider);
  if (backend is MountGuardBackend) {
    unawaited(
      (backend as MountGuardBackend)
          .mountGuardSetAutoSyncResume(enabled)
          .catchError((Object _) {}),
    );
  }
});

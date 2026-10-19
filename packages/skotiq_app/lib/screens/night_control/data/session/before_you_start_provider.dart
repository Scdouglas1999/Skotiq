// "Before you start": every check between the rig as it stands and a run.
//
// It merges the device states, the disk projection for the loaded plan, the
// weather source, the configured dawn policy and the first-light setup steps
// of `tonight_checklist_panel.dart` (site, capture folder, devices, solver).
// The catalogs step has no row here: annotation catalogs do not stop a run.
//
// The dawn row states the policy the weather-safety evaluator and SafeRig
// actually apply (commits 196685ed0 and ce865087e):
//  * no site on record: there is no dawn rule at all;
//  * "Park before dawn" off: nothing parks the mount at dawn;
//  * on, with a site: 30 minutes before astronomical dawn a running run is
//    parked; a mount with nothing running only has its tracking turned off.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import '../../night_control_contracts.dart';
import 'conditions_provider.dart';
import 'equipment_summary_provider.dart';
import 'session_format.dart';
import 'session_stats_provider.dart';

const String _equipmentRoute = '/equipment';
const String _siteRoute = '/settings?section=location';
const String _folderRoute = '/settings?section=files-storage';
const String _solverRoute = '/settings/plate-solving';
const String _weatherRoute = '/settings?section=weather-safety';

/// The dawn rule's lead time, as `WeatherSafetyNotifier` applies it.
const Duration kNightParkBeforeDawnLead = Duration(minutes: 30);

/// The plate solver the operator picked, and whether it is installed.
@immutable
class NightSolverStatus {
  const NightSolverStatus({required this.ready, this.name});

  final bool ready;

  /// "ASTAP" or "Astrometry.net"; null when none is installed.
  final String? name;
}

/// Null while detection runs: a solver still being looked for is not a
/// missing solver.
final nightSolverStatusProvider = Provider<NightSolverStatus?>((ref) {
  final detection = ref.watch(plateSolverDetectionProvider).valueOrNull;
  final preference = ref.watch(plateSolverPreferenceProvider).valueOrNull;
  if (detection == null || preference == null) return null;
  final ready = detection.supports(preference.choice);
  final name = switch (preference.choice) {
    PlateSolverChoice.astap => 'ASTAP',
    PlateSolverChoice.astrometry => 'Astrometry.net',
    PlateSolverChoice.auto => detection.astapReady
        ? 'ASTAP'
        : detection.astrometryPath != null
            ? 'Astrometry.net'
            : null,
  };
  return NightSolverStatus(ready: ready, name: ready ? name : null);
});

/// The loaded plan's disk projection; null without a plan or while it runs.
final nightDiskProjectionProvider = Provider<DiskSpaceProjection?>((ref) {
  return ref.watch(sequenceDiskProjectionProvider).valueOrNull?.projection;
});

/// When the dawn rule parks a running run tonight: 30 minutes before the
/// next astronomical dawn at the site. Null when the site has no
/// astronomical dawn (a night that never gets fully dark).
///
/// "Next" the way the rule reads it: last night's dawn while it is still
/// ahead (after midnight), otherwise tonight's.
DateTime? nightDawnParkTime({
  required DateTime now,
  required double latitude,
  required double longitude,
}) {
  for (final day in [now.subtract(const Duration(days: 1)), now]) {
    final dawn = SkyCalculations.computeTwilight(
      noonLocal: DateTime(day.year, day.month, day.day, 12),
      latitudeDegrees: latitude,
      longitudeDegrees: longitude,
      kind: TwilightKind.astronomical,
    ).morningStart;
    if (dawn == null || now.isAfter(dawn)) continue;
    return dawn.subtract(kNightParkBeforeDawnLead);
  }
  return null;
}

ChecklistItemVm _row(
  ChecklistItemId id,
  ChecklistItemState state,
  String titleKey, {
  NightText? detail,
  String? actionKey,
  String? route,
}) =>
    ChecklistItemVm(
      id: id,
      state: state,
      title: NightText(titleKey),
      detail: detail,
      actionLabel: actionKey == null ? null : NightText(actionKey),
      route: route,
    );

ChecklistItemVm _notConnected(
  ChecklistItemId id,
  String titleKey,
  ChecklistItemState state,
) =>
    _row(
      id,
      state,
      titleKey,
      detail: const NightText('nightSessionDeviceNotConnected'),
      actionKey: 'nightSessionActionConnect',
      route: _equipmentRoute,
    );

final nightBeforeYouStartProvider = Provider<List<ChecklistItemVm>>((ref) {
  final camera = ref.watch(cameraStateProvider);
  final wheel = ref.watch(filterWheelStateProvider);
  final focuser = ref.watch(focuserStateProvider);
  final mount = ref.watch(mountStateProvider);
  final guider = ref.watch(guiderStateProvider);
  final phd2 = ref.watch(phd2StateProvider);
  final assigned = ref.watch(assignedProfileDeviceSlotsProvider).toSet();
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  final solver = ref.watch(nightSolverStatusProvider);
  final projection = ref.watch(nightDiskProjectionProvider);
  final freeBytes = ref.watch(nightCaptureFreeBytesProvider);
  final conditions = ref.watch(nightConditionsSourceProvider);
  final safety = ref.watch(nightSafetyReadingProvider);

  final rows = <ChecklistItemVm>[];

  // Camera: the one device a run cannot start without.
  if (!nightConnected(camera.connectionState)) {
    rows.add(
      _notConnected(
        ChecklistItemId.camera,
        'nightSessionCheckCamera',
        ChecklistItemState.blocked,
      ),
    );
  } else {
    final temp = camera.temperature;
    rows.add(
      _row(
        ChecklistItemId.camera,
        ChecklistItemState.ok,
        'nightSessionCheckCamera',
        detail: temp == null
            ? const NightText('nightSessionCheckConnected')
            : camera.isCooling && (temp - camera.targetTemp).abs() >= 0.5
                ? NightText(
                    'nightSessionCheckCameraCooling',
                    params: <String, String>{
                      'temp': nightFixed(temp, 1),
                      'target': nightFixed(camera.targetTemp, 0),
                    },
                  )
                : NightText(
                    'nightSessionCheckCameraAt',
                    params: <String, String>{'temp': nightCelsius(temp)},
                  ),
      ),
    );
  }

  // Filter wheel and focuser: checked when connected or when the profile
  // assigns one.
  if (nightConnected(wheel.connectionState)) {
    final slot = wheel.currentPosition;
    final names = wheel.filterNames;
    final name =
        slot != null && slot >= 0 && slot < names.length ? names[slot] : null;
    rows.add(
      _row(
        ChecklistItemId.filterWheel,
        ChecklistItemState.ok,
        'nightSessionCheckFilter',
        detail: NightText(
          name == null || name.isEmpty
              ? 'nightSessionCheckFilterSlots'
              : 'nightSessionCheckFilterSlotsAt',
          params: <String, String>{
            'count': '${names.length}',
            if (name != null) 'name': name,
          },
        ),
      ),
    );
  } else if (assigned.contains(ProfileDeviceSlot.filterWheel)) {
    rows.add(
      _notConnected(
        ChecklistItemId.filterWheel,
        'nightSessionCheckFilter',
        ChecklistItemState.attention,
      ),
    );
  }

  if (nightConnected(focuser.connectionState)) {
    final position = focuser.position;
    rows.add(
      _row(
        ChecklistItemId.focuser,
        ChecklistItemState.ok,
        'nightSessionCheckFocuser',
        detail: position == null
            ? const NightText('nightSessionCheckConnected')
            : NightText.literal(nightGrouped(position)),
      ),
    );
  } else if (assigned.contains(ProfileDeviceSlot.focuser)) {
    rows.add(
      _notConnected(
        ChecklistItemId.focuser,
        'nightSessionCheckFocuser',
        ChecklistItemState.attention,
      ),
    );
  }

  // Mount: readiness treats it as desirable, not required, so a missing
  // mount needs a look rather than blocking.
  if (nightConnected(mount.connectionState)) {
    rows.add(
      _row(
        ChecklistItemId.mount,
        mount.isParked ? ChecklistItemState.attention : ChecklistItemState.ok,
        'nightSessionCheckMount',
        detail: NightText(
          mount.isParked
              ? (mount.isTracking
                  ? 'nightSessionCheckMountParkedTracking'
                  : 'nightSessionCheckMountParked')
              : (mount.isTracking
                  ? 'nightSessionCheckMountTracking'
                  : 'nightSessionCheckMountIdle'),
        ),
      ),
    );
  } else {
    rows.add(
      _notConnected(
        ChecklistItemId.mount,
        'nightSessionCheckMount',
        ChecklistItemState.attention,
      ),
    );
  }

  // Guider: connected but idle is the board's "!" row with an in-place Loop.
  if (nightConnected(guider.connectionState)) {
    final working = phd2 == Phd2State.guiding ||
        phd2 == Phd2State.looping ||
        phd2 == Phd2State.calibrating ||
        phd2 == Phd2State.settling;
    rows.add(
      working
          ? _row(
              ChecklistItemId.guider,
              ChecklistItemState.ok,
              'nightSessionCheckGuider',
              detail: NightText(nightPhd2StateKey(phd2)),
            )
          : _row(
              ChecklistItemId.guider,
              ChecklistItemState.attention,
              'nightSessionCheckGuider',
              detail: guider.deviceName == null
                  ? const NightText('nightSessionCheckGuiderIdleUnnamed')
                  : NightText(
                      'nightSessionCheckGuiderIdle',
                      params: <String, String>{'name': guider.deviceName!},
                    ),
              actionKey: 'nightSessionActionLoop',
            ),
    );
  } else if (assigned.contains(ProfileDeviceSlot.guider)) {
    rows.add(
      _notConnected(
        ChecklistItemId.guider,
        'nightSessionCheckGuider',
        ChecklistItemState.attention,
      ),
    );
  }

  if (solver != null) {
    rows.add(
      solver.ready
          ? _row(
              ChecklistItemId.solver,
              ChecklistItemState.ok,
              'nightSessionCheckSolver',
              detail: solver.name == null
                  ? const NightText('nightSessionCheckSolverReady')
                  : NightText.literal(solver.name!),
            )
          : _row(
              ChecklistItemId.solver,
              ChecklistItemState.attention,
              'nightSessionCheckSolver',
              detail: const NightText('nightSessionCheckSolverMissing'),
              actionKey: 'nightSessionActionSetUp',
              route: _solverRoute,
            ),
    );
  }

  // Disk: the capture folder first (a setup step), then the plan's needs.
  if (settings != null && settings.imageOutputPath.trim().isEmpty) {
    rows.add(
      _row(
        ChecklistItemId.disk,
        ChecklistItemState.blocked,
        'nightSessionCheckDisk',
        detail: const NightText('nightSessionCheckDiskNoFolder'),
        actionKey: 'nightSessionActionChoose',
        route: _folderRoute,
      ),
    );
  } else if (projection != null) {
    rows.add(
      _row(
        ChecklistItemId.disk,
        switch (projection.severity) {
          DiskSpaceSeverity.blocking => ChecklistItemState.blocked,
          DiskSpaceSeverity.warning => ChecklistItemState.attention,
          DiskSpaceSeverity.info => ChecklistItemState.ok,
        },
        'nightSessionCheckDisk',
        detail: NightText(
          'nightSessionCheckDiskPlan',
          params: <String, String>{
            'free': nightBytes(projection.freeBytes),
            'need': nightBytes(projection.projectedBytes),
          },
        ),
      ),
    );
  } else if (freeBytes != null) {
    rows.add(
      _row(
        ChecklistItemId.disk,
        ChecklistItemState.ok,
        'nightSessionCheckDisk',
        detail: NightText(
          'nightSessionCheckDiskFree',
          params: <String, String>{'free': nightBytes(freeBytes)},
        ),
      ),
    );
  }

  // Weather: without a device, safety has nothing to react to.
  switch (conditions) {
    case ConditionsSource.device:
      final safe = safety.safe;
      rows.add(
        !safety.monitoring
            ? _row(
                ChecklistItemId.weather,
                ChecklistItemState.attention,
                'nightSessionCheckWeather',
                detail: const NightText('nightSessionCheckWeatherOff'),
                actionKey: 'nightSessionActionSettings',
                route: _weatherRoute,
              )
            : _row(
                ChecklistItemId.weather,
                safe == false
                    ? ChecklistItemState.attention
                    : ChecklistItemState.ok,
                'nightSessionCheckWeather',
                detail: NightText(
                  safe == null
                      ? 'nightSessionCheckWeatherDevice'
                      : safe
                          ? 'nightSessionCheckWeatherSafe'
                          : 'nightSessionCheckWeatherUnsafe',
                ),
              ),
      );
    case ConditionsSource.forecast:
      rows.add(
        _row(
          ChecklistItemId.weather,
          ChecklistItemState.attention,
          'nightSessionCheckWeather',
          detail: const NightText('nightSessionCheckWeatherForecast'),
          actionKey: 'nightSessionActionAdd',
          route: _weatherRoute,
        ),
      );
    case ConditionsSource.none:
      rows.add(
        _row(
          ChecklistItemId.weather,
          ChecklistItemState.attention,
          'nightSessionCheckWeather',
          detail: const NightText('nightSessionCheckWeatherNone'),
          actionKey: 'nightSessionActionAdd',
          route: _weatherRoute,
        ),
      );
  }

  // Dawn and site: both read the stored settings, so both wait for them.
  if (settings != null) {
    if (!settings.hasObserverLocation) {
      rows.add(
        _row(
          ChecklistItemId.dawn,
          ChecklistItemState.attention,
          'nightSessionCheckDawn',
          detail: const NightText('nightSessionCheckDawnNoSite'),
        ),
      );
    } else if (!settings.parkBeforeDawn) {
      rows.add(
        _row(
          ChecklistItemId.dawn,
          ChecklistItemState.attention,
          'nightSessionCheckDawn',
          detail: const NightText('nightSessionCheckDawnOff'),
        ),
      );
    } else {
      final park = nightDawnParkTime(
        now: ref.watch(nightSessionNowProvider),
        latitude: settings.latitude,
        longitude: settings.longitude,
      );
      rows.add(
        park == null
            ? _row(
                ChecklistItemId.dawn,
                ChecklistItemState.ok,
                'nightSessionCheckDawn',
                detail: const NightText('nightSessionCheckDawnNoDark'),
              )
            : _row(
                ChecklistItemId.dawn,
                ChecklistItemState.ok,
                'nightSessionCheckDawn',
                detail: NightText(
                  'nightSessionCheckDawnPark',
                  params: <String, String>{
                    'time': nightClockTime(ref.watch(clockProvider), park),
                  },
                ),
              ),
      );
    }
    if (!settings.hasObserverLocation) {
      rows.add(
        _row(
          ChecklistItemId.site,
          ChecklistItemState.attention,
          'nightSessionCheckSite',
          detail: const NightText('nightSessionCheckSiteMissing'),
          actionKey: 'nightSessionActionSetSite',
          route: _siteRoute,
        ),
      );
    }
  }

  return rows;
});

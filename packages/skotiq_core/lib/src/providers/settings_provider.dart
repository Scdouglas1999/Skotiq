import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/remote_host.dart';
import '../backend/skotiq_backend.dart';
import 'database_provider.dart';
import 'backend_provider.dart';
import 'frame_watch_settings_provider.dart';
import 'host_settings/host_settings_providers.dart';
import '../models/plate_solver.dart';
import '../models/site/learned_obstruction.dart';
import '../models/site/location_settings.dart';
import '../models/site/site_horizon_profile.dart';
import '../models/settings/app_settings.dart' as models;
import '../models/settings/app_settings.dart'
    show ObserverLocation, SafetyFailMode;
import '../models/imaging/imaging_models.dart'
    show AutofocusSettings, FilterAutofocusConfig;
import '../settings/app_settings_codec.dart';
import '../settings/app_settings_state.g.dart';
import '../settings/preflight_strictness.dart';
import '../settings/setting.dart';
import '../models/focuser_backlash_calibration.dart'
    show FocuserBacklashCalibrationSettings;
import '../database/daos/settings_dao.dart';
import '../models/backend/backend_types.dart';
import 'plate_solve_service_provider.dart';

// Section parts: AppSettingsNotifier is one notifier split across `part` files
// under `settings_sections/`, one per UI / domain section. `part` rather than
// separate notifiers because the underlying `app_settings` row is a single
// Drift record and the remote-sync subscription in `build()` applies per-field
// `settings.changed` events to one in-memory state; section files also share
// the notifier's private helpers (`_saveSetting`, `_patchState`, `_unset`)
// without leaking them to the public API.
//
// A new setting is one entry in `settings/app_settings_table.dart` plus a
// setter in its section file.
part 'settings_sections/general.dart';
part 'settings_sections/appearance.dart';
part 'settings_sections/location.dart';
part 'settings_sections/environment.dart';
part 'settings_sections/recovery.dart';
part 'settings_sections/image_grading.dart';
part 'settings_sections/adaptive_exposure.dart';
part 'settings_sections/preflight.dart';
part 'settings_sections/smart_night.dart';
part 'settings_sections/session_lifecycle.dart';
part 'settings_sections/autofocus.dart';
part 'settings_sections/equipment.dart';
part 'settings_sections/file_paths.dart';
part 'settings_sections/imaging.dart';
part 'settings_sections/notifications.dart';
part 'settings_sections/phd2.dart';
part 'settings_sections/plate_solve.dart';
part 'settings_sections/protocol.dart';
part 'settings_sections/catalogs.dart';
part 'settings_sections/remote_access.dart';
part 'settings_sections/sequencer.dart';
part 'settings_sections/app_settings_notifier.dart';
part 'settings_sections/app_settings_site.dart';

/// The fields of [after] that differ from [before], in the JSON form
/// `POST /api/settings` takes, so a client save sends only what it changed.
///
/// The site is one value spread over four keys; when any of them changes the
/// patch carries all four, so the host never combines half of a new site with
/// half of the old one.
Map<String, dynamic> remoteSettingsPatch(
  models.AppSettings before,
  models.AppSettings after,
) {
  final b = jsonDecode(jsonEncode(before.toJson())) as Map<String, dynamic>;
  final a = jsonDecode(jsonEncode(after.toJson())) as Map<String, dynamic>;
  final patch = <String, dynamic>{
    for (final key in {...b.keys, ...a.keys})
      if (jsonEncode(b[key]) != jsonEncode(a[key])) key: a[key],
  };
  const siteKeys = {'latitude', 'longitude', 'elevation', 'location'};
  if (patch.keys.any(siteKeys.contains)) {
    for (final key in siteKeys) {
      if (a.containsKey(key)) patch[key] = a[key];
    }
  }
  return patch;
}

@immutable
class AppSettingsWriteFailure {
  final String setting;
  final Object error;
  final DateTime occurredAt;

  const AppSettingsWriteFailure({
    required this.setting,
    required this.error,
    required this.occurredAt,
  });

  String get message =>
      'Could not save $setting. The displayed value may not match the host.';
}

/// Central error channel for settings controls whose async setter callback is
/// intentionally fire-and-forget (switches, sliders, and text fields).
final appSettingsWriteFailureProvider = StateProvider<AppSettingsWriteFailure?>(
  (ref) => null,
);

final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettingsState>(() {
      return AppSettingsNotifier();
    });

/// Effective horizon in degrees selected from [appSettingsProvider].
///
/// The same value is consumed by the Run Dashboard's "time-to-set"
/// statistic and by the planetarium target-card so both surfaces display
/// the same number to the second. Falls back to 0° (mathematical horizon)
/// before settings have loaded.
final effectiveHorizonDegProvider = Provider<double>((ref) {
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  return settings?.effectiveHorizonDeg ?? 0.0;
});

/// Focused observer-location selector derived from [appSettingsProvider].
///
/// Watching this provider avoids rebuilding weather/suggestion chains when
/// unrelated settings change.
final appObserverLocationProvider = Provider<LocationSettings?>((ref) {
  final location = ref.watch(
    appSettingsProvider.select(
      (settingsAsync) => settingsAsync.valueOrNull == null
          ? null
          : (
              latitude: settingsAsync.valueOrNull!.latitude,
              longitude: settingsAsync.valueOrNull!.longitude,
              elevation: settingsAsync.valueOrNull!.elevation,
            ),
    ),
  );

  if (location == null) {
    return null;
  }
  // One rule, one home: [siteLocationIsSet] is the canonical not-set test.
  if (!siteLocationIsSet(location.latitude, location.longitude)) {
    return null;
  }

  return LocationSettings(
    latitude: location.latitude,
    longitude: location.longitude,
    elevation: location.elevation,
  );
});

/// Convenience provider that derives a typed [AutofocusSettings] from the
/// persisted [AppSettingsState] autofocus fields.
///
/// This avoids every consumer needing to manually pluck out individual
/// `af_*` fields and parse the filter settings JSON.
final autofocusSettingsProvider = Provider<AutofocusSettings>((ref) {
  final settingsAsync = ref.watch(appSettingsProvider);
  final settings = settingsAsync.valueOrNull;
  if (settings == null) {
    return const AutofocusSettings();
  }

  return AutofocusSettings(
    method: settings.afMethod,
    curveFitting: settings.afCurveFitting,
    stepSize: settings.afStepSize,
    exposureTime: settings.afExposureTime,
    initialOffsetSteps: settings.afInitialOffsetSteps,
    numberOfAttempts: settings.afNumberOfAttempts,
    useBrightestNStars: settings.afUseBrightestNStars,
    outerCropRatio: settings.afOuterCropRatio,
    innerCropRatio: settings.afInnerCropRatio,
    binning: settings.afBinning,
    rSquaredThreshold: settings.afRSquaredThreshold,
    failureHfrToleranceRatio: settings.afFailureHfrToleranceRatio,
    disableGuidingDuringAf: settings.afDisableGuidingDuringAf,
    focuserSettleTimeMs: settings.afFocuserSettleTimeMs,
    exposuresPerPoint: settings.afExposuresPerPoint,
    backlashCompMethod: settings.afBacklashCompMethod,
    backlashIn: settings.afBacklashIn,
    backlashOut: settings.afBacklashOut,
    autofocusFilterName: settings.afAutofocusFilterName,
    filterSettings: AutofocusSettings.parseFilterSettingsJson(
      settings.afFilterSettingsJson,
    ),
  );
});

/// Whether the equipment connects when the app starts.
///
/// Hardware moves only on a stored choice: a database with no row for it
/// connects nothing, although the setting itself is on when nothing is
/// stored and a new install is given that row.
class AutoConnectSettingsNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final setting = AppSettingDefs.autoConnectEquipment;
    final rows = await ref.read(settingsDaoProvider).readRows([setting]);
    return setting.fromRows(rows, false);
  }
}

final autoConnectSettingsProvider =
    AsyncNotifierProvider<AutoConnectSettingsNotifier, bool>(() {
      return AutoConnectSettingsNotifier();
    });

/// Focused provider for Bortle class.
final bortleClassProvider = Provider<int>((ref) {
  final settingsAsync = ref.watch(appSettingsProvider);
  return settingsAsync.valueOrNull?.bortleClass ?? 5;
});

/// Focused provider for parsed horizon profile.
///
/// The operator's profile with the obstructions the runs learned at the
/// current site merged in (see [userHorizonProfileProvider] for the profile
/// alone, which is what the horizon editor edits).
final horizonProfileProvider = Provider<SiteHorizonProfile>((ref) {
  final profile = ref.watch(userHorizonProfileProvider);
  final site = ref.watch(appObserverLocationProvider);
  if (site == null) return profile;
  final learned =
      ref
          .watch(frameWatchSettingsProvider)
          .valueOrNull
          ?.pointsForSite(site.latitude, site.longitude) ??
      const <LearnedObstructionPoint>[];
  if (learned.isEmpty) return profile;
  return profile.withLearnedObstructions(learned);
});

/// The operator's own horizon profile, without learned obstructions.
final userHorizonProfileProvider = Provider<SiteHorizonProfile>((ref) {
  final json = ref.watch(
    appSettingsProvider.select(
      (settingsAsync) =>
          settingsAsync.valueOrNull?.horizonProfileJson ??
          '{"N":0,"NE":0,"E":0,"SE":0,"S":0,"SW":0,"W":0,"NW":0}',
    ),
  );
  return SiteHorizonProfile.fromJson(json);
});

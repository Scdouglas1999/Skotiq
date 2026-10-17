import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
// The barrel's `HorizonProfile` is the scheduler's samples-based class;
// this screen needs the legacy 8-point compass profile, exported through
// the barrel under the `LegacyHorizonProfile` alias (see
// `src/legacy_aliases.dart`).
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../../utils/confirm_dialog.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/geolocation_consent.dart';
import '../../../widgets/tutorial_keys/settings_keys.dart';
import 'settings_widgets.dart';

part 'location_settings_parts/_timezone_data.dart';

typedef HorizonImportPicker = Future<file_selector.XFile?> Function();
typedef HorizonImportReader = Future<String> Function(
  file_selector.XFile file,
);

/// Resolves this machine's position through the three positioning tiers —
/// the platform's location service, a Wi-Fi scan resolved by a positioning
/// service, then the public-IP estimate — and reports what each one did.
/// Injected so the consent, radio-power and write flows can be driven in
/// tests without a network, a GPS or a wireless card.
typedef SiteLocator = Future<PositioningAttempt> Function({
  required bool allowWifiScan,
  required bool allowIp,
  bool mayEnableWifiRadio,
  String? googleApiKey,
});

final siteLocatorProvider = Provider<SiteLocator>(
  (ref) => GeolocationService.locate,
);

typedef PlaceSearcher = Future<List<PlaceSearchHit>> Function(String query);

final placeSearchProvider = Provider<PlaceSearcher>(
  (ref) => GeolocationService.searchPlaces,
);

Future<file_selector.XFile?> _pickHorizonImport() {
  return file_selector.openFile(
    acceptedTypeGroups: [
      const file_selector.XTypeGroup(
        label: 'Horizon profile (.hor / .csv / .txt)',
        extensions: ['hor', 'csv', 'txt'],
      ),
    ],
  );
}

final horizonImportPickerProvider =
    Provider<HorizonImportPicker>((ref) => _pickHorizonImport);

final horizonImportReaderProvider = Provider<HorizonImportReader>(
  (ref) => (file) => File(file.path).readAsString(),
);

class LocationSettingsPage extends ConsumerStatefulWidget {
  final bool isMobile;

  const LocationSettingsPage({super.key, this.isMobile = false});

  @override
  ConsumerState<LocationSettingsPage> createState() => _LocationSettingsState();
}

class _LocationSettingsState extends ConsumerState<LocationSettingsPage> {
  final _latController = TextEditingController();
  final _lonController = TextEditingController();
  final _elevController = TextEditingController();
  final _placeSearchController = TextEditingController();
  final Map<String, TextEditingController> _horizonControllers = {};
  bool _isImportingHorizon = false;
  int _horizonImportGeneration = 0;
  bool _legacyTimezoneMigrated = false;
  bool _placeSearching = false;
  List<PlaceSearchHit> _placeHits = const [];
  bool _detecting = false;

  /// Set when a detect ran and the precise Wi-Fi tier was skipped because the
  /// radio is off. It is the one failure the operator can fix from this page,
  /// so the offer to fix it only appears once we know it applies — a row
  /// advertising Wi-Fi on a machine with no wireless card would be noise.
  bool _wifiRadioOffersPrecision = false;

  final _googleKeyController = TextEditingController();
  final _googleKeyFocus = FocusNode();
  bool _googleKeySeeded = false;

  @override
  void initState() {
    super.initState();
    for (final dir in horizonDirections) {
      _horizonControllers[dir] = TextEditingController();
    }
    // Commit on blur as well as on Enter: a pasted key followed by a click
    // elsewhere is the normal way this field gets filled, and losing it there
    // would look like the key was rejected.
    _googleKeyFocus.addListener(() {
      if (!_googleKeyFocus.hasFocus) {
        unawaited(_saveGoogleKey(_googleKeyController.text));
      }
    });
  }

  @override
  void dispose() {
    _latController.dispose();
    _lonController.dispose();
    _elevController.dispose();
    _placeSearchController.dispose();
    _googleKeyController.dispose();
    _googleKeyFocus.dispose();
    for (final c in _horizonControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (!_isImportingHorizon ||
          previous == null ||
          identical(previous, next)) {
        return;
      }
      _horizonImportGeneration++;
      setState(() => _isImportingHorizon = false);
    });

    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => SettingsLoadingState(
        isMobile: widget.isMobile,
      ),
      error: (error, stack) => SettingsErrorState(
        isMobile: widget.isMobile,
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final authority = ref.watch(backendProvider);
        final isRemoteMode = ref.watch(isRemoteModeProvider);
        final storedGoogleKey = ref.watch(googleGeolocationKeyProvider).value;
        if (storedGoogleKey != null) _seedGoogleKey(storedGoogleKey);
        final horizonProfile =
            LegacyHorizonProfile.fromJson(settings.horizonProfileJson);
        _migrateLegacyTimezone(settings);

        return SettingsPage(
          key: SettingsTutorialKeys.location,
          title: 'Location',
          description: 'Observatory location for calculations',
          isMobile: widget.isMobile,
          hideHeader: widget.isMobile,
          children: [
            SettingsSection(
              title: 'Coordinates',
              isMobile: widget.isMobile,
              children: [
                // A fresh profile seeds observer_latitude/longitude/elevation
                // at 0.0 before the user has been asked anything, so these
                // three editors open reading "0 °", "0 °", "0 m" — a settled
                // position, in the same type as a site somebody typed. The
                // Dashboard one click away says "Set an observing location",
                // and Weather and Plan Tonight both say "Location not
                // configured", so this page was the one surface still
                // presenting the placeholder as fact.
                //
                // Say so, in the app's warning colour, the way the Sequencer's
                // target card says "Not set" over its 0h/+0° placeholder
                // instead of printing `00h 00m 00s`.
                if (!settings.hasObserverLocation)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(
                      SkotiqTokens.spaceLg,
                      SkotiqTokens.spaceLg,
                      SkotiqTokens.spaceLg,
                      0,
                    ),
                    child: SkotiqBanner(
                      tone: BannerTone.warning,
                      title: 'Observing site not set',
                      message:
                          'The 0° / 0° / 0 m below are placeholders, not your '
                          'location. Skotiq will not compute twilight, '
                          'altitude or a plan from them — enter your '
                          'coordinates, search for a place, or use Detect '
                          'location, to set a site.',
                    ),
                  ),
                SettingRow(
                  icon: LucideIcons.search,
                  title: 'Search place',
                  subtitle:
                      'Town or observatory by name. Accurate on a desktop '
                      'with no GPS',
                  trailing: SizedBox(
                    width: widget.isMobile ? 180 : 240,
                    child: SkotiqTextField(
                      controller: _placeSearchController,
                      hint: 'Newtown Square, PA',
                      onSubmitted: (_) => _searchPlace(),
                      suffixWidget: GestureDetector(
                        onTap: _placeSearching ? null : _searchPlace,
                        child: Icon(
                          LucideIcons.search,
                          size: SkotiqTokens.iconXs,
                          color: SkotiqColors.of(context).textMuted,
                        ),
                      ),
                    ),
                  ),
                  controlFlex: 2,
                  isMobile: widget.isMobile,
                ),
                if (_placeHits.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      SkotiqTokens.spaceLg,
                      SkotiqTokens.spaceSm,
                      SkotiqTokens.spaceLg,
                      SkotiqTokens.spaceMd,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final hit in _placeHits)
                          GestureDetector(
                            onTap: () => _applyPlace(hit),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: SkotiqTokens.spaceSm,
                              ),
                              child: Text(
                                hit.elevation == null
                                    ? hit.label
                                    : '${hit.label} · ${hit.elevation!.round()} m',
                                style: SkotiqTypography.body.copyWith(
                                  color: SkotiqColors.of(context).textPrimary,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                SettingRow(
                  // Keyed, with Longitude and Elevation below.
                  //
                  // Without keys, the rebuild right after "Detect location"
                  // showed the latitude in the Longitude field and the
                  // longitude in Elevation. The stored values were always
                  // correct and navigating away and back cleared it, so the
                  // only moment it was visible was the one where the operator
                  // checks what was just detected. Two siblings above these
                  // rows are conditional — the "observing site not set" banner
                  // and the place-search results — so setting a site shrinks
                  // the list by one and these three identical SettingRows can
                  // take their neighbours' state.
                  //
                  // Verified by driving the built app: detect on a profile
                  // with no site, unkeyed, reproduced it every time; keyed, the
                  // fields are right immediately. A widget test does NOT
                  // reproduce it — the same provider transition renders
                  // correctly under flutter_test with or without these keys —
                  // so there is deliberately no regression test here rather
                  // than one that would pass either way.
                  key: const ValueKey('site-latitude-row'),
                  icon: LucideIcons.mapPin,
                  title: 'Latitude',
                  subtitle: 'Decimal degrees or DMS (44 3 29 N). Positive is '
                      'North, negative is South',
                  trailing: SettingsNumberInput(
                    controller: _latController,
                    authoritativeValue: settings.latitude,
                    authorityKey: authority,
                    suffix: '\u00B0',
                    min: -90,
                    max: 90,
                    decimals: 6,
                    parse: (text) => parseSiteAngle(
                      text,
                      maxDegrees: 90,
                      positiveHemisphere: 'N',
                      negativeHemisphere: 'S',
                    ),
                    onChanged: (value) async {
                      await ref
                          .read(appSettingsProvider.notifier)
                          .setLatitude(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                  isMobile: widget.isMobile,
                ),
                SettingRow(
                  key: const ValueKey('site-longitude-row'),
                  icon: LucideIcons.mapPin,
                  title: 'Longitude',
                  subtitle: 'Decimal degrees or DMS (121 18 55 W). Positive is '
                      'East, negative is West',
                  trailing: SettingsNumberInput(
                    controller: _lonController,
                    authoritativeValue: settings.longitude,
                    authorityKey: authority,
                    suffix: '\u00B0',
                    min: -180,
                    max: 180,
                    decimals: 6,
                    parse: (text) => parseSiteAngle(
                      text,
                      maxDegrees: 180,
                      positiveHemisphere: 'E',
                      negativeHemisphere: 'W',
                    ),
                    onChanged: (value) async {
                      await ref
                          .read(appSettingsProvider.notifier)
                          .setLongitude(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                  isMobile: widget.isMobile,
                ),
                SettingRow(
                  key: const ValueKey('site-elevation-row'),
                  icon: LucideIcons.mountain,
                  title: 'Elevation',
                  subtitle: 'Height above sea level',
                  trailing: SettingsNumberInput(
                    controller: _elevController,
                    authoritativeValue: settings.elevation,
                    authorityKey: authority,
                    suffix: 'm',
                    min: -500,
                    max: 10000,
                    decimals: 0,
                    onChanged: (value) async {
                      await ref
                          .read(appSettingsProvider.notifier)
                          .setElevation(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                  isLast: false,
                  isMobile: widget.isMobile,
                ),
                // Only a remote session HAS a server to read from: over a local
                // backend `profileSettingsBackendProvider` reads this app's own
                // settings store, so the row wrote the values back unchanged
                // and still reported "Location synced from server".
                if (isRemoteMode)
                  SettingRow(
                    icon: LucideIcons.refreshCw,
                    title: 'Sync from server',
                    subtitle: 'Fetch location from the connected imaging host',
                    trailing: SkotiqIconButton(
                      icon: LucideIcons.downloadCloud,
                      tooltip: 'Fetch the site from the imaging host',
                      color: SkotiqColors.of(context).primary,
                      onPressed: () async {
                        try {
                          final actionAuthority = ref.read(backendProvider);
                          final backend =
                              ref.read(profileSettingsBackendProvider);
                          final location = await backend.getLocation();

                          if (!mounted ||
                              !identical(
                                ref.read(backendProvider),
                                actionAuthority,
                              )) {
                            if (mounted) {
                              this.context.showWarningSnackBar(
                                    'The imaging host changed while syncing. '
                                    'Try again on the current host.',
                                  );
                            }
                            return;
                          }

                          if (location != null) {
                            await ref
                                .read(appSettingsProvider.notifier)
                                .updateLocation(
                                  latitude: location.latitude,
                                  longitude: location.longitude,
                                  elevation: location.elevation,
                                );
                            if (context.mounted) {
                              context.showSuccessSnackBar(
                                  'Location read from the imaging host');
                            }
                          } else {
                            if (context.mounted) {
                              this.context.showWarningSnackBar(
                                  'No location available from server');
                            }
                          }
                        } catch (e) {
                          if (context.mounted) {
                            context.showErrorSnackBar('Sync failed: $e');
                          }
                        }
                      },
                    ),
                    isLast: false,
                    isMobile: widget.isMobile,
                  ),
                SettingRow(
                  icon: LucideIcons.locate,
                  // Not "GPS": the same click walks all three tiers, and the
                  // subtitle names the one that actually gets you a yard.
                  title: 'Detect location',
                  subtitle: 'Nearby Wi-Fi networks place you to within '
                      'about 100 m. Falls back to this machine’s GPS or '
                      'your internet address.',
                  trailing: SkotiqIconButton(
                    icon: LucideIcons.crosshair,
                    tooltip: 'Detect this location',
                    color: SkotiqColors.of(context).primary,
                    onPressed:
                        _detecting ? null : () => _detectLocation(settings),
                  ),
                  isLast: !_wifiRadioOffersPrecision,
                  isMobile: widget.isMobile,
                ),
                if (_wifiRadioOffersPrecision)
                  SettingRow(
                    icon: LucideIcons.wifi,
                    title: 'Turn Wi-Fi on for a precise fix',
                    subtitle: 'Wi-Fi is switched off, so the precise scan was '
                        'skipped. Skotiq will switch it on, scan for '
                        'nearby networks, and switch it back off.',
                    trailing: SkotiqButton(
                      label: 'Scan',
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      isLoading: _detecting,
                      onPressed: _detecting
                          ? null
                          : () => _detectLocation(
                                settings,
                                mayEnableWifiRadio: true,
                              ),
                    ),
                    isLast: true,
                    isMobile: widget.isMobile,
                  ),
              ],
            ),
            SettingsSection(
              title: 'Advanced',
              isMobile: widget.isMobile,
              children: [
                SettingRow(
                  icon: LucideIcons.key,
                  title: 'Google Geolocation API key',
                  subtitle: 'Optional. beaconDB, the key-free service Detect '
                      'location uses, is mapped by volunteers and has no '
                      'coverage in plenty of places; with a key from Google '
                      'Cloud’s Geolocation API the same list of nearby '
                      'networks goes to a far larger map first. The key is '
                      'stored on this machine and sent only to Google.',
                  trailing: SizedBox(
                    width: widget.isMobile ? 180 : 240,
                    child: SkotiqTextField(
                      controller: _googleKeyController,
                      focusNode: _googleKeyFocus,
                      hint: 'Paste a key, or leave empty',
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      onSubmitted: (value) => unawaited(_saveGoogleKey(value)),
                    ),
                  ),
                  controlFlex: 2,
                  isLast: true,
                  isMobile: widget.isMobile,
                ),
              ],
            ),
            SettingsSection(
              title: 'Observing environment',
              isMobile: widget.isMobile,
              children: [
                SettingRow(
                  icon: LucideIcons.sun,
                  title: 'Bortle class',
                  subtitle: BortleScale.description(settings.bortleClass),
                  trailing: SettingsDropdown(
                    value: settings.bortleClass.toString(),
                    items: List.generate(9, (i) => '${i + 1}'),
                    itemLabels: List.generate(
                      9,
                      (i) => '${i + 1} - ${BortleScale.description(i + 1)}',
                    ),
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setBortleClass(int.parse(value));
                    },
                    width: widget.isMobile ? 200 : 280,
                    isMobile: widget.isMobile,
                  ),
                  isMobile: widget.isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.eye,
                  title: 'Limiting magnitude',
                  subtitle:
                      'Estimated naked-eye limit for Bortle ${settings.bortleClass}',
                  trailing: Text(
                    '${BortleScale.limitingMagnitude(settings.bortleClass).toStringAsFixed(1)}m',
                    style: SkotiqTypography.bodyStrong
                        .copyWith(color: SkotiqColors.of(context).textPrimary),
                  ),
                  isLast: true,
                  isMobile: widget.isMobile,
                ),
              ],
            ),
            SettingsSection(
              title: 'Local horizon mask',
              isMobile: widget.isMobile,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                  child: Text(
                    'Set minimum observable altitude at each compass direction. '
                    'Objects below these altitudes are considered obstructed by terrain, '
                    'trees, or buildings.\n'
                    // The resolution actually in force, stated where the mask
                    // is edited. These eight numbers are a summary whenever a
                    // survey is loaded, and the whole model otherwise — and
                    // which of the two it is decides whether a target inside
                    // an obstructed sector is refused or allowed.
                    '${horizonProfile.sampleCount >= 2 ? 'An imported survey of '
                        '${horizonProfile.sampleCount} samples is in use — the '
                        'planner and sky chart interpolate it. These eight '
                        'fields summarise it by sector; editing any of them '
                        'replaces the survey with your eight values.' : 'These '
                        'eight 45° sectors are the whole mask, so the tallest '
                        'obstruction in a sector applies across all of it. '
                        'Import a .hor / CSV survey to keep full resolution.'}',
                    style: SkotiqTypography.caption.copyWith(
                      color: SkotiqColors.of(context).textSecondary,
                    ),
                  ),
                ),
                // The horizon mask (`horizon_profile_json`) is intentionally
                // non-remotable \u2014 editing it over NetworkBackend throws. Show a
                // host-only notice instead of editors that can't persist.
                if (isRemoteMode)
                  Padding(
                    padding:
                        const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                    child: Text(
                      'The local horizon mask can only be edited on the imaging '
                      'host.',
                      style: SkotiqTypography.caption.copyWith(
                        color: SkotiqColors.of(context).textSecondary,
                      ),
                    ),
                  )
                else ...[
                  ...List.generate(horizonDirections.length, (i) {
                    final dir = horizonDirections[i];
                    final azimuth = horizonDirectionAzimuths[i];
                    return SettingRow(
                      icon: _compassIcon(dir),
                      title: '$dir (${azimuth.toStringAsFixed(0)}\u00B0)',
                      subtitle: 'Horizon altitude at $dir',
                      trailing: SettingsNumberInput(
                        controller: _horizonControllers[dir]!,
                        authoritativeValue: horizonProfile.altitudeAt(dir),
                        authorityKey: authority,
                        suffix: '\u00B0',
                        min: 0,
                        max: 89,
                        decimals: 0,
                        onChanged: (_) => _updateHorizonProfile(),
                        isMobile: widget.isMobile,
                      ),
                      isLast: i == horizonDirections.length - 1,
                      isMobile: widget.isMobile,
                    );
                  }),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          icon: _isImportingHorizon
                              ? const SizedBox.square(
                                  dimension: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  LucideIcons.upload,
                                  size: 14,
                                  color: SkotiqColors.of(context).primary,
                                ),
                          label: Text(
                              _isImportingHorizon
                                  ? 'Importing horizon...'
                                  : 'Import .hor / CSV',
                              style: SkotiqTypography.caption.copyWith(
                                color: _isImportingHorizon
                                    ? SkotiqColors.of(context).textMuted
                                    : SkotiqColors.of(context).primary,
                              )),
                          onPressed:
                              _isImportingHorizon ? null : _importHorizonFile,
                        ),
                        TextButton.icon(
                          icon: Icon(LucideIcons.rotateCcw,
                              size: 14,
                              color: SkotiqColors.of(context).primary),
                          label: Text('Reset All to 0\u00B0',
                              style: SkotiqTypography.caption.copyWith(
                                color: SkotiqColors.of(context).primary,
                              )),
                          onPressed: () => _resetHorizon(horizonProfile),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            SettingsSection(
              title: 'Time',
              isMobile: widget.isMobile,
              children: [
                SettingRow(
                  icon: LucideIcons.clock,
                  title: 'Timezone',
                  subtitle: _timezoneSubtitle(settings),
                  trailing: SettingsDropdown(
                    value: utcOffsetForTimezone(settings.timezone),
                    items: kUtcOffsetTimezones,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setTimezone(value);
                    },
                    width: widget.isMobile ? 160 : 200,
                    isMobile: widget.isMobile,
                  ),
                  isMobile: widget.isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.globe,
                  title: 'Use system time',
                  subtitle: 'Sync time from operating system',
                  trailing: SettingsSwitch(
                    value: settings.useSystemTime,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setUseSystemTime(value);
                    },
                  ),
                  isLast: true,
                  isMobile: widget.isMobile,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// How far the resolved position may sit from the stored one before the
  /// stored elevation is treated as belonging to a different place. An IP
  /// estimate is accurate to roughly a city (~10 km), so a fix inside this
  /// radius is plausibly the same observing site.
  static const double _sameSiteRadiusKm = 25;

  /// Great-circle distance in kilometres.
  static double _kmBetween(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusKm = 6371.0;
    double toRad(double deg) => deg * math.pi / 180.0;
    final dLat = toRad(lat2 - lat1);
    final dLon = toRad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(toRad(lat1)) *
            math.cos(toRad(lat2)) *
            math.pow(math.sin(dLon / 2), 2);
    return earthRadiusKm * 2 * math.asin(math.min(1.0, math.sqrt(a)));
  }

  Future<void> _searchPlace() async {
    final query = _placeSearchController.text.trim();
    if (query.isEmpty || _placeSearching) return;
    setState(() => _placeSearching = true);
    try {
      final hits = await ref.read(placeSearchProvider)(query);
      if (!mounted) return;
      setState(() {
        _placeSearching = false;
        _placeHits = hits;
      });
      if (hits.isEmpty) {
        context.showWarningSnackBar('No places matched that name.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _placeSearching = false);
      context.showErrorSnackBar('Could not search for a place: $e');
    }
  }

  Future<void> _applyPlace(PlaceSearchHit hit) async {
    await ref.read(appSettingsProvider.notifier).updateLocation(
          latitude: hit.latitude,
          longitude: hit.longitude,
          elevation: hit.elevation ?? 0.0,
        );
    if (!mounted) return;
    setState(() => _placeHits = const []);
    final elev = hit.elevation;
    context.showSuccessSnackBar(
      elev == null
          ? 'Coordinates set to ${hit.label}. Elevation cleared to 0 m — '
              'enter the elevation for this site.'
          : 'Coordinates set to ${hit.label}. Elevation ${elev.round()} m.',
    );
  }

  /// Seed the Google key field from storage once, and keep it in step with
  /// whatever the store holds. The field is the operator's text while they
  /// are typing, so it is seeded rather than rebuilt from the provider.
  void _seedGoogleKey(String stored) {
    if (_googleKeySeeded) return;
    _googleKeySeeded = true;
    _googleKeyController.text = stored;
  }

  Future<void> _saveGoogleKey(String value) async {
    final notifier = ref.read(googleGeolocationKeyProvider.notifier);
    if (ref.read(googleGeolocationKeyProvider).value == value.trim()) return;
    await notifier.setKey(value);
    if (!mounted) return;
    context.showSuccessSnackBar(
      value.trim().isEmpty
          ? 'Google key cleared. Detect location will use beaconDB only.'
          : 'Google key saved. Detect location will ask Google first.',
    );
  }

  /// Resolve this machine's position, with consent, and never leave the
  /// site in a state that does not exist.
  ///
  /// Three rules. ASK before the lookup, once per session, naming each tier
  /// that will run: the Wi-Fi tier sends the names of the networks around the
  /// house and the IP tier sends a public address, and this app is often run
  /// on an isolated observatory network. NEVER mix a new fix with a stale
  /// elevation: carrying the old value through gives a site that does not
  /// exist, feeding refraction and horizon maths. And never CHANGE the
  /// machine unasked — [mayEnableWifiRadio] is set only by the explicit "Turn
  /// Wi-Fi on for a precise fix" row, and the radio is switched back off
  /// afterwards.
  Future<void> _detectLocation(
    AppSettingsState rendered, {
    bool mayEnableWifiRadio = false,
  }) async {
    if (_detecting) return;
    final googleKey = ref.read(googleGeolocationKeyProvider).value ?? '';
    // Shared with the first-run wizard's site step, which fires the same
    // service: one dialog means the two surfaces cannot describe the outbound
    // request differently, or one of them forget to ask.
    final consented = await ensureGeolocationConsent(
      context,
      ref,
      outcome: kGeolocationWritesSiteOutcome,
      googleKeyPresent: googleKey.isNotEmpty,
    );
    if (!consented || !mounted) return;

    setState(() => _detecting = true);
    try {
      final actionAuthority = ref.read(backendProvider);
      // Re-read rather than trust the value this row was built with: the
      // operator can edit the elevation while the consent dialog is up, and
      // the same-site comparison below has to be against what is stored now.
      final settings = ref.read(appSettingsProvider).value ?? rendered;
      final attempt = await ref.read(siteLocatorProvider)(
        allowWifiScan: true,
        allowIp: true,
        mayEnableWifiRadio: mayEnableWifiRadio,
        googleApiKey: googleKey.isEmpty ? null : googleKey,
      );
      if (!mounted || !identical(ref.read(backendProvider), actionAuthority)) {
        if (mounted) {
          context.showWarningSnackBar(
            'The imaging host changed while reading the device location. Try '
            'again on the current host.',
          );
        }
        return;
      }
      setState(() => _wifiRadioOffersPrecision = attempt.canRetryWithWifi);

      final location = attempt.fix;
      if (location == null) {
        context.showWarningSnackBar(
          'No position from Wi-Fi, this machine, or the internet lookup. '
          '${attempt.failureDetail} Search for a place by name, or enter '
          'coordinates.',
        );
        return;
      }

      final lat = location.latitude;
      final lon = location.longitude;
      final movedKm =
          _kmBetween(settings.latitude, settings.longitude, lat, lon);
      final keepElevation = movedKm <= _sameSiteRadiusKm;
      await ref.read(appSettingsProvider.notifier).updateLocation(
            latitude: lat,
            longitude: lon,
            // Clearing beats inheriting: an elevation from another site is a
            // wrong number the app would use, while 0 m is the app's own
            // "not set" value and is called out in the message below.
            elevation: keepElevation ? settings.elevation : 0,
          );
      if (!mounted) return;
      final where = location.locationName ??
          '${lat.toStringAsFixed(4)}, '
              '${lon.toStringAsFixed(4)}';
      context.showSuccessSnackBar(
        'Coordinates set to $where. ${location.explanation} '
        '${keepElevation ? 'Elevation kept at '
            '${settings.elevation.toStringAsFixed(0)} m.' : 'Elevation '
            'cleared to 0 m — enter the elevation for this site.'} '
        '${_refinementNudge(attempt)}',
      );
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Could not detect a location: $e');
      }
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  /// What to do about a fix that may be wrong.
  ///
  /// A switched-off radio is the one cause the operator can remove, so it
  /// takes priority over the generic nudge — pointing someone at the map when
  /// a precise fix is one click away is the worse advice.
  static String _refinementNudge(PositioningAttempt attempt) =>
      attempt.canRetryWithWifi
          ? 'Turn Wi-Fi on for a precise fix.'
          : 'Refine on the map if it is off.';

  /// Import a horizon obstruction profile from a Stellarium-style `.hor` file
  /// or a CSV of `azimuth,altitude` pairs. Every sample is persisted, and the
  /// eight compass fields on this page summarise them (highest altitude per
  /// 45° sector, so the number shown never under-reports an obstruction).
  ///
  /// [LegacyHorizonProfile] carries the SAMPLES, not just the eight sector
  /// summaries, and interpolates them in `altitudeAtAzimuth` — the call the
  /// planner's visibility filter and the planetarium's 360-entry terrain table
  /// both make. Keeping only the summaries applies one 29° tree across a whole
  /// 45° sector and refuses targets that are plainly clear.
  Future<void> _importHorizonFile() async {
    if (_isImportingHorizon) return;
    final generation = ++_horizonImportGeneration;
    final authority = ref.read(backendProvider);
    setState(() => _isImportingHorizon = true);

    try {
      final file = await ref.read(horizonImportPickerProvider)();
      if (file == null || !_isCurrentHorizonImport(generation, authority)) {
        return;
      }

      final content = await ref.read(horizonImportReaderProvider)(file);
      if (!_isCurrentHorizonImport(generation, authority)) return;
      final imported = LegacyHorizonProfile.parseHorizonText(content);
      final sampleCount = _countHorizonSamples(content);

      final confirmed = await _confirmHorizonReduction(
        fileName: file.name,
        sampleCount: sampleCount,
        imported: imported,
      );
      if (confirmed != true ||
          !_isCurrentHorizonImport(generation, authority)) {
        return;
      }

      await ref
          .read(appSettingsProvider.notifier)
          .setHorizonProfileJson(imported.toJson());
      if (!mounted || !_isCurrentHorizonImport(generation, authority)) {
        return;
      }

      context.showSuccessSnackBar(
        'Horizon imported from ${file.name} — $sampleCount '
        '${sampleCount == 1 ? 'sample' : 'samples'} stored; the eight fields '
        'below summarise them by sector.',
      );
    } on FormatException catch (e) {
      if (mounted && _isCurrentHorizonImport(generation, authority)) {
        context.showErrorSnackBar('Could not import horizon: ${e.message}');
      }
    } catch (e) {
      if (mounted && _isCurrentHorizonImport(generation, authority)) {
        context.showErrorSnackBar('Could not import horizon file: $e');
      }
    } finally {
      if (_isCurrentHorizonImport(generation, authority)) {
        setState(() => _isImportingHorizon = false);
      }
    }
  }

  /// How many azimuth/altitude samples the file actually contained.
  ///
  /// Counts the lines [LegacyHorizonProfile.parseHorizonText] treats as data:
  /// it skips blanks and `#`/`//`/`;` comments and REQUIRES every remaining
  /// line to be a valid pair (it throws otherwise), so after a successful
  /// parse this count is the sample count. Deliberately does not re-parse the
  /// numbers — the parser above is the authority on what is a sample.
  static int _countHorizonSamples(String text) {
    var count = 0;
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#') ||
          trimmed.startsWith('//') ||
          trimmed.startsWith(';')) {
        continue;
      }
      count++;
    }
    return count;
  }

  /// Show what the import is about to store before it overwrites the mask.
  ///
  /// Returns true only if the user accepted it.
  Future<bool?> _confirmHorizonReduction({
    required String fileName,
    required int sampleCount,
    required LegacyHorizonProfile imported,
  }) {
    final colors = SkotiqColors.of(context);
    // The survey is kept whole; the eight fields are its summary. Stated in
    // both directions because the eight numbers below are what the operator
    // will then SEE on this page, and a 36-sample import that displays as
    // eight numbers looks exactly like an import that threw 28 of them away.
    final resolution = imported.sampleCount >= 2
        ? 'All $sampleCount are stored and interpolated between, so the '
            'planner and the sky chart use the skyline your file describes, '
            'not a 45°-wide step.'
        : 'A single sample describes a flat horizon, so it is stored as one '
            'altitude all the way round.';
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Import horizon from $fileName?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$sampleCount ${sampleCount == 1 ? 'sample' : 'samples'} read. '
                '$resolution',
              ),
              const SizedBox(height: 12),
              Text(
                'Summarised on this page as the tallest obstruction in each '
                'of the eight 45° sectors:',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  for (final dir in horizonDirections)
                    Text(
                      '$dir ${imported.altitudeAt(dir).toStringAsFixed(0)}°',
                      style: SkotiqTypography.body.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'This replaces the current mask. Editing any of the eight '
                'values afterwards replaces the imported skyline with those '
                'eight sector altitudes.',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        actions: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => Navigator.pop(dialogContext, false),
          ),
          SkotiqButton(
            label: 'Import',
            variant: ButtonVariant.primary,
            size: ButtonSize.small,
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      ),
    );
  }

  /// Flatten the horizon mask — after asking, whenever there is something to
  /// lose.
  ///
  /// "Reset All to 0°" sits on the same row as "Import .hor / CSV", about
  /// 120 px from it. A survey is hours of work with a compass and an
  /// inclinometer, the app does not keep the source file, and there is no undo,
  /// so a misclick beside Import would cost the whole skyline.
  Future<void> _resetHorizon(LegacyHorizonProfile current) async {
    final hasSurvey = current.sampleCount >= 2;
    final hasMask = horizonDirections.any((dir) => current.altitudeAt(dir) > 0);

    if (hasSurvey || hasMask) {
      final what = hasSurvey
          ? 'The imported survey of ${current.sampleCount} samples, and the '
              'eight sector values below it, will be replaced by a flat 0° '
              'horizon.'
          : 'The eight sector values below will be replaced by a flat 0° '
              'horizon.';
      final confirmed = await ConfirmDialog.show(
        context: context,
        title: 'Reset the horizon mask?',
        message: '$what Skotiq does not keep the file it was imported '
            'from, so this cannot be undone.',
        confirmLabel: 'Reset horizon',
        isDestructive: true,
      );
      if (!confirmed || !mounted) return;
    }

    try {
      final reset = <String, double>{
        for (final dir in horizonDirections) dir: 0,
      };
      await ref.read(appSettingsProvider.notifier).setHorizonProfileJson(
            LegacyHorizonProfile(reset).toJson(),
          );
    } catch (error) {
      if (mounted) {
        context.showErrorSnackBar('Could not reset the horizon mask: $error');
      }
    }
  }

  bool _isCurrentHorizonImport(
    int generation,
    SkotiqBackend authority,
  ) {
    return mounted &&
        generation == _horizonImportGeneration &&
        identical(ref.read(backendProvider), authority);
  }

  Future<void> _updateHorizonProfile() async {
    final parts = <String>[];
    for (final dir in horizonDirections) {
      final text = _horizonControllers[dir]!.text;
      final val = double.tryParse(text)?.clamp(0.0, 89.0) ?? 0.0;
      parts.add('"$dir":${val.toStringAsFixed(1)}');
    }
    final json = '{${parts.join(',')}}';
    await ref.read(appSettingsProvider.notifier).setHorizonProfileJson(json);
  }

  IconData _compassIcon(String direction) {
    return switch (direction) {
      'N' => LucideIcons.arrowUp,
      'NE' => LucideIcons.arrowUpRight,
      'E' => LucideIcons.arrowRight,
      'SE' => LucideIcons.arrowDownRight,
      'S' => LucideIcons.arrowDown,
      'SW' => LucideIcons.arrowDownLeft,
      'W' => LucideIcons.arrowLeft,
      'NW' => LucideIcons.arrowUpLeft,
      _ => LucideIcons.compass,
    };
  }

  /// What the Timezone row can honestly say about the value below it.
  ///
  /// Reads [clockProvider] rather than the raw setting, so the sentence
  /// describes the clock actually in force — a row that says nothing leaves a
  /// picker that changes no displayed time with no claim to falsify.
  String _timezoneSubtitle(AppSettingsState settings) {
    if (settings.useSystemTime) {
      return 'Ignored while "Use system time" is on — times follow this '
          "computer's clock";
    }
    final clock = ref.watch(clockProvider);
    if (clock is! FixedOffsetClock) {
      return 'Skotiq cannot apply "${settings.timezone}", so times follow '
          "this computer's clock — choose a UTC offset";
    }
    final now = clock.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return 'Capture timestamps and scheduling use ${clock.label} — now '
        '$hh:$mm (fixed offset, no daylight saving)';
  }

  /// Rewrites an IANA label left by the previous picker to the equivalent
  /// standard-time UTC offset.
  ///
  /// `clockProvider` parses only `UTC` and `UTC±HH:MM`, so a stored IANA name
  /// resolves to null and silently falls back to the system clock while the
  /// setting still persists and displays. Migrating means the choice the
  /// operator already made is honoured.
  void _migrateLegacyTimezone(AppSettingsState settings) {
    if (_legacyTimezoneMigrated) return;
    final stored = settings.timezone;
    if (kUtcOffsetTimezones.contains(stored)) return;
    final mapped = kLegacyIanaUtcOffsets[stored];
    if (mapped == null) return;
    _legacyTimezoneMigrated = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await ref.read(appSettingsProvider.notifier).setTimezone(mapped);
      } catch (error) {
        // A host-only/remote write failure leaves the stored label in place;
        // the row's subtitle then reports that it is not being applied.
        debugPrint('Could not migrate legacy timezone "$stored": $error');
      }
    });
  }
}

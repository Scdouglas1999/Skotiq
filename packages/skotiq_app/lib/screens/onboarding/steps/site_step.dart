import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../../utils/snackbar_helper.dart';
import '../../../widgets/geolocation_consent.dart';

/// Why the observing-site step will not let the wizard advance, or null when the
/// current entry is acceptable.
///
/// The step owns the in-progress field text, so the wizard shell cannot
/// re-derive validity from the onboarding draft or from persisted settings — a
/// rejected coordinate never reaches either. The shell reads this before Next
/// and "Skip this step" advance, which is what stops an out-of-range entry from
/// being waved through with its red error still on screen.
final onboardingSiteEntryErrorProvider = StateProvider<String?>((ref) => null);

/// The approximate-location lookup that *offers* a starting point. Injected so
/// tests exercise the suggestion UI without reaching the network.
typedef ApproximateLocationLookup = Future<(double, double, String?)?>
    Function();

final onboardingApproximateLocationProvider =
    Provider<ApproximateLocationLookup>(
  (ref) => GeolocationService.fetchLocation,
);

/// The lookup behind "Use my current location": the three positioning tiers
/// — the platform's location service, a Wi-Fi scan resolved by a positioning
/// service, then the public-IP estimate — with what each one did, so the
/// confirmation can say how precise the answer is and the step can offer the
/// one failure the operator can fix. Injected so the consent, radio-power and
/// elevation rules can be driven in tests without a network or a GPS.
typedef SiteLocator = Future<PositioningAttempt> Function({
  required bool allowWifiScan,
  required bool allowIp,
  bool mayEnableWifiRadio,
  String? googleApiKey,
});

final onboardingSiteLocatorProvider = Provider<SiteLocator>(
  (ref) => GeolocationService.locate,
);

/// Observing-site step.
///
/// The rest of the wizard builds an equipment profile; this step captures the
/// one piece of setup that is not equipment — where the user observes from.
/// With no site on record every location-driven surface falls back to its
/// "your location is not set" state.
///
/// Unlike the device steps this writes straight through to app settings via
/// [appSettingsProvider] rather than the onboarding draft: the coordinates are
/// global observer settings, not per-profile. The step is optional — a user
/// setting up indoors during the day can skip it and be nudged from the
/// next-steps screen.
///
/// Two rules keep a site the user never chose out of the database:
///
///  * **An unusable entry reverts to what the step started with.** Typing "100"
///    transits the in-range prefixes "1" and "10", so persisting each keystroke
///    would put 10°N on record. Whenever the pair is incomplete or out of range
///    the step puts back the coordinates it was seeded with — synchronously, so
///    Next cannot arrive before the commit — and a typo can neither invent a
///    site nor destroy the one already saved.
///  * **An IP estimate is a suggestion, never a default.** It is offered as a
///    labelled starting point the user accepts explicitly, never written to
///    settings behind their back; `location_sync_service.dart` owns why. The
///    explicit "Use my current location" path is different: the operator asked
///    for a fix, consented to the outbound request, and is told when the
///    answer came from the internet rather than a receiver.
class OnboardingSiteStep extends ConsumerStatefulWidget {
  const OnboardingSiteStep({super.key});

  @override
  ConsumerState<OnboardingSiteStep> createState() => _OnboardingSiteStepState();
}

class _OnboardingSiteStepState extends ConsumerState<OnboardingSiteStep> {
  final _latController = TextEditingController();
  final _lonController = TextEditingController();
  final _elevController = TextEditingController();

  String? _latError;
  String? _lonError;
  String? _elevError;

  /// The site as it stood when the step was entered. An entry that is not a
  /// usable coordinate pair restores these rather than leaving a partially typed
  /// value on record.
  double _baselineLat = 0.0;
  double _baselineLon = 0.0;

  /// Guards the one-time controller seed from persisted settings. Re-seeding on
  /// every rebuild would fight the user's in-progress typing.
  bool _seeded = false;
  bool _locating = false;

  /// IP-derived starting point, offered only when there is no site on record.
  (double, double, String?)? _ipEstimate;
  bool _ipLookupStarted = false;
  bool _ipLookupRunning = false;

  /// Set when a lookup ran and the precise Wi-Fi tier was skipped because the
  /// radio is off — the one failure the operator can fix from here, so the
  /// offer only appears once we know it applies.
  bool _wifiRadioOffersPrecision = false;

  @override
  void dispose() {
    _latController.dispose();
    _lonController.dispose();
    _elevController.dispose();
    super.dispose();
  }

  /// Prefill the fields from persisted settings, but only when the user has an
  /// actual site on record. lat/lon both at 0.0 is the "null island" default,
  /// not a real Gulf-of-Guinea observatory, so we leave the fields blank there
  /// to prompt real entry rather than seeding a misleading 0/0.
  void _seedFrom(AppSettingsState settings) {
    if (_seeded) return;
    _seeded = true;
    final hasSite = settings.hasObserverLocation;
    _baselineLat = settings.latitude;
    _baselineLon = settings.longitude;
    if (hasSite) {
      _latController.text = _trimNumber(settings.latitude);
      _lonController.text = _trimNumber(settings.longitude);
    }
    if (settings.elevation != 0.0) {
      _elevController.text = settings.elevation.toStringAsFixed(0);
    }
    // Re-publish the blocking reason for the seeded text. The provider outlives
    // this widget, so a stale reason left by an earlier visit would otherwise
    // block Next until the user happened to touch a field. Seeded values are
    // always valid, so this normally clears it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishBlockingReason();
    });
    // Deliberately NO lookup here. Skotiq is routinely installed on
    // isolated observatory networks, so arriving on this step makes no outbound
    // request: the offer waits for an explicit [_lookUpIpEstimate].
  }

  /// True when the coordinate fields hold a usable pair, so the "no site on
  /// record" offer has been answered.
  ///
  /// Derived rather than latched at seed time: a one-shot flag would leave the
  /// banner directly above the fields reading "No site on record yet", and
  /// still offering to estimate one, after "Use my current location" filled
  /// them in.
  bool get _siteEntered =>
      _validateLatitude(_latController.text.trim()) == null &&
      _validateLongitude(_lonController.text.trim()) == null &&
      _latController.text.trim().isNotEmpty &&
      _lonController.text.trim().isNotEmpty;

  /// Fetch an approximate position to *offer*, once the operator has asked for
  /// it and agreed to the request. Failure is silent: a first run with no
  /// network must show manual entry, not an error the user cannot act on.
  Future<void> _lookUpIpEstimate() async {
    if (_ipLookupRunning) return;
    final consented = await ensureGeolocationConsent(
      context,
      ref,
      outcome: kGeolocationOffersEstimateOutcome,
      // This offer is the IP tier alone: it never scans for Wi-Fi, so it must
      // not ask for — or silently inherit — consent to send the networks
      // around the house anywhere.
      includeWifiScan: false,
    );
    if (!consented || !mounted) return;
    setState(() {
      _ipLookupStarted = true;
      _ipLookupRunning = true;
    });
    final estimate = await ref.read(onboardingApproximateLocationProvider)();
    if (!mounted) return;
    setState(() {
      _ipLookupRunning = false;
      _ipEstimate = estimate;
    });
  }

  /// Accept the IP estimate as the starting point. This is the only path by
  /// which an IP-derived coordinate reaches settings, and it requires a click.
  Future<void> _applyIpEstimate() async {
    final estimate = _ipEstimate;
    if (estimate == null) return;
    final (lat, lon, _) = estimate;
    _latController.text = _trimNumber(_roundLookup(lat));
    _lonController.text = _trimNumber(_roundLookup(lon));
    _onFieldChanged();
  }

  static String? _validateLatitude(String raw) {
    if (raw.isEmpty) return null;
    final value = double.tryParse(raw);
    if (value == null || value < -90 || value > 90) {
      return 'Latitude must be between -90 and 90.';
    }
    return null;
  }

  static String? _validateLongitude(String raw) {
    if (raw.isEmpty) return null;
    final value = double.tryParse(raw);
    if (value == null || value < -180 || value > 180) {
      return 'Longitude must be between -180 and 180.';
    }
    return null;
  }

  static String? _validateElevation(String raw) {
    if (raw.isEmpty) return null;
    final value = double.tryParse(raw);
    if (value == null || value < -500 || value > 10000) {
      return 'Elevation must be between -500 and 10000 m.';
    }
    return null;
  }

  /// Validate every field on each keystroke so the inline error is immediate,
  /// publish the shell's blocking reason, then reconcile settings.
  void _onFieldChanged() {
    setState(() {
      _latError = _validateLatitude(_latController.text.trim());
      _lonError = _validateLongitude(_lonController.text.trim());
      _elevError = _validateElevation(_elevController.text.trim());
    });
    _publishBlockingReason();
    unawaited(_commitIfValid());
  }

  void _publishBlockingReason() {
    final latRaw = _latController.text.trim();
    final lonRaw = _lonController.text.trim();
    final halfASite = latRaw.isEmpty != lonRaw.isEmpty
        ? 'Enter both latitude and longitude, or clear both to skip this step.'
        : null;
    final reason = _latError ?? _lonError ?? _elevError ?? halfASite;
    ref.read(onboardingSiteEntryErrorProvider.notifier).state = reason;
  }

  /// Reconcile persisted settings with what is currently in the fields.
  ///
  /// Exactly three outcomes, evaluated against the *whole* field text rather
  /// than the keystroke that arrived:
  ///
  ///  * a valid, complete pair → persist it;
  ///  * both fields cleared → persist the unset 0/0 sentinel, so the database
  ///    agrees with the blank fields on screen instead of keeping a coordinate
  ///    the user just deleted;
  ///  * anything else (out of range, unparseable, or only one of the pair) →
  ///    restore the baseline. This is what keeps a rejected "100" from leaving
  ///    its in-range prefix "10" on record, and equally keeps a typo from
  ///    destroying a site that was already saved.
  Future<void> _commitIfValid() async {
    if (!mounted) return;
    final latRaw = _latController.text.trim();
    final lonRaw = _lonController.text.trim();
    final elevRaw = _elevController.text.trim();

    final double latitude;
    final double longitude;
    final entryIsUsable = _validateLatitude(latRaw) == null &&
        _validateLongitude(lonRaw) == null &&
        latRaw.isNotEmpty &&
        lonRaw.isNotEmpty;
    if (entryIsUsable) {
      latitude = double.parse(latRaw);
      longitude = double.parse(lonRaw);
    } else if (latRaw.isEmpty && lonRaw.isEmpty) {
      latitude = 0.0;
      longitude = 0.0;
    } else {
      latitude = _baselineLat;
      longitude = _baselineLon;
    }

    final elevation = _validateElevation(elevRaw) != null || elevRaw.isEmpty
        ? null
        : double.parse(elevRaw);

    final current = ref.read(appSettingsProvider).valueOrNull;
    if (current != null &&
        current.latitude == latitude &&
        current.longitude == longitude &&
        (elevation == null || current.elevation == elevation)) {
      return;
    }
    await ref.read(appSettingsProvider.notifier).updateLocation(
          latitude: latitude,
          longitude: longitude,
          elevation: elevation,
        );
  }

  /// Render a coordinate without a trailing ".0" so a whole-degree site does
  /// not display as "45.0".
  static String _trimNumber(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toString();
  }

  /// Round a looked-up coordinate to the precision the lookup can support.
  ///
  /// Both sources behind "Use my current location" are estimates — an IP lookup
  /// resolves to about 10 km — and the raw reading arrives with seven decimals,
  /// roughly a centimetre. Printing that invites the user to trust a guess, and
  /// disagrees with the review step, which already shows four. Four decimals is
  /// ~11 m: finer than any estimate here and still far finer than an observing
  /// site needs. A coordinate the user types is left exactly as typed.
  static double _roundLookup(double value) =>
      double.parse(value.toStringAsFixed(4));

  /// Resolve this machine's position and write the coordinates, mirroring
  /// Settings → Location's "Detect location" affordance — including its three
  /// rules. It asks before anything leaves the machine, naming each tier that
  /// will run (once per session, shared with Settings). It refuses to leave a
  /// stored elevation attached to a position it does not belong to. And it
  /// changes nothing about the machine unasked: [mayEnableWifiRadio] is set
  /// only by the explicit "Turn Wi-Fi on for a precise fix" offer, and the
  /// radio goes back off afterwards. Guards the async gap with a
  /// backend-authority check so a host switch mid-read never applies the
  /// reading to the replacement host.
  Future<void> _useDeviceLocation(
    AppSettingsState settings, {
    bool mayEnableWifiRadio = false,
  }) async {
    if (_locating) return;
    final googleKey = ref.read(googleGeolocationKeyProvider).value ?? '';
    final consented = await ensureGeolocationConsent(
      context,
      ref,
      outcome: kGeolocationWritesSiteOutcome,
      googleKeyPresent: googleKey.isNotEmpty,
    );
    if (!consented || !mounted) return;
    final authority = ref.read(backendProvider);
    setState(() => _locating = true);
    try {
      final attempt = await ref.read(onboardingSiteLocatorProvider)(
        allowWifiScan: true,
        allowIp: true,
        mayEnableWifiRadio: mayEnableWifiRadio,
        googleApiKey: googleKey.isEmpty ? null : googleKey,
      );
      if (!mounted || !identical(ref.read(backendProvider), authority)) {
        return;
      }
      setState(() => _wifiRadioOffersPrecision = attempt.canRetryWithWifi);
      final location = attempt.fix;
      if (location == null) {
        context.showWarningSnackBar(
          'No position from Wi-Fi, this machine, or the internet lookup. '
          '${attempt.failureDetail} Enter your coordinates below, or skip and '
          'set the site later in Settings → Location.',
        );
        return;
      }
      final name = location.locationName;
      final lat = _roundLookup(location.latitude);
      final lon = _roundLookup(location.longitude);
      // Only a site already on record can lend a stale elevation; on a first
      // run the field holds whatever the operator has just typed, which is
      // theirs to keep.
      final hasStoredSite = settings.hasObserverLocation;
      final keepElevation = !hasStoredSite ||
          _kmBetween(settings.latitude, settings.longitude, lat, lon) <=
              _sameSiteRadiusKm;
      await ref.read(appSettingsProvider.notifier).updateLocation(
            latitude: lat,
            longitude: lon,
            elevation: keepElevation ? null : 0,
          );
      if (!mounted || !identical(ref.read(backendProvider), authority)) return;
      _latController.text = _trimNumber(lat);
      _lonController.text = _trimNumber(lon);
      if (!keepElevation) _elevController.clear();
      setState(() {
        _latError = null;
        _lonError = null;
        if (!keepElevation) _elevError = null;
      });
      _publishBlockingReason();
      final where = name ?? '${_trimNumber(lat)}°, ${_trimNumber(lon)}°';
      context.showSuccessSnackBar(
        'Coordinates set to $where. ${location.explanation}'
        '${keepElevation ? '' : ' Elevation cleared — enter the elevation '
            'for this site.'}'
        // The wizard has no map and no place search, so the nudge points at
        // the fields directly below instead of an affordance that is not
        // here yet.
        '${location.isPrecise ? '' : attempt.canRetryWithWifi ? ' Turn Wi-Fi on for a precise fix.' : ' Correct the coordinates below if it is off.'}',
      );
    } catch (error) {
      if (mounted && identical(ref.read(backendProvider), authority)) {
        context.showErrorSnackBar('Could not read device location: $error');
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// How far a resolved position may sit from the stored one before the stored
  /// elevation is treated as belonging to a different place. Matches
  /// Settings → Location; an IP estimate is accurate to roughly a city.
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

  /// The IP estimate, presented as a suggestion with its provenance and its
  /// error budget stated plainly. It is deliberately not written into the
  /// coordinate fields until the user presses "Use this": a value sitting in the
  /// field looks like a value the app knows, and this one is a guess.
  Widget _buildIpEstimate() {
    final estimate = _ipEstimate;
    if (estimate != null) {
      return SkotiqBanner(
        icon: LucideIcons.globe,
        title: 'Approximate location from your IP address.',
        message: '${_trimNumber(estimate.$1)}°, ${_trimNumber(estimate.$2)}°'
            '${estimate.$3 != null ? ' — ${estimate.$3}' : ''}. '
            'This is where your internet provider appears to be, not where '
            'your telescope is, so it can be tens of kilometres out. Use it '
            'as a starting point and correct it if you can.',
        action: SkotiqButton(
          label: 'Use this',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => unawaited(_applyIpEstimate()),
        ),
      );
    }
    if (_ipLookupRunning) {
      return const SkotiqBanner(
        icon: LucideIcons.globe,
        title: 'Looking up an approximate location…',
      );
    }
    if (_ipLookupStarted) {
      return const SkotiqBanner(
        icon: LucideIcons.globe,
        tone: BannerTone.warning,
        title: 'Could not reach a geolocation service.',
        message: 'Enter your coordinates below.',
      );
    }
    return SkotiqBanner(
      icon: LucideIcons.globe,
      title: 'No site on record yet.',
      message: 'Skotiq can ask a third-party service to estimate your '
          'position from your public IP address — city-level, about 10 km. '
          'Nothing is sent until you ask.',
      action: SkotiqButton(
        label: 'Estimate from IP',
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        onPressed: () => unawaited(_lookUpIpEstimate()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => Center(
        child: CircularProgressIndicator(color: colors.primary),
      ),
      error: (error, _) => SkotiqBanner(
        tone: BannerTone.error,
        title: 'Could not load location settings.',
        message: '$error',
      ),
      data: (settings) {
        _seedFrom(settings);
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(
                icon: LucideIcons.mapPin,
                title: 'Where do you observe?',
              ),
              Text(
                'Your site drives Tonight, the planner’s visibility and dark '
                'windows, meridian-flip timing, and the weather radar. You can '
                'change it any time in Settings → Location.',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceLg),
              Row(
                children: [
                  // Flexible so a phone column bounds the button and its label
                  // ellipsizes; unbounded it takes its full intrinsic width and
                  // overflows the row by 13 px at 390 px.
                  Flexible(
                    child: SkotiqButton(
                      icon: LucideIcons.locate,
                      label: 'Use my current location',
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      isLoading: _locating,
                      onPressed:
                          _locating ? null : () => _useDeviceLocation(settings),
                    ),
                  ),
                ],
              ),
              if (_wifiRadioOffersPrecision) ...[
                const SizedBox(height: SkotiqTokens.spaceMd),
                SkotiqBanner(
                  icon: LucideIcons.wifi,
                  title: 'Turn Wi-Fi on for a precise fix.',
                  message: 'Wi-Fi is switched off, so the scan that places '
                      'you to within about 100 m was skipped. Skotiq '
                      'will switch it on, scan for nearby networks, and '
                      'switch it back off.',
                  action: SkotiqButton(
                    label: 'Scan',
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    isLoading: _locating,
                    onPressed: _locating
                        ? null
                        : () => unawaited(
                              _useDeviceLocation(
                                settings,
                                mayEnableWifiRadio: true,
                              ),
                            ),
                  ),
                ),
              ],
              if (!_siteEntered || _ipLookupRunning || _ipEstimate != null) ...[
                const SizedBox(height: SkotiqTokens.spaceMd),
                _buildIpEstimate(),
              ],
              const SizedBox(height: SkotiqTokens.spaceLg),
              // One form, one label column: side by side, latitude and
              // longitude left a 42 px field on a phone.
              _CoordinateField(
                controller: _latController,
                label: 'Latitude',
                hint: 'e.g. 40.71',
                suffix: '°',
                helper: 'Positive for North, negative for South',
                errorText: _latError,
                onChanged: _onFieldChanged,
              ),
              const SizedBox(height: FormRow.rowGap),
              _CoordinateField(
                controller: _lonController,
                label: 'Longitude',
                hint: 'e.g. -74.01',
                suffix: '°',
                helper: 'Positive for East, negative for West',
                errorText: _lonError,
                onChanged: _onFieldChanged,
              ),
              const SizedBox(height: FormRow.rowGap),
              _CoordinateField(
                controller: _elevController,
                label: 'Elevation',
                hint: 'e.g. 120',
                suffix: 'm',
                helper: 'Optional. Height above sea level, in metres',
                errorText: _elevError,
                onChanged: _onFieldChanged,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A labelled decimal coordinate input: a label, a [SkotiqTextField] that
/// accepts signed decimals, and a muted helper line. Mirrors the numeric-field
/// styling used by the camera-defaults step.
class _CoordinateField extends StatelessWidget {
  const _CoordinateField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.helper,
    required this.suffix,
    required this.onChanged,
    this.errorText,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final String helper;
  final String suffix;
  final String? errorText;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return FormRow(
      label: label,
      help: helper,
      child: SkotiqTextField(
        controller: controller,
        hint: hint,
        suffix: suffix,
        errorText: errorText,
        mono: true,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9\-\.]')),
        ],
        onChanged: (_) => onChanged(),
      ),
    );
  }
}

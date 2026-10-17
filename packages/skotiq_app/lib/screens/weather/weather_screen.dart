import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../widgets/weather/weather_radar_map.dart';
import '../../widgets/weather/radar_timeline_scrubber.dart';
import '../../widgets/weather/weather_status_card.dart';
import '../../widgets/weather/satellite_legend.dart';
import '../../widgets/tutorial_keys/weather_keys.dart';

part 'weather_screen/header_and_radar_controls.dart';
part 'weather_screen/safety_and_settings.dart';
part 'weather_screen/cloud_and_hardware.dart';

/// Width of the conditions HUD over the radar (05 §15 side-panel rhythm, one
/// step narrower because it floats on glass rather than owning a column).
const double _conditionsHudWidth = 300;

/// Below this the control bar drops its satellite legend and stacks its
/// transport over its options; above it everything fits on one row.
const double _controlBarWideWidth = 900;

/// How much of a narrow body the map keeps before the conditions panel takes
/// the rest. Half, clamped so the map stays a map and the panel stays useful.
const double _narrowMapFraction = 0.5;

/// Full weather monitoring screen: a full-bleed radar with a glass HUD.
///
/// The sky is the hero (02 rule 1), so the radar runs edge to edge under the
/// page header and the readouts float over it in glass. Four glass elements,
/// which is the ceiling 05 §14 sets: the source stamp (top-left) and the zoom
/// group (bottom-right) belong to [WeatherRadarMap]; the conditions HUD
/// (top-right) and the radar control bar (bottom) are built here.
///
/// Behaviour is unchanged from the card-grid version: the same providers, the
/// same 5-minute refresh, the same frame selection and the same snooze
/// controls.
class WeatherScreen extends ConsumerStatefulWidget {
  const WeatherScreen({super.key});

  @override
  ConsumerState<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends ConsumerState<WeatherScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  // Animation state.
  //
  // Null means "nobody has scrubbed": the timeline then follows the live edge
  // of the loop (see [latestObservedRadarFrameIndex]) and keeps following it
  // across the 5-minute refresh. A fixed 0 opened the screen on the OLDEST
  // frame — up to two hours of history behind the NOW marker the scrubber
  // draws — so the map you glanced at showed cloud that had already moved on.
  int? _selectedFrameIndex;
  bool _isPlaying = false;
  double _playbackSpeed = 1.0;
  double _radarOpacity = 0.7;
  double _radarContrast = 1.5; // Default to moderate contrast enhancement
  bool _statusCardExpanded = true;
  bool _displayControlsOpen = false;

  // Refresh timer. Suspended when the app is backgrounded so a hidden window
  // doesn't keep hammering the radar API every five minutes.
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fadeController = AnimationController(
      vsync: this,
      duration: SkotiqTokens.durationSmooth,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: SkotiqTokens.curveStandard,
    );
    _fadeController.forward();

    _startRefreshTimer();

    // Initial fetch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshWeatherData();
    });
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _refreshWeatherData();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_refreshTimer == null || !_refreshTimer!.isActive) {
        _startRefreshTimer();
        // Catch up immediately after resume so radar isn't stale.
        _refreshWeatherData();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fadeController.dispose();
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _refreshWeatherData() {
    // Invalidate the radar frames provider to trigger a fresh fetch
    ref.invalidate(weatherRadarFramesProvider);
    // Also refresh motion analysis and alert evaluation
    ref.invalidate(analyzeCloudMotionProvider);
    ref.invalidate(evaluateWeatherConditionsProvider);
    // Refresh cloud cover percentage
    ref.invalidate(cloudCoverPercentageProvider);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final weatherStatus = ref.watch(weatherStatusProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final appSettings = settingsAsync.valueOrNull;
    final weatherSettingsAsync = ref.watch(weatherSettingsDataProvider);
    final motionAsync = ref.watch(analyzeCloudMotionProvider);
    final alertAsync = ref.watch(evaluateWeatherConditionsProvider);
    final cloudCoverAsync = ref.watch(cloudCoverPercentageProvider);
    final radarSource = ref.watch(radarSourceInfoProvider);
    final safetyState = ref.watch(weatherSafetyProvider);
    final weatherSettings = ref.watch(weatherSettingsProvider);

    // Get location from settings
    final latitude = appSettings?.latitude ?? 0.0;
    final longitude = appSettings?.longitude ?? 0.0;
    final hasLocation = !(latitude == 0.0 && longitude == 0.0);

    // Get weather settings for alert radius. The map needs a number and reads
    // 0 as "draw no ring"; the readout must NOT — a settings store that has not
    // answered yet is an unknown radius, which is an em dash, not "0 km".
    final weatherSettingsData = weatherSettingsAsync.valueOrNull;
    final alertRadiusKm = weatherSettingsData?.triggerDistanceKm;

    final radarFrames = weatherStatus.radarFrames;
    final motion = motionAsync.valueOrNull;
    final alert = alertAsync.valueOrNull;

    final settingsLoading =
        settingsAsync.isLoading || weatherSettingsAsync.isLoading;
    final settingsFailed =
        settingsAsync.hasError || weatherSettingsAsync.hasError;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              _WeatherHeader(
                status: safetyState.status,
                monitoring: safetyState.monitoringEnabled,
                onRefresh: _refreshWeatherData,
                onSettingsTap: () =>
                    context.go('/settings?section=weather-safety'),
                isLoading: settingsLoading || weatherStatus.isLoading,
              ),
              // ONE banner, for the highest-priority problem only (02 rule 4).
              // The safety verdict itself is the header chip, not a banner.
              _WeatherBanner(
                showFetchFailure: !settingsLoading &&
                    !settingsFailed &&
                    hasLocation &&
                    weatherStatus.errorMessage != null,
                autoParkStranded: weatherSettings.autoParkEnabled &&
                    !safetyState.autoParkArmed &&
                    safetyState.monitoringEnabled,
                onRetry: _refreshWeatherData,
                onOpenSettings: () =>
                    context.go('/settings?section=weather-safety'),
              ),
              Expanded(
                child: settingsLoading
                    ? const _WeatherLoadingBody()
                    : settingsFailed
                        ? _SettingsUnavailableBody(
                            onRetry: () => ref.invalidate(appSettingsProvider),
                          )
                        : hasLocation
                            ? _buildRadarBody(
                                latitude: latitude,
                                longitude: longitude,
                                alertRadiusKm: alertRadiusKm,
                                radarFrames: radarFrames,
                                motion: motion,
                                alert: alert,
                                weatherStatus: weatherStatus,
                                cloudCoverPercent: cloudCoverAsync.valueOrNull,
                                radarSource: radarSource,
                              )
                            : const _NoLocationBody(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The full-bleed radar and its glass HUD.
  Widget _buildRadarBody({
    required double latitude,
    required double longitude,
    required double? alertRadiusKm,
    required List<RadarFrame> radarFrames,
    required CloudMotion? motion,
    required WeatherAlert? alert,
    required WeatherStatus weatherStatus,
    required double? cloudCoverPercent,
    required RadarSourceInfo radarSource,
  }) {
    // Clamp frame index to valid range
    final validFrameIndex = radarFrames.isEmpty
        ? 0
        : (_selectedFrameIndex ?? latestObservedRadarFrameIndex(radarFrames))
            .clamp(0, radarFrames.length - 1);

    final currentFrame =
        radarFrames.isEmpty ? null : radarFrames[validFrameIndex];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _controlBarWideWidth;
        // The HUD only floats when there is room beside it for the map to
        // still read as a map; on a phone it sits under the radar instead.
        final floatingHud =
            constraints.maxWidth >= SkotiqTokens.breakpointTablet &&
                constraints.maxHeight >= 420;

        final map = WeatherRadarMap(
          key: WeatherTutorialKeys.radarMap,
          currentFrame: currentFrame,
          latitude: latitude,
          longitude: longitude,
          alertRadiusKm: alertRadiusKm ?? 0,
          radarOpacity: _radarOpacity,
          contrastLevel: _radarContrast,
          motionDirection: motion?.directionDegrees,
          sourceName: radarSource.providerName,
          fetchedAt: radarSource.fetchedAt,
        );

        final conditions = _WeatherConditions(
          key: WeatherTutorialKeys.statusCard,
          radarAvailable: true,
          alert: alert,
          motion: motion,
          lastUpdate: weatherStatus.lastUpdate,
          cloudCoverPercent: cloudCoverPercent,
          alertRadiusKm: alertRadiusKm,
          expanded: _statusCardExpanded,
          onExpandToggle: () =>
              setState(() => _statusCardExpanded = !_statusCardExpanded),
        );

        final controlBar = _RadarControlBar(
          wide: wide,
          frames: radarFrames,
          currentIndex: validFrameIndex,
          onFrameChanged: (index) =>
              setState(() => _selectedFrameIndex = index),
          isPlaying: _isPlaying,
          onPlayPauseToggle: () => setState(() => _isPlaying = !_isPlaying),
          playbackSpeed: _playbackSpeed,
          onSpeedChanged: (speed) => setState(() => _playbackSpeed = speed),
          opacity: _radarOpacity,
          contrast: _radarContrast,
          onOpacityChanged: (value) => setState(() => _radarOpacity = value),
          onContrastChanged: (value) => setState(() => _radarContrast = value),
          displayControlsOpen: _displayControlsOpen,
          onDisplayControlsToggle: () =>
              setState(() => _displayControlsOpen = !_displayControlsOpen),
        );

        if (!floatingHud) {
          // Narrow: a 300 px HUD floating over a 376 px map is not a map, so
          // the map keeps the top half of the body and the same conditions
          // block becomes a scrolling panel beneath it. Same widgets, no
          // second style.
          final mapHeight =
              (constraints.maxHeight * _narrowMapFraction).clamp(200.0, 420.0);
          return Column(
            children: [
              SizedBox(
                height: mapHeight,
                child: Stack(
                  children: [
                    Positioned.fill(child: map),
                    Positioned(
                      left: SkotiqTokens.spaceMd,
                      right: SkotiqTokens.spaceMd,
                      bottom: SkotiqTokens.spaceMd,
                      child: Glass(child: controlBar),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                  child: SkotiqPanel(
                    head: const PanelHead(
                      icon: SkotiqIcons.weather,
                      label: 'Conditions',
                    ),
                    child: conditions,
                  ),
                ),
              ),
            ],
          );
        }

        return Stack(
          children: [
            Positioned.fill(child: map),
            Positioned(
              top: SkotiqTokens.spaceLg,
              right: SkotiqTokens.space2xl,
              child: SizedBox(
                width: _conditionsHudWidth,
                child: Glass(child: conditions),
              ),
            ),
            Positioned(
              left: SkotiqTokens.space2xl,
              // Clears the map's own zoom group in the bottom-right corner.
              right: SkotiqTokens.space2xl +
                  WeatherRadarMapMetrics.zoomGroupWidth +
                  SkotiqTokens.spaceMd,
              bottom: SkotiqTokens.spaceLg,
              child: Glass(child: controlBar),
            ),
          ],
        );
      },
    );
  }
}

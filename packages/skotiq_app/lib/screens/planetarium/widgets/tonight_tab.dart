import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../services/observing_site.dart';
import '../../../utils/plan_tonight_sequencer_helper.dart';
import '../planetarium_screen.dart';
import 'sidebar_shared_widgets.dart';

/// Render an instant as the HH:MM face the OBSERVING SITE reads.
///
/// Every time on this tab — twilight, moonrise/set, transit, satellite passes —
/// is a fact about the place the rig sits, and the operator may be in another
/// zone entirely. These were formatted with `.toLocal()`, i.e. the controlling
/// laptop's zone, so Settings → Location → Timezone changed nothing here while
/// the dashboard's own twilight strip and the status-bar clock (which do read
/// [clockProvider]) moved: one app showing two zones, with nothing saying which
/// was which. [SystemClock.fromUtc] is `toLocal()`, so a rig on "use system
/// time" renders exactly as before.
String _siteHhmm(DateTime t, Clock clock) {
  final shown = clock.fromUtc(t.toUtc());
  return '${shown.hour.toString().padLeft(2, '0')}:'
      '${shown.minute.toString().padLeft(2, '0')}';
}

class TonightTab extends ConsumerWidget {
  final SkotiqColors colors;

  const TonightTab({super.key, required this.colors});

  Future<void> _sendToFraming(
    BuildContext context,
    WidgetRef ref,
    DeepSkyObject dso,
    String displayName,
    ObjectVisibility visibility,
  ) async {
    final target = await catalogTargetSuggestion(
      ref: ref,
      targetName: displayName,
      raHours: dso.coordinates.ra,
      decDegrees: dso.coordinates.dec,
      catalogId: dso.catalogIds.isNotEmpty ? dso.catalogIds.first : dso.name,
      objectType: dsoTypeLabel(dso.type),
      magnitude: dso.magnitude,
      sizeArcmin: dso.sizeArcMin,
      constellation: dso.constellation,
      visibility: visibility,
    );
    if (!context.mounted) return;
    ref.read(framingProvider.notifier).setTargetSuggestion(target);
    context.goNamed('framing');
  }

  Future<void> _addToSequencer(
    BuildContext context,
    WidgetRef ref,
    DeepSkyObject dso,
    String displayName,
    ObjectVisibility visibility,
  ) async {
    final target = await catalogTargetSuggestion(
      ref: ref,
      targetName: displayName,
      raHours: dso.coordinates.ra,
      decDegrees: dso.coordinates.dec,
      catalogId: dso.catalogIds.isNotEmpty ? dso.catalogIds.first : dso.name,
      objectType: dsoTypeLabel(dso.type),
      magnitude: dso.magnitude,
      sizeArcmin: dso.sizeArcMin,
      constellation: dso.constellation,
      visibility: visibility,
    );

    if (!context.mounted) return;
    final added = await addPlanTonightTargetToSequencer(
      context: context,
      ref: ref,
      target: target,
    );

    if (added && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added $displayName to sequence')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Everything on this tab except the moon's phase is a fact about a PLACE:
    // twilight, the darkness window, transit altitudes, satellite passes. With
    // no site on record these providers answer for 0°N 0°E and the whole tab
    // reads as a real plan for a night in the Gulf of Guinea. `null` here means
    // "no site", so the tab asks for one instead of inventing an observer.
    final site = ref.watch(observingSiteProvider);
    final hasSite = site != null;
    final twilight = ref.watch(siteTwilightTimesProvider);
    final moonTimes = ref.watch(siteMoonTimesProvider);
    // Phase and illumination are the same everywhere on Earth.
    final moonInfo = ref.watch(moonInfoProvider);
    final location = ref.watch(observerLocationProvider);
    // Ranking targets is a per-site computation (transit altitude, dark-window
    // overlap). Without a site it would rank ~12k DSOs for an observer at
    // 0°N 0°E and present the winners as tonight's plan.
    final bestTargets = hasSite ? ref.watch(bestTargetsProvider) : null;
    final clock = ref.watch(clockProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Location indicator
          _LocationIndicator(
            colors: colors,
            site: site,
            locationName: location.locationName,
          ),

          const SizedBox(height: 16),

          if (twilight == null) ...[
            SkotiqCard(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(SkotiqIcons.location, size: 16, color: colors.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Set an observing location to see tonight’s twilight, '
                      'darkness window, and best targets.',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (twilight != null) ...[
            // Twilight card - Evening
            InfoCard(
              title: 'Evening twilight',
              icon: SkotiqIcons.sunset,
              color: colors.warning,
              colors: colors,
              child: Column(
                children: [
                  if (twilight.sunset != null)
                    TwilightRow(
                      label: 'Sunset',
                      time: _siteHhmm(twilight.sunset!, clock),
                      colors: colors,
                    ),
                  if (twilight.civilDusk != null)
                    TwilightRow(
                      label: 'Civil dusk',
                      time: _siteHhmm(twilight.civilDusk!, clock),
                      colors: colors,
                    ),
                  if (twilight.nauticalDusk != null)
                    TwilightRow(
                      label: 'Nautical dusk',
                      time: _siteHhmm(twilight.nauticalDusk!, clock),
                      colors: colors,
                    ),
                  if (twilight.astronomicalDusk != null)
                    TwilightRow(
                      label: 'Astro dusk',
                      time: _siteHhmm(twilight.astronomicalDusk!, clock),
                      isPrimary: true,
                      colors: colors,
                    ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Darkness duration card
            if (twilight.astronomicalDusk != null &&
                twilight.astronomicalDawn != null)
              DarknessCard(
                twilight: twilight,
                colors: colors,
              ),

            const SizedBox(height: 16),

            // Morning Twilight card
            InfoCard(
              title: 'Morning twilight',
              icon: SkotiqIcons.sunrise,
              color: colors.bandDawn,
              colors: colors,
              child: Column(
                children: [
                  if (twilight.astronomicalDawn != null)
                    TwilightRow(
                      label: 'Astro dawn',
                      time: _siteHhmm(twilight.astronomicalDawn!, clock),
                      isPrimary: true,
                      colors: colors,
                    ),
                  if (twilight.nauticalDawn != null)
                    TwilightRow(
                      label: 'Nautical dawn',
                      time: _siteHhmm(twilight.nauticalDawn!, clock),
                      colors: colors,
                    ),
                  if (twilight.civilDawn != null)
                    TwilightRow(
                      label: 'Civil dawn',
                      time: _siteHhmm(twilight.civilDawn!, clock),
                      colors: colors,
                    ),
                  if (twilight.sunrise != null)
                    TwilightRow(
                      label: 'Sunrise',
                      time: _siteHhmm(twilight.sunrise!, clock),
                      colors: colors,
                    ),
                ],
              ),
            ),

            const SizedBox(height: 16),
          ],

          // Moon card
          InfoCard(
            title: 'Moon',
            icon: SkotiqIcons.moon,
            color: colors.info,
            colors: colors,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Phase',
                      style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textSecondary),
                    ),
                    Text(
                      moonInfo.phaseName,
                      style: SkotiqTypography.labelStrong
                          .copyWith(color: colors.textPrimary),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Illumination',
                      style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textSecondary),
                    ),
                    Text(
                      '${moonInfo.illumination.toStringAsFixed(0)}%',
                      style: SkotiqTypography.labelStrong.copyWith(
                          color: moonInfo.illumination < 25
                              ? colors.success
                              : moonInfo.illumination > 75
                                  ? colors.error
                                  : colors.warning),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Rise/set are site-derived; phase and illumination above are
                // not, so they survive without a location.
                if (moonTimes?.moonrise != null)
                  TwilightRow(
                    label: 'Moonrise',
                    time: _siteHhmm(moonTimes!.moonrise!, clock),
                    colors: colors,
                  ),
                if (moonTimes?.moonset != null)
                  TwilightRow(
                    label: 'Moonset',
                    time: _siteHhmm(moonTimes!.moonset!, clock),
                    colors: colors,
                  ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Best targets tonight header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Best Targets Tonight',
                style: SkotiqTypography.labelStrong
                    .copyWith(color: colors.textPrimary),
              ),
              Tooltip(
                message: kTonightRankingTooltip,
                child: Icon(
                  SkotiqIcons.help,
                  size: 14,
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Usable hours above 30\u00b0 in darkness, and when each peaks',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: 12),

          if (bestTargets == null)
            SkotiqCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(SkotiqIcons.location, size: 32, color: colors.textMuted),
                  const SizedBox(height: 8),
                  Text(
                    'Set an observing location to rank tonight’s targets',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            )
          else
            bestTargets.when(
              data: (targets) {
                // Null once more if the site was cleared between the gate above
                // and this resolution: "no site" is a different answer from
                // "nothing is up", so it keeps its own copy.
                if (targets == null) {
                  return SkotiqCard(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: Text(
                        'Set an observing location to rank tonight\u2019s targets',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                  );
                }
                if (targets.isEmpty) {
                  return SkotiqCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Icon(LucideIcons.cloudOff,
                            size: 32, color: colors.textMuted),
                        const SizedBox(height: 8),
                        Text(
                          'Nothing clears 30\u00b0 during tonight\u2019s darkness',
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize12,
                            color: colors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return Column(
                  children: targets.take(5).map((item) {
                    final dso = item.object;
                    final (displayName, catalogTag) = getDsoDisplayInfo(dso);
                    // The moment the target is highest INSIDE the darkness
                    // window \u2014 not its transit, which for anything that
                    // culminates while the sun is up names an hour nobody can
                    // use, and which was exactly what let daylight targets
                    // head this list.
                    final peakTime = item.peakTime != null
                        ? _siteHhmm(item.peakTime!, clock)
                        : '-';
                    return TargetCard(
                      name: displayName,
                      catalog: catalogTag,
                      type: dsoTypeName(dso.type),
                      metric: '${item.hoursInDarkness.toStringAsFixed(1)}h',
                      caption: peakTime,
                      colors: colors,
                      onTap: () {
                        ref
                            .read(selectedObjectProvider.notifier)
                            .selectObject(dso);
                        ref
                            .read(skyViewStateProvider.notifier)
                            .lookAt(dso.coordinates);
                      },
                      onSendToFraming: () => _sendToFraming(
                        context,
                        ref,
                        dso,
                        displayName,
                        item.visibility,
                      ),
                      onAddToSequencer: () => _addToSequencer(
                        context,
                        ref,
                        dso,
                        displayName,
                        item.visibility,
                      ),
                    );
                  }).toList(),
                );
              },
              loading: () => Container(
                padding: const EdgeInsets.all(24),
                child: const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              error: (e, _) => Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.error.withValues(alpha: 0.1),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.alertCircle,
                        size: 16, color: colors.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Error loading targets',
                        style: TextStyle(
                            fontSize: SkotiqTypography.fontSize12,
                            color: colors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 16),

          // Satellite passes section
          _SatellitePassesSection(colors: colors),
        ],
      ),
    );
  }
}

class _SatellitePassesSection extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const _SatellitePassesSection({required this.colors});

  @override
  ConsumerState<_SatellitePassesSection> createState() =>
      _SatellitePassesSectionState();
}

class _SatellitePassesSectionState
    extends ConsumerState<_SatellitePassesSection> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final showSatellites = ref.watch(showSatellitesProvider);
    final passState = ref.watch(passPredictionProvider);
    final upcomingPasses = ref.watch(upcomingPassesProvider);
    // A pass is a geometry between a satellite and a POINT ON THE GROUND: rise
    // time, peak elevation and compass bearing are all meaningless — and wrong
    // in a way the user cannot spot — for an observer the app invented.
    final hasSite = ref.watch(observingSiteProvider) != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              onTap: () => setState(() => _isExpanded = !_isExpanded),
              child: Row(
                children: [
                  Icon(
                    _isExpanded
                        ? SkotiqIcons.chevronDown
                        : SkotiqIcons.chevronRight,
                    size: 14,
                    color: widget.colors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Satellite Passes',
                    style: SkotiqTypography.labelStrong
                        .copyWith(color: widget.colors.textPrimary),
                  ),
                ],
              ),
            ),
            if (!showSatellites && hasSite)
              SkotiqButton(
                onPressed: () {
                  ref.read(showSatellitesProvider.notifier).state = true;
                  ref.read(skyRenderConfigProvider.notifier).toggleSatellites();
                  setState(() => _isExpanded = true);
                },
                label: 'Enable',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
              ),
          ],
        ),
        if (_isExpanded && !hasSite) ...[
          const SizedBox(height: 8),
          SkotiqCard(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Set an observing location to predict satellite passes.',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: widget.colors.textMuted),
            ),
          ),
        ] else if (_isExpanded && showSatellites) ...[
          const SizedBox(height: 8),
          if (passState.isComputing)
            Container(
              padding: const EdgeInsets.all(16),
              child: const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (passState.error != null)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: widget.colors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
              child: Text(
                passState.error!,
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: widget.colors.error),
              ),
            )
          else if (upcomingPasses.isEmpty)
            SkotiqCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Icon(LucideIcons.satellite,
                      size: 24, color: widget.colors.textMuted),
                  const SizedBox(height: 6),
                  Text(
                    'No upcoming passes',
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: widget.colors.textMuted),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: () {
                      ref.read(passPredictionProvider.notifier).computePasses();
                    },
                    child: Text(
                      'Compute Passes',
                      style: TextStyle(
                          fontSize: SkotiqTypography.fontSize11,
                          color: widget.colors.accent),
                    ),
                  ),
                ],
              ),
            )
          else
            ...upcomingPasses.take(10).map((pass) => _SatellitePassCard(
                  pass: pass,
                  colors: widget.colors,
                  clock: ref.watch(clockProvider),
                )),
        ] else if (_isExpanded && !showSatellites) ...[
          const SizedBox(height: 8),
          SkotiqCard(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Enable satellite tracking to see pass predictions.',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: widget.colors.textMuted),
            ),
          ),
        ],
      ],
    );
  }
}

class _SatellitePassCard extends StatelessWidget {
  final SatellitePass pass;
  final SkotiqColors colors;

  /// Required, not defaulted to [SystemClock]: a silent host-local default is
  /// how every face on this tab drifted away from the site timezone in the
  /// first place, and a compile error is the only thing that catches the next
  /// caller that forgets.
  final Clock clock;

  const _SatellitePassCard({
    required this.pass,
    required this.colors,
    required this.clock,
  });

  @override
  Widget build(BuildContext context) {
    final isIss = pass.name.contains('ISS') || pass.name.contains('ZARYA');

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(
          color: pass.isBrightPass
              ? colors.warning
                  .withValues(alpha: SkotiqTokens.opacityAccentTintHover)
              : colors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isIss)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: colors.warning
                        .withValues(alpha: SkotiqTokens.opacityStatusFill),
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                  ),
                  child: Text(
                    'ISS',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize9,
                      fontWeight: FontWeight.w700,
                      color: colors.warning,
                    ),
                  ),
                ),
              Expanded(
                child: Text(
                  isIss ? 'International Space Station' : pass.name,
                  style:
                      SkotiqTypography.h6.copyWith(color: colors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                'Max ${pass.maxElevation.toStringAsFixed(0)}\u00b0',
                style: SkotiqTypography.labelQuiet.copyWith(
                    color: pass.isBrightPass
                        ? colors.warning
                        : colors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _PassTimeLabel(
                label: 'Rise',
                time: _siteHhmm(pass.riseTime, clock),
                az: '${pass.riseAzimuth.toStringAsFixed(0)}\u00b0',
                colors: colors,
              ),
              const SizedBox(width: 8),
              Icon(SkotiqIcons.arrowRight, size: 10, color: colors.textMuted),
              const SizedBox(width: 8),
              _PassTimeLabel(
                label: 'Max',
                time: _siteHhmm(pass.maxElevationTime, clock),
                az: '${pass.maxElevationAzimuth.toStringAsFixed(0)}\u00b0',
                colors: colors,
              ),
              const SizedBox(width: 8),
              Icon(SkotiqIcons.arrowRight, size: 10, color: colors.textMuted),
              const SizedBox(width: 8),
              _PassTimeLabel(
                label: 'Set',
                time: _siteHhmm(pass.setTime, clock),
                az: '${pass.setAzimuth.toStringAsFixed(0)}\u00b0',
                colors: colors,
              ),
              const Spacer(),
              Text(
                '${pass.duration.inMinutes}m',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    color: colors.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PassTimeLabel extends StatelessWidget {
  final String label;
  final String time;
  final String az;
  final SkotiqColors colors;

  const _PassTimeLabel({
    required this.label,
    required this.time,
    required this.az,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
              fontSize: SkotiqTypography.fontSize9, color: colors.textMuted),
        ),
        Text(
          time,
          style:
              SkotiqTypography.labelQuiet.copyWith(color: colors.textPrimary),
        ),
        Text(
          az,
          style: TextStyle(
              fontSize: SkotiqTypography.fontSize9, color: colors.textMuted),
        ),
      ],
    );
  }
}

class _LocationIndicator extends StatelessWidget {
  final SkotiqColors colors;

  /// `null` when no observing site is on record.
  final LocationSettings? site;
  final String? locationName;

  const _LocationIndicator({
    required this.colors,
    required this.site,
    required this.locationName,
  });

  @override
  Widget build(BuildContext context) {
    final site = this.site;
    final isDefaultLocation = site == null;
    return Container(
      padding: EdgeInsets.all(Responsive.isPhone(context) ? 8 : 12),
      decoration: BoxDecoration(
        color: isDefaultLocation
            ? colors.warning.withValues(alpha: 0.1)
            : colors.success.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(
          color: isDefaultLocation
              ? colors.warning.withValues(alpha: 0.3)
              : colors.success.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            SkotiqIcons.location,
            size: 14,
            color: isDefaultLocation ? colors.warning : colors.success,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isDefaultLocation
                      ? 'No observing location set'
                      : locationName ?? 'Custom Location',
                  style: SkotiqTypography.labelStrongSm.copyWith(
                      color:
                          isDefaultLocation ? colors.warning : colors.success),
                ),
                // Only a site the user actually recorded gets coordinates
                // printed. Showing "0.00\u00b0N, 0.00\u00b0E" here spelled out a
                // fabricated site as though it were the configured one.
                Text(
                  site == null
                      ? 'Tonight\u2019s times need a site'
                      : '${site.latitude.abs().toStringAsFixed(2)}\u00b0${site.latitude >= 0 ? 'N' : 'S'}, ${site.longitude.abs().toStringAsFixed(2)}\u00b0${site.longitude >= 0 ? 'E' : 'W'}',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    color: isDefaultLocation
                        ? colors.warning.withValues(alpha: 0.8)
                        : colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (isDefaultLocation)
            GestureDetector(
              onTap: () {
                try {
                  context.goNamed('settings');
                } catch (e, stack) {
                  developer.log(
                    '[TonightTab] Could not open settings to fix the '
                    'default location: $e',
                    name: 'TonightTab',
                    level: 900,
                    error: e,
                    stackTrace: stack,
                  );
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.warning.withValues(alpha: 0.2),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                ),
                child: Text(
                  'Set location',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    fontWeight: FontWeight.w500,
                    color: colors.warning,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

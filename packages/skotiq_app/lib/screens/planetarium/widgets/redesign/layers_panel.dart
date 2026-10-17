import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../../settings/catalog_settings_screen.dart';
import '../../sky_imagery/planetarium_sky_imagery_providers.dart';

/// Unified layers panel — the single source of truth for sky visibility.
///
/// Every row uses one consistent switch idiom ([_LayerSwitch]) and writes
/// through
/// [skyRenderConfigProvider] / the relevant [StateProvider]. Current values are
/// read from [effectiveSkyRenderConfigProvider] and the HUD providers.
class LayersPanel extends ConsumerWidget {
  const LayersPanel({super.key, this.onClose, this.showFov, this.onToggleFov});

  /// Optional close affordance (shown as a header X on phone bottom sheets).
  final VoidCallback? onClose;

  /// FOV-indicator state + toggle (lives in screen state, not render config).
  final bool? showFov;
  final VoidCallback? onToggleFov;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final config = ref.watch(effectiveSkyRenderConfigProvider);
    final notifier = ref.read(skyRenderConfigProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(colors: colors, onClose: onClose),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              _Group(
                title: 'Stars & Deep Sky',
                colors: colors,
                children: [
                  _LayerSwitch(
                    label: 'Stars',
                    value: config.showStars,
                    onChanged: (_) => notifier.toggleStars(),
                  ),
                  // Gated on an actually-installed tileset. No official deep
                  // tileset is published, so on a stock install flipping this
                  // switch could never do anything: the sky was pixel-identical
                  // with no toast, no progress and no "not installed" state, and
                  // the switch stayed on. A control that cannot act must say so.
                  _DeepStarsSwitch(),
                  // The catalogue thins out to nothing at imaging fields, so
                  // this streams real DSS imagery behind the chart instead.
                  // Needs the internet, hence off by default and labelled with
                  // the zoom it engages at, so an offline user is not left
                  // wondering why a switch they flipped did nothing.
                  _LayerSwitch(
                    label: 'Survey imagery (DSS, below '
                        '${kPlanetariumSkyImageryMaxFovDegrees.toStringAsFixed(0)}°)',
                    value: ref.watch(planetariumSkyImageryEnabledProvider),
                    onChanged: (v) => ref
                        .read(planetariumSkyImageryEnabledProvider.notifier)
                        .state = v,
                  ),
                  _LayerSwitch(
                    label: 'Deep-sky objects',
                    value: config.showDSOs,
                    onChanged: (_) => notifier.toggleDSOs(),
                  ),
                  _LayerSwitch(
                    label: 'DSO labels',
                    value: config.showDSOLabels,
                    onChanged: (_) => notifier.toggleDsoLabels(),
                  ),
                  _LayerSwitch(
                    label: 'Constellation lines',
                    value: config.showConstellationLines,
                    onChanged: (_) => notifier.toggleConstellationLines(),
                  ),
                  _LayerSwitch(
                    label: 'Constellation labels',
                    value: config.showConstellationLabels,
                    onChanged: (_) => notifier.toggleConstellationLabels(),
                  ),
                  _LayerSwitch(
                    label: 'Constellation boundaries',
                    value: config.showConstellationBoundaries,
                    onChanged: (_) => notifier.toggleConstellationBoundaries(),
                  ),
                  _LayerSwitch(
                    label: 'Constellation art',
                    value: config.showConstellationArt,
                    onChanged: (_) => notifier.toggleConstellationArt(),
                  ),
                  _LayerSwitch(
                    label: 'Milky way',
                    value: config.showMilkyWay,
                    onChanged: (_) => notifier.toggleMilkyWay(),
                  ),
                  _LayerSwitch(
                    label: 'Variable stars',
                    value: ref.watch(showVariableStarsProvider),
                    onChanged: (v) {
                      ref.read(showVariableStarsProvider.notifier).state = v;
                      notifier.toggleVariableStars();
                    },
                  ),
                ],
              ),
              _Group(
                title: 'Grids & Lines',
                colors: colors,
                children: [
                  // 'Coordinate grid' is the master switch; the two frame
                  // switches under it only choose WHICH grid it draws. Listed as
                  // three peers (with the master last) they read as independent
                  // layers, so turning 'Equatorial grid' on while the master was
                  // off drew nothing and said nothing. Master first, dependents
                  // indented and visibly disabled until it is on.
                  _LayerSwitch(
                    label: 'Coordinate grid',
                    value: config.showCoordinateGrid,
                    onChanged: (_) => notifier.toggleGrid(),
                  ),
                  _LayerSwitch(
                    label: 'Equatorial (RA/Dec) lines',
                    value: config.showEquatorialGrid,
                    enabled: config.showCoordinateGrid,
                    indented: true,
                    onChanged: (_) => notifier.toggleEquatorialGrid(),
                  ),
                  _LayerSwitch(
                    label: 'Alt/Az lines',
                    value: config.showAltAzGrid,
                    enabled: config.showCoordinateGrid,
                    indented: true,
                    onChanged: (_) => notifier.toggleAltAzGrid(),
                  ),
                  _LayerSwitch(
                    label: 'Ecliptic',
                    value: config.showEcliptic,
                    onChanged: (_) => notifier.toggleEcliptic(),
                  ),
                  _LayerSwitch(
                    label: 'Galactic plane',
                    value: config.showGalacticPlane,
                    onChanged: (_) => notifier.toggleGalacticPlane(),
                  ),
                  _LayerSwitch(
                    label: 'Meridian',
                    value: config.showMeridian,
                    onChanged: (_) => notifier.toggleMeridian(),
                  ),
                  _LayerSwitch(
                    label: 'Cardinal directions',
                    value: config.showCardinalDirections,
                    onChanged: (_) => notifier.toggleCardinalDirections(),
                  ),
                ],
              ),
              _Group(
                title: 'Solar system',
                colors: colors,
                children: [
                  _LayerSwitch(
                    label: 'Sun',
                    value: config.showSun,
                    onChanged: (_) => notifier.toggleSun(),
                  ),
                  _LayerSwitch(
                    label: 'Moon',
                    value: config.showMoon,
                    onChanged: (_) => notifier.toggleMoon(),
                  ),
                  _LayerSwitch(
                    label: 'Planets',
                    value: config.showPlanets,
                    onChanged: (_) => notifier.togglePlanets(),
                  ),
                  _LayerSwitch(
                    label: 'Satellites',
                    value: ref.watch(showSatellitesProvider),
                    onChanged: (v) {
                      ref.read(showSatellitesProvider.notifier).state = v;
                      notifier.toggleSatellites();
                    },
                  ),
                  _LayerSwitch(
                    label: 'Minor planets / comets',
                    value: ref.watch(showMinorPlanetsProvider),
                    onChanged: (v) {
                      ref.read(showMinorPlanetsProvider.notifier).state = v;
                      notifier.toggleMinorPlanets();
                    },
                  ),
                ],
              ),
              _Group(
                title: 'Ground & Site',
                colors: colors,
                children: [
                  _LayerSwitch(
                    label: 'Horizon',
                    value: config.showHorizon,
                    onChanged: (_) => notifier.toggleHorizon(),
                  ),
                  _LayerSwitch(
                    // The ground is occluding terrain, which only the horizon
                    // view has — the equatorial star atlas draws none, so
                    // leaving this unqualified made it look broken there.
                    label: 'Ground plane (horizon view)',
                    value: ref.watch(showGroundPlaneProvider),
                    onChanged: (v) =>
                        ref.read(showGroundPlaneProvider.notifier).state = v,
                  ),
                ],
              ),
              _Group(
                title: 'Planning',
                colors: colors,
                children: [
                  _LayerSwitch(
                    label: 'Planning overlays',
                    value: config.showPlanningOverlays,
                    onChanged: (_) => notifier.togglePlanningOverlays(),
                  ),
                  if (showFov != null && onToggleFov != null)
                    _LayerSwitch(
                      label: 'FOV indicator',
                      value: showFov!,
                      onChanged: (_) => onToggleFov!(),
                    ),
                  _LayerSwitch(
                    label: 'FOV rings (Telrad / finder)',
                    value: ref.watch(showFovRingsProvider),
                    onChanged: (v) =>
                        ref.read(showFovRingsProvider.notifier).state = v,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.colors, this.onClose});

  final SkotiqColors colors;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.border.withValues(alpha: 0.6)),
        ),
      ),
      child: Row(
        children: [
          Icon(SkotiqIcons.list, size: 16, color: colors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Layers',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize14,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          if (onClose != null)
            IconButton(
              icon: Icon(SkotiqIcons.close,
                  size: 18, color: colors.textSecondary),
              onPressed: onClose,
              tooltip: 'Close',
            ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.children,
    required this.colors,
  });

  final String title;
  final List<Widget> children;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: colors.textMuted,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

/// One consistent switch row idiom for every layer toggle.
class _LayerSwitch extends StatelessWidget {
  const _LayerSwitch({
    required this.label,
    required this.value,
    this.onChanged,
    this.enabled = true,
    this.indented = false,
    this.trailing,
    this.subtitle,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// False for a row whose effect is currently impossible (a missing catalog, a
  /// master switch that is off). Renders inert and greyed rather than accepting
  /// a flip that silently does nothing.
  final bool enabled;

  /// Indents the row to show it modifies the switch above it.
  final bool indented;

  /// Optional affordance shown instead of the switch (e.g. an install action).
  final Widget? trailing;

  /// Optional second line explaining an inert row.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isEnabled = enabled && onChanged != null;
    final labelColor = !isEnabled
        ? colors.textMuted
        : (value ? colors.textPrimary : colors.textSecondary);
    // One node per row, the way SettingRow does it. Unmerged, the label and the
    // switch were separate nodes: a screen reader was handed twelve inert
    // "panel: Ecliptic [DISABLED]" entries with no on/off state, sitting beside
    // two rows that happened to report properly — fourteen sky layers, two of
    // them operable.
    return MergeSemantics(
      child: InkWell(
        onTap: isEnabled ? () => onChanged!(!value) : null,
        child: Padding(
          padding: EdgeInsets.only(
            left: indented ? 32 : 16,
            right: 16,
            top: 4,
            bottom: 4,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize13,
                        color: labelColor,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize11,
                          color: colors.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null)
                trailing!
              else
                Switch(
                  value: isEnabled && value,
                  onChanged: isEnabled ? onChanged : null,
                  activeThumbColor: colors.accent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The deep-star tier row.
///
/// Reads [deepStarManifestProvider] so the row reflects whether a tileset is
/// actually installed. No tileset is published by default (the shipped
/// `deep_stars/config.json` points at a dev localhost host), so without this
/// gate the switch was a live-looking control that could never draw a star.
class _DeepStarsSwitch extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manifest = ref.watch(deepStarManifestProvider);
    const label = 'Deep stars (Tycho-2 / Gaia tier)';

    if (manifest.isLoading) {
      return const _LayerSwitch(
        label: label,
        value: false,
        enabled: false,
        subtitle: 'Checking for an installed tileset...',
      );
    }

    if (manifest.valueOrNull == null) {
      return _LayerSwitch(
        label: label,
        value: false,
        enabled: false,
        // "Install" promised a download that does not exist: no deep-star
        // tileset is published, and the button only opens a form asking the
        // user to host one themselves. Name the control after what it does.
        subtitle: 'No tileset available yet - stars below mag '
            '${kHygFaintFloorMag.toStringAsFixed(1)} need a self-hosted tileset',
        trailing: SkotiqButton(
          label: 'Configure source...',
          variant: ButtonVariant.outline,
          size: ButtonSize.small,
          onPressed: () => _openCatalogSettings(context, ref),
        ),
      );
    }

    return _LayerSwitch(
      label: label,
      value: ref.watch(showDeepStarsProvider),
      subtitle: 'Engages below '
          '${kDeepStarFovThresholdDegrees.toStringAsFixed(0)}\u00b0 field',
      onChanged: (v) => ref.read(showDeepStarsProvider.notifier).state = v,
    );
  }

  void _openCatalogSettings(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            context,
            designMaxWidth: 800,
            designMaxHeight: 700,
          ),
          child: const CatalogSettingsScreen(),
        ),
      ),
    ).then((_) => ref.read(deepStarManifestRefreshProvider.notifier).state++);
  }
}

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_core/skotiq_core.dart' show chooseExportTarget;
import '../../../services/finder_chart_service.dart';
import '../../../utils/exported_file_reveal.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../utils/coordinate_format_utils.dart';
import '../../../widgets/tutorial_keys/planetarium_keys.dart';
import '../providers/finder_chart_catalog_provider.dart';

/// Floating zoom/overlay control cluster drawn over the planetarium sky canvas.
///
/// Its translucent-black panel and white text/dividers are a deliberate fixed
/// HUD palette (canvas-absolute, not theme-relative): the whole planetarium is
/// wrapped in `_NightVisionFilter`, which applies the luminance→red conversion
/// for night-vision mode. Mapping these to semantic theme colors would both
/// double-up with that filter and break the over-sky contrast, so the
/// shared [ImageOverlayColors] keep this contrast independent of page surfaces.
class ViewControls extends ConsumerWidget {
  final SkotiqColors colors;
  final bool showFOV;
  final VoidCallback onToggleFOV;

  const ViewControls({
    super.key,
    required this.colors,
    required this.showFOV,
    required this.onToggleFOV,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewState = ref.watch(skyViewStateProvider);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ImageOverlayColors.shadow.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ViewControlButton(
            icon: SkotiqIcons.add,
            onTap: ref.read(skyViewStateProvider.notifier).zoomIn,
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: Text(
              CoordinateFormatUtils.formatFOVCompact(viewState.fieldOfView),
              style: const TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                color: ImageOverlayColors.secondary,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 4),
          ViewControlButton(
            icon: SkotiqIcons.remove,
            onTap: ref.read(skyViewStateProvider.notifier).zoomOut,
          ),
          const Divider(height: 16, color: ImageOverlayColors.divider),
          ViewControlButton(
            icon: SkotiqIcons.home,
            onTap: () {
              // Home = the observer's zenith, not the fixed point RA 0h/Dec 0
              // (which is usually below the horizon). See
              // [skyViewHomeCenterProvider].
              // Null with no site on record: the zenith is the point over the
              // observer, so the equatorial centre is left where it is.
              final home = ref.read(skyViewHomeCenterProvider);
              if (home != null) {
                ref
                    .read(skyViewStateProvider.notifier)
                    .setCenter(home.$1, home.$2);
              }
              ref
                  .read(skyViewStateProvider.notifier)
                  .setHorizontalCenter(0, 90);
              ref.read(skyViewStateProvider.notifier).setFieldOfView(60);
            },
          ),
          const SizedBox(height: 4),
          ViewControlButton(
            key: PlanetariumTutorialKeys.fovToggle,
            icon: SkotiqIcons.frame,
            isActive: showFOV,
            onTap: onToggleFOV,
            tooltip: 'Toggle FOV indicator',
          ),
          const SizedBox(height: 4),
          // FOV reference rings (Telrad + finder) toggle
          Consumer(
            builder: (context, ref, _) {
              return ViewControlButton(
                icon: SkotiqIcons.target,
                isActive: ref.watch(showFovRingsProvider),
                onTap: () {
                  final notifier = ref.read(showFovRingsProvider.notifier);
                  notifier.state = !notifier.state;
                },
                tooltip: 'Toggle FOV rings (Telrad / finder)',
              );
            },
          ),
          const SizedBox(height: 4),
          // Angular-measurement tool toggle (separation + position angle).
          Consumer(
            builder: (context, ref, _) {
              return ViewControlButton(
                icon: SkotiqIcons.ruler,
                isActive: ref.watch(measurementModeProvider),
                onTap: () {
                  final notifier = ref.read(measurementModeProvider.notifier);
                  notifier.state = !notifier.state;
                },
                tooltip: 'Measure angular separation + position angle',
              );
            },
          ),
          const SizedBox(height: 4),
          // Night-vision (red) mode toggle
          Consumer(
            builder: (context, ref, _) {
              return ViewControlButton(
                icon: SkotiqIcons.moon,
                isActive: ref.watch(nightVisionModeProvider),
                onTap: () {
                  final notifier = ref.read(nightVisionModeProvider.notifier);
                  notifier.state = !notifier.state;
                },
                tooltip: 'Toggle night-vision (red) mode',
              );
            },
          ),
          const SizedBox(height: 4),
          // Performance HUD toggle (UI-thread ms / GPU-raster ms / FPS).
          Consumer(
            builder: (context, ref, _) {
              return ViewControlButton(
                icon: SkotiqIcons.activity,
                isActive: ref.watch(showPerfHudProvider),
                onTap: () {
                  final notifier = ref.read(showPerfHudProvider.notifier);
                  notifier.state = !notifier.state;
                },
                tooltip: 'Toggle performance HUD',
              );
            },
          ),
          const SizedBox(height: 4),
          // Planning overlays toggle: altitude track + meridian-flip marker for
          // the selected target, plus the twilight (dusk/dawn) indicator.
          Consumer(
            builder: (context, ref, _) {
              final config = ref.watch(skyRenderConfigProvider);
              return ViewControlButton(
                icon: SkotiqIcons.chart,
                isActive: config.showPlanningOverlays,
                onTap: () {
                  ref
                      .read(skyRenderConfigProvider.notifier)
                      .togglePlanningOverlays();
                },
                tooltip: 'Toggle planning overlays (altitude track, '
                    'meridian flip, twilight)',
              );
            },
          ),
          const Divider(height: 16, color: ImageOverlayColors.divider),
          // Compass HUD toggle - wrapped in Consumer to scope rebuilds
          Consumer(
            builder: (context, ref, _) {
              return ViewControlButton(
                icon: SkotiqIcons.compass,
                isActive: ref.watch(showCompassHudProvider),
                onTap: () {
                  final notifier = ref.read(showCompassHudProvider.notifier);
                  notifier.state = !notifier.state;
                },
                tooltip: 'Toggle Compass',
              );
            },
          ),
          const SizedBox(height: 4),
          // Mini-map toggle - wrapped in Consumer to scope rebuilds
          Consumer(
            builder: (context, ref, _) {
              return ViewControlButton(
                icon: SkotiqIcons.map,
                isActive: ref.watch(showMinimapProvider),
                onTap: () {
                  final notifier = ref.read(showMinimapProvider.notifier);
                  notifier.state = !notifier.state;
                },
                tooltip: 'Toggle Mini-map',
              );
            },
          ),
          const SizedBox(height: 4),
          // Satellite toggle - wrapped in Consumer to scope rebuilds
          Consumer(
            builder: (context, ref, _) {
              return ViewControlButton(
                icon: LucideIcons.satellite,
                isActive: ref.watch(showSatellitesProvider),
                onTap: () {
                  final notifier = ref.read(showSatellitesProvider.notifier);
                  notifier.state = !notifier.state;
                  // Also toggle in render config
                  ref.read(skyRenderConfigProvider.notifier).toggleSatellites();
                },
                tooltip: 'Toggle Satellites',
              );
            },
          ),
          const SizedBox(height: 4),
          // Variable stars toggle
          Consumer(
            builder: (context, ref, _) {
              return ViewControlButton(
                icon: SkotiqIcons.sparkle,
                isActive: ref.watch(showVariableStarsProvider),
                onTap: () {
                  final notifier = ref.read(showVariableStarsProvider.notifier);
                  notifier.state = !notifier.state;
                  ref
                      .read(skyRenderConfigProvider.notifier)
                      .toggleVariableStars();
                },
                tooltip: 'Toggle Variable Stars',
              );
            },
          ),
          const SizedBox(height: 4),
          // Minor planets (asteroids/comets) toggle
          Consumer(
            builder: (context, ref, _) {
              return ViewControlButton(
                icon: LucideIcons.diamond,
                isActive: ref.watch(showMinorPlanetsProvider),
                onTap: () {
                  final notifier = ref.read(showMinorPlanetsProvider.notifier);
                  notifier.state = !notifier.state;
                  ref
                      .read(skyRenderConfigProvider.notifier)
                      .toggleMinorPlanets();
                },
                tooltip: 'Toggle Asteroids & Comets',
              );
            },
          ),
          const SizedBox(height: 4),
          QualitySettingsButton(colors: colors),
          const Divider(height: 16, color: ImageOverlayColors.divider),
          // Alt/Az ("tonight from my site") view-mode toggle. Reframes the sky
          // horizon-up / zenith-centered as the observer sees it; tap again to
          // return to the equatorial (star-atlas) frame.
          ViewControlButton(
            icon: SkotiqIcons.layers,
            isActive: viewState.viewMode == SkyViewMode.horizontal,
            onTap: () {
              final notifier = ref.read(skyViewStateProvider.notifier);
              notifier.setViewMode(
                viewState.viewMode == SkyViewMode.horizontal
                    ? SkyViewMode.equatorial
                    : SkyViewMode.horizontal,
                observer: ref.read(observerLocationProvider),
                instant: ref.read(observationTimeProvider).time,
              );
            },
            tooltip: viewState.viewMode == SkyViewMode.horizontal
                ? 'Alt/Az view (horizon-up) — switch to equatorial'
                : 'Switch to Alt/Az view (tonight from my site)',
          ),
          const SizedBox(height: 4),
          ProjectionSelectorButton(colors: colors),
          const Divider(height: 16, color: ImageOverlayColors.divider),
          ExportChartButton(colors: colors),
        ],
      ),
    );
  }
}

/// Export finder chart as PDF
class ExportChartButton extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const ExportChartButton({super.key, required this.colors});

  @override
  ConsumerState<ExportChartButton> createState() => _ExportChartButtonState();
}

class _ExportChartButtonState extends ConsumerState<ExportChartButton> {
  bool _isExporting = false;

  Future<void> _exportChart({required bool printMode}) async {
    if (_isExporting) return;
    setState(() => _isExporting = true);

    try {
      final viewState = ref.read(skyViewStateProvider);
      final renderConfig = ref.read(skyRenderConfigProvider);
      // A finder chart states a horizon, so it needs a real observer rather
      // than a default one.
      final site = ref.read(observerLocationProvider).site;
      if (site == null) {
        if (mounted) {
          context.showWarningSnackBar(
            'Set your observing location in Settings to export a finder chart.',
          );
        }
        return;
      }
      final time = ref.read(observationTimeProvider);
      final constellations = ref.read(constellationDataProvider);
      final selectedState = ref.read(selectedObjectProvider);
      final sunPos = ref.read(sunPositionProvider);
      final moonPos = ref.read(moonPositionProvider);
      final moonInfo = ref.read(moonInfoProvider);
      final planets = ref.read(planetPositionsProvider);
      final milkyWayPoints = ref.read(milkyWayPointsProvider);

      // Determine object name from selection
      String? objectName;
      String? objectType;
      double? objectMagnitude;
      String? objectSize;
      if (selectedState.object != null) {
        final obj = selectedState.object!;
        if (obj is DeepSkyObject) {
          final (displayName, _) = _getDsoDisplayInfo(obj);
          objectName = displayName;
          objectType = obj.type.displayName;
          objectMagnitude = obj.magnitude;
          objectSize = obj.sizeString;
        } else {
          objectName = obj.name;
          objectMagnitude = obj.magnitude;
          if (obj is Star) {
            objectType = obj.spectralType != null
                ? 'Star (${obj.spectralType})'
                : 'Star';
          }
        }
      }

      // See [finderChartPose]: the chart is centred on the object it is titled
      // for, and always rendered in the equatorial frame.
      final (region: chartRegion, pose: chartPose) = finderChartPose(
        viewState: viewState,
        viewCenter: ref.read(viewCenterEquatorialProvider),
        subject: selectedState.coordinates,
      );
      final catalog = await ref.read(
        finderChartCatalogSnapshotProvider(chartRegion).future,
      );
      if (!mounted) return;
      final stars = catalog.stars;
      final dsos = catalog.dsos;

      final suggestedName = FinderChartService.suggestedFilename(
        objectName: objectName,
      );

      // Android/iOS have no save dialog — `getSavePath` throws
      // UnimplementedError there — so the chart goes to a sandbox path and
      // reaches the user through the share sheet below.
      final target = await chooseExportTarget(
        suggestedName: suggestedName,
        acceptedTypeGroups: [
          const XTypeGroup(label: 'PDF files', extensions: ['pdf']),
        ],
      );

      if (target == null) return;

      await FinderChartService.generateChart(
        outputPath: target.path,
        viewState: chartPose,
        renderConfig: renderConfig,
        stars: stars,
        dsos: dsos,
        constellations: constellations,
        observationTime: time.time,
        latitude: site.latitude,
        longitude: site.longitude,
        chartConfig: FinderChartConfig(
          printMode: printMode,
          chartResolution: 2048,
          objectName: objectName,
          objectType: objectType,
          objectMagnitude: objectMagnitude,
          objectSize: objectSize,
          includeDetailsPage: objectName != null,
        ),
        selectedObject: selectedState.coordinates,
        sunPosition: sunPos,
        moonPosition: (moonPos.$1, moonPos.$2, moonInfo.illumination),
        planets: planets,
        milkyWayPoints: milkyWayPoints,
      );

      if (mounted) {
        await revealExportedFile(
          context,
          target.path,
          subject: 'Finder chart',
          desktopMessage: 'Finder chart saved to ${target.path}',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to export chart: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: SkotiqColors.of(context).error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isExporting) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: const Padding(
          padding: const EdgeInsets.all(6),
          child: const SkotiqSpinner(
              size: 16, color: ImageOverlayColors.secondary),
        ),
      );
    }

    return PopupMenuButton<bool>(
      icon: const Icon(
        LucideIcons.fileDown,
        size: 18,
        color: ImageOverlayColors.secondary,
      ),
      tooltip: 'Export finder chart',
      color: widget.colors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
      offset: const Offset(-160, 0),
      onSelected: (printMode) => _exportChart(printMode: printMode),
      itemBuilder: (context) => [
        PopupMenuItem<bool>(
          value: false,
          child: Row(
            children: [
              Icon(LucideIcons.fileDown,
                  size: 16, color: widget.colors.textPrimary),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Export Chart (Dark)',
                    style: TextStyle(color: widget.colors.textPrimary),
                  ),
                  Text(
                    'Dark sky background',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: widget.colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        PopupMenuItem<bool>(
          value: true,
          child: Row(
            children: [
              Icon(LucideIcons.printer,
                  size: 16, color: widget.colors.textPrimary),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Export Chart (Print)',
                    style: TextStyle(color: widget.colors.textPrimary),
                  ),
                  Text(
                    'White background, black stars',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: widget.colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// DSO display name helper (same logic as planetarium_screen.dart)
  static (String, String) _getDsoDisplayInfo(DeepSkyObject dso) {
    if (dso.isMessier) {
      final messierNum = dso.messierNumber;
      if (messierNum != null) return (messierNum, 'M');
    }
    final ngcIc = dso.ngcIcDesignation;
    if (ngcIc != null) {
      if (ngcIc.startsWith('NGC')) return (ngcIc, 'NGC');
      if (ngcIc.startsWith('IC')) return (ngcIc, 'IC');
    }
    if (dso.id.startsWith('NGC')) return (dso.id, 'NGC');
    if (dso.id.startsWith('IC')) return (dso.id, 'IC');
    if (dso.id.startsWith('M')) return (dso.id, 'M');
    return (dso.name, dso.id);
  }
}

/// Quality settings popup button
class QualitySettingsButton extends ConsumerWidget {
  final SkotiqColors colors;

  const QualitySettingsButton({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quality = ref.watch(renderQualityProvider);

    return _namedCommandBarPopup(
      name: 'Render quality',
      child: PopupMenuButton<RenderQuality>(
        icon: const Icon(
          SkotiqIcons.settings2,
          size: 18,
          color: ImageOverlayColors.secondary,
        ),
        // Empty, deliberately: see [_namedCommandBarPopup].
        tooltip: '',
        color: colors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
        offset: const Offset(-120, 0),
        onSelected: (tier) {
          ref.read(renderQualityProvider.notifier).setQuality(tier);
        },
        itemBuilder: (context) => [
          _buildQualityMenuItem(
            context,
            RenderQuality.minimal,
            'Minimal',
            'Raspberry Pi / low-power',
            quality.quality,
          ),
          _buildQualityMenuItem(
            context,
            RenderQuality.performance,
            'Performance',
            'Low-end devices',
            quality.quality,
          ),
          _buildQualityMenuItem(
            context,
            RenderQuality.balanced,
            'Balanced',
            'Recommended',
            quality.quality,
          ),
          _buildQualityMenuItem(
            context,
            RenderQuality.quality,
            'Quality',
            'Best visuals',
            quality.quality,
          ),
        ],
      ),
    );
  }

  PopupMenuItem<RenderQuality> _buildQualityMenuItem(
    BuildContext context,
    RenderQuality tier,
    String title,
    String subtitle,
    RenderQuality current,
  ) {
    final isSelected = tier == current;
    return PopupMenuItem<RenderQuality>(
      value: tier,
      child: Row(
        children: [
          Icon(
            isSelected ? SkotiqIcons.success : SkotiqIcons.circle,
            size: 16,
            color: isSelected ? colors.accent : colors.textSecondary,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Wrap a command-bar [PopupMenuButton] so it has a NAME and its message is
/// carried by the trigger.
///
/// Two things are wrong with a bare `PopupMenuButton(tooltip: 'X')` here:
///
///  * The icon carries no label, so the control dumps as a bare `button: ` —
///    unidentifiable to anyone driving the bar from the keyboard or a screen
///    reader.
///  * Material's `Tooltip` publishes its message as a semantics node of its
///    own, which survives the pointer and strands a stale `panel: …` in the
///    tree for the rest of the session after one hover. Passing an EMPTY
///    tooltip makes `Tooltip` return its child untouched, so no such node is
///    ever created; the hover message comes from [SkotiqTooltip], which
///    retires with the pointer.
Widget _namedCommandBarPopup({required String name, required Widget child}) {
  // The NAME itself goes on the icon (`Icon(semanticLabel:)`), because
  // `PopupMenuButton` builds an `IconButton` whose semantics node is a
  // container of its own: a parent `Semantics(label: …)` — even merged —
  // lands beside that node and leaves the button announcing `button: ` with
  // nothing after it. The icon's label is the one string that ends up ON the
  // button node, with its role and its tap action.
  return SkotiqTooltip(
    message: name,
    position: SkotiqTooltipPosition.bottom,
    child: child,
  );
}

/// Projection selector popup button
class ProjectionSelectorButton extends ConsumerWidget {
  final SkotiqColors colors;

  const ProjectionSelectorButton({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewState = ref.watch(skyViewStateProvider);
    final currentProjection = viewState.projection;

    final name = 'Projection: ${_projectionName(currentProjection)}';
    return _namedCommandBarPopup(
      name: name,
      child: PopupMenuButton<SkyProjection>(
        icon: Icon(
          _projectionIcon(currentProjection),
          size: 18,
          color: ImageOverlayColors.secondary,
          semanticLabel: name,
        ),
        // Empty, deliberately: see [_namedCommandBarPopup].
        tooltip: '',
        color: colors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
        offset: const Offset(-140, 0),
        onSelected: (projection) {
          ref.read(skyViewStateProvider.notifier).setProjection(projection);
        },
        itemBuilder: (context) => SkyProjection.values.map((projection) {
          final isSelected = projection == currentProjection;
          return PopupMenuItem<SkyProjection>(
            value: projection,
            child: Row(
              children: [
                Icon(
                  isSelected ? SkotiqIcons.success : SkotiqIcons.circle,
                  size: 16,
                  color: isSelected ? colors.accent : colors.textSecondary,
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _projectionName(projection),
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    Text(
                      _projectionDescription(projection),
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  static String _projectionName(SkyProjection projection) {
    switch (projection) {
      case SkyProjection.stereographic:
        return 'Stereographic';
      case SkyProjection.orthographic:
        return 'Orthographic';
      case SkyProjection.azimuthalEquidistant:
        return 'Equidistant';
    }
  }

  static String _projectionDescription(SkyProjection projection) {
    switch (projection) {
      case SkyProjection.stereographic:
        return 'Conformal, preserves angles';
      case SkyProjection.orthographic:
        return 'Perspective from infinity';
      case SkyProjection.azimuthalEquidistant:
        return 'Preserves distances from center';
    }
  }

  static IconData _projectionIcon(SkyProjection projection) {
    switch (projection) {
      case SkyProjection.stereographic:
        return SkotiqIcons.globe;
      case SkyProjection.orthographic:
        return SkotiqIcons.circle;
      case SkyProjection.azimuthalEquidistant:
        return SkotiqIcons.target;
    }
  }
}

class ViewControlButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;
  final String? tooltip;

  const ViewControlButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.isActive = false,
    this.tooltip,
  });

  @override
  State<ViewControlButton> createState() => _ViewControlButtonState();
}

class _ViewControlButtonState extends State<ViewControlButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final button = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: widget.isActive
                ? colors.primary
                    .withValues(alpha: SkotiqTokens.opacityAccentTintHover)
                : (_isHovered
                    ? ImageOverlayColors.foreground.withValues(alpha: 0.1)
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            border: widget.isActive
                ? Border.all(color: colors.primary, width: 1)
                : null,
          ),
          child: Icon(
            widget.icon,
            size: 14,
            color:
                widget.isActive ? colors.primary : ImageOverlayColors.secondary,
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(
        message: widget.tooltip!,
        child: button,
      );
    }
    return button;
  }
}

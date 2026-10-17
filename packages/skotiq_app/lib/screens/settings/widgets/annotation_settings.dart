import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'settings_widgets.dart';

class AnnotationSettingsPage extends ConsumerWidget {
  final bool isMobile;

  const AnnotationSettingsPage({super.key, this.isMobile = false});

  SettingsPage _authorityState({
    required BuildContext context,
    required String authority,
    required VoidCallback onRetry,
    Object? error,
  }) {
    return SettingsPage(
      title: 'Annotations',
      description: 'Configure object annotations on captured images',
      isMobile: isMobile,
      hideHeader: isMobile,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            children: [
              if (error == null)
                const CircularProgressIndicator()
              else
                Icon(
                  LucideIcons.alertTriangle,
                  color: SkotiqColors.of(context).error,
                ),
              const SizedBox(height: 12),
              Text(
                error == null
                    ? 'Loading $authority…'
                    : 'Could not load $authority',
                textAlign: TextAlign.center,
              ),
              if (error != null) ...[
                const SizedBox(height: 6),
                Text(
                  error.toString(),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                SkotiqButton(
                  label: 'Retry annotation settings',
                  icon: LucideIcons.refreshCw,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: onRetry,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _resetAuthority(
    BuildContext context, {
    required String label,
    required Future<void> Function() reset,
  }) async {
    try {
      await reset();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label reset to defaults')),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not reset $label: $error'),
            backgroundColor: SkotiqColors.of(context).error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(annotationSettingsProvider);
    final markerStyleAsync = ref.watch(annotationMarkerStyleProvider);

    if (settingsAsync.hasError) {
      return _authorityState(
        context: context,
        authority: 'annotation display settings',
        error: settingsAsync.error,
        onRetry: () => ref.invalidate(annotationSettingsProvider),
      );
    }
    if (!settingsAsync.hasValue) {
      return _authorityState(
        context: context,
        authority: 'annotation display settings',
        onRetry: () => ref.invalidate(annotationSettingsProvider),
      );
    }
    if (markerStyleAsync.hasError) {
      return _authorityState(
        context: context,
        authority: 'annotation marker styles',
        error: markerStyleAsync.error,
        onRetry: () => ref.invalidate(annotationMarkerStyleProvider),
      );
    }
    if (!markerStyleAsync.hasValue) {
      return _authorityState(
        context: context,
        authority: 'annotation marker styles',
        onRetry: () => ref.invalidate(annotationMarkerStyleProvider),
      );
    }

    final settingsNotifier = ref.read(annotationSettingsProvider.notifier);
    final markerNotifier = ref.read(annotationMarkerStyleProvider.notifier);

    final settings = settingsAsync.requireValue;
    final markerStyle = markerStyleAsync.requireValue;

    return SettingsPage(
      title: 'Annotations',
      description: 'Configure object annotations on captured images',
      isMobile: isMobile,
      hideHeader: isMobile,
      children: [
        // Display Settings
        SettingsSection(
          title: 'Display',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.eye,
              title: 'Enable annotations',
              subtitle: 'Show object annotations on images',
              trailing: SettingsSwitch(
                value: settings.enabled,
                onChanged: (value) => settingsNotifier.setEnabled(value),
              ),
              isMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.tag,
              title: 'Show labels',
              subtitle: 'Display object names next to markers',
              trailing: SettingsSwitch(
                value: settings.showLabels,
                onChanged: (value) => settingsNotifier.setShowLabels(value),
              ),
              isMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.hash,
              title: 'Show magnitudes',
              subtitle: 'Display magnitude values with labels',
              trailing: SettingsSwitch(
                value: settings.showMagnitudes,
                onChanged: (value) => settingsNotifier.setShowMagnitudes(value),
              ),
              isMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.listTree,
              title: 'Max objects to display',
              subtitle: 'Limit number of annotations for performance',
              trailing: SettingsCompactSlider(
                value: settings.maxObjectsToDisplay.toDouble(),
                min: 50,
                max: 2000,
                divisions: 39,
                label: settings.maxObjectsToDisplay.toString(),
                onChanged: (value) =>
                    settingsNotifier.setMaxObjectsToDisplay(value.toInt()),
                isMobile: isMobile,
              ),
              isMobile: isMobile,
              stackOnMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.grid,
              title: 'Grid overlay',
              subtitle: 'Grid type: pixel, celestial RA/Dec, or off',
              trailing: SettingsDropdown(
                value: switch (settings.gridType) {
                  GridType.none => 'Off',
                  GridType.pixel => 'Pixel',
                  GridType.celestial => 'RA/Dec',
                },
                items: const ['Off', 'Pixel', 'RA/Dec'],
                onChanged: (value) {
                  final type = switch (value) {
                    'Pixel' => GridType.pixel,
                    'RA/Dec' => GridType.celestial,
                    _ => GridType.none,
                  };
                  return settingsNotifier.setGridType(type);
                },
                isMobile: isMobile,
              ),
              isLast: true,
              isMobile: isMobile,
            ),
          ],
        ),
        SizedBox(height: isMobile ? 16 : 20),

        // Magnitude Filtering
        SettingsSection(
          title: 'Magnitude filter',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.sunDim,
              title: 'Minimum magnitude',
              subtitle: 'Brightest objects to show (lower = brighter)',
              trailing: SettingsCompactSlider(
                value: settings.minMagnitude,
                min: -5,
                max: 10,
                divisions: 30,
                label: settings.minMagnitude.toStringAsFixed(1),
                onChanged: (value) => settingsNotifier.setMinMagnitude(value),
                isMobile: isMobile,
              ),
              isMobile: isMobile,
              stackOnMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.sunMedium,
              title: 'Maximum magnitude',
              subtitle: 'Faintest objects to show (higher = fainter)',
              trailing: SettingsCompactSlider(
                value: settings.magnitudeCutoff,
                min: 8,
                max: 22,
                divisions: 28,
                label: settings.magnitudeCutoff.toStringAsFixed(1),
                onChanged: (value) =>
                    settingsNotifier.setMagnitudeCutoff(value),
                isMobile: isMobile,
              ),
              isLast: true,
              isMobile: isMobile,
              stackOnMobile: isMobile,
            ),
          ],
        ),
        SizedBox(height: isMobile ? 16 : 20),

        // Object Types
        SettingsSection(
          title: 'Object types',
          isMobile: isMobile,
          children: [
            ObjectTypeToggle(
              title: 'Galaxies',
              icon: LucideIcons.circle,
              color: Color(markerStyle.galaxyColor),
              isEnabled: settings.visibleTypes
                  .contains(AnnotationObjectFilter.galaxies),
              onChanged: (value) => settingsNotifier
                  .toggleObjectType(AnnotationObjectFilter.galaxies),
              isMobile: isMobile,
            ),
            ObjectTypeToggle(
              title: 'Nebulae',
              icon: LucideIcons.cloud,
              color: Color(markerStyle.nebulaColor),
              isEnabled: settings.visibleTypes
                  .contains(AnnotationObjectFilter.nebulae),
              onChanged: (value) => settingsNotifier
                  .toggleObjectType(AnnotationObjectFilter.nebulae),
              isMobile: isMobile,
            ),
            ObjectTypeToggle(
              title: 'Star clusters',
              icon: LucideIcons.sparkles,
              color: Color(markerStyle.clusterColor),
              isEnabled: settings.visibleTypes
                  .contains(AnnotationObjectFilter.starClusters),
              onChanged: (value) => settingsNotifier
                  .toggleObjectType(AnnotationObjectFilter.starClusters),
              isMobile: isMobile,
            ),
            ObjectTypeToggle(
              title: 'Planetary nebulae',
              icon: LucideIcons.target,
              color: Color(markerStyle.planetaryNebulaColor),
              isEnabled: settings.visibleTypes
                  .contains(AnnotationObjectFilter.planetaryNebulae),
              onChanged: (value) => settingsNotifier
                  .toggleObjectType(AnnotationObjectFilter.planetaryNebulae),
              isMobile: isMobile,
            ),
            ObjectTypeToggle(
              title: 'Stars',
              icon: LucideIcons.star,
              color: Color(markerStyle.starColor),
              isEnabled:
                  settings.visibleTypes.contains(AnnotationObjectFilter.stars),
              onChanged: (value) => settingsNotifier
                  .toggleObjectType(AnnotationObjectFilter.stars),
              isMobile: isMobile,
            ),
            ObjectTypeToggle(
              title: 'Other objects',
              icon: LucideIcons.helpCircle,
              color: Color(markerStyle.otherColor),
              isEnabled:
                  settings.visibleTypes.contains(AnnotationObjectFilter.other),
              onChanged: (value) => settingsNotifier
                  .toggleObjectType(AnnotationObjectFilter.other),
              isLast: true,
              isMobile: isMobile,
            ),
          ],
        ),
        SizedBox(height: isMobile ? 16 : 20),

        // Fade Effects
        SettingsSection(
          title: 'Fade effects',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.mousePointer,
              title: 'Fade when not hovering',
              subtitle: 'Dim annotations when mouse leaves image',
              trailing: SettingsSwitch(
                value: settings.fadeWhenNotHovering,
                onChanged: (value) =>
                    settingsNotifier.setFadeWhenNotHovering(value),
              ),
              isMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.sun,
              title: 'Hover opacity',
              subtitle: 'Brightness when mouse is over image',
              trailing: SettingsCompactSlider(
                value: settings.hoverOpacity,
                min: 0.3,
                max: 1.0,
                divisions: 14,
                label: '${(settings.hoverOpacity * 100).toInt()}%',
                onChanged: (value) => settingsNotifier.setHoverOpacity(value),
                isMobile: isMobile,
              ),
              isMobile: isMobile,
              stackOnMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.moon,
              title: 'Idle opacity',
              subtitle: 'Brightness when mouse leaves image',
              trailing: SettingsCompactSlider(
                value: settings.idleOpacity,
                min: 0.0,
                max: 0.5,
                divisions: 10,
                label: '${(settings.idleOpacity * 100).toInt()}%',
                onChanged: (value) => settingsNotifier.setIdleOpacity(value),
                isMobile: isMobile,
              ),
              isMobile: isMobile,
              stackOnMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.timer,
              title: 'Fade duration',
              subtitle: 'Animation speed in milliseconds',
              trailing: SettingsCompactSlider(
                value: settings.fadeAnimationMs.toDouble(),
                min: 100,
                max: 1000,
                divisions: 9,
                label: '${settings.fadeAnimationMs}ms',
                onChanged: (value) =>
                    settingsNotifier.setFadeAnimationMs(value.toInt()),
                isMobile: isMobile,
              ),
              isLast: true,
              isMobile: isMobile,
              stackOnMobile: isMobile,
            ),
          ],
        ),
        SizedBox(height: isMobile ? 16 : 20),

        // Click to Identify
        SettingsSection(
          title: 'Click to identify',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.mousePointerClick,
              title: 'Enable click to identify',
              subtitle: 'Click on image to identify objects',
              trailing: SettingsSwitch(
                value: settings.clickToIdentify,
                onChanged: (value) =>
                    settingsNotifier.setClickToIdentify(value),
              ),
              isMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.crosshair,
              title: 'Search radius',
              subtitle: 'Distance to search for objects (arcseconds)',
              trailing: SettingsCompactSlider(
                value: settings.clickSearchRadiusArcsec,
                min: 5,
                max: 120,
                divisions: 23,
                label: '${settings.clickSearchRadiusArcsec.toInt()}"',
                onChanged: (value) =>
                    settingsNotifier.setClickSearchRadius(value),
                isMobile: isMobile,
              ),
              isLast: true,
              isMobile: isMobile,
              stackOnMobile: isMobile,
            ),
          ],
        ),
        SizedBox(height: isMobile ? 16 : 20),

        // Marker Styles
        SettingsSection(
          title: 'Marker styles',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.pencil,
              title: 'Stroke width',
              subtitle: 'Thickness of marker outlines',
              trailing: SettingsCompactSlider(
                value: markerStyle.strokeWidth,
                min: 0.5,
                max: 4.0,
                divisions: 7,
                label: markerStyle.strokeWidth.toStringAsFixed(1),
                onChanged: (value) => markerNotifier.setStrokeWidth(value),
                isMobile: isMobile,
              ),
              isMobile: isMobile,
              stackOnMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.type,
              title: 'Label font size',
              subtitle: 'Size of text labels',
              trailing: SettingsCompactSlider(
                value: markerStyle.labelFontSize,
                min: 8,
                max: 18,
                divisions: 10,
                label: '${markerStyle.labelFontSize.toInt()}px',
                onChanged: (value) => markerNotifier.setLabelFontSize(value),
                isMobile: isMobile,
              ),
              isMobile: isMobile,
              stackOnMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.scaling,
              title: 'Scale by object size',
              subtitle: 'Larger objects get larger markers',
              trailing: SettingsSwitch(
                value: markerStyle.scaleBySize,
                onChanged: (value) => markerNotifier.setScaleBySize(value),
              ),
              isLast: true,
              isMobile: isMobile,
            ),
          ],
        ),
        SizedBox(height: isMobile ? 16 : 20),

        // Automation
        SettingsSection(
          title: 'Automation',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.zap,
              title: 'Auto-annotate images',
              subtitle: 'Automatically annotate plate-solved images',
              trailing: SettingsSwitch(
                value: settings.autoAnnotate,
                onChanged: (value) => settingsNotifier.setAutoAnnotate(value),
              ),
              isLast: true,
              isMobile: isMobile,
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Each persisted authority resets independently so a failed marker
        // write cannot masquerade as a successful all-settings reset.
        Center(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              SkotiqButton(
                label: 'Reset display settings',
                icon: LucideIcons.rotateCcw,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () {
                  _resetAuthority(
                    context,
                    label: 'Annotation display settings',
                    reset: settingsNotifier.reset,
                  );
                },
              ),
              SkotiqButton(
                label: 'Reset marker styles',
                icon: LucideIcons.rotateCcw,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () {
                  _resetAuthority(
                    context,
                    label: 'Annotation marker styles',
                    reset: markerNotifier.reset,
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

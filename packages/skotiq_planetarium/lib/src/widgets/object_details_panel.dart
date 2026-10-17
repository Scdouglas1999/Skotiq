import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../celestial_object.dart';
import '../astronomy/astronomy_calculations.dart';
import '../services/survey_image_service.dart';
import '../providers/planetarium_providers.dart';

part 'object_details_panel/header_sections.dart';
part 'object_details_panel/catalog_sections.dart';
part 'object_details_panel/visibility_sections.dart';
part 'object_details_panel/action_sections.dart';
part 'object_details_panel/chart_painters.dart';

/// Enhanced object details panel showing comprehensive information
class ObjectDetailsPanel extends ConsumerWidget {
  /// The celestial object to display
  final CelestialObject object;

  /// Background color
  final Color? backgroundColor;

  /// Text color
  final Color? textColor;

  /// Accent color
  final Color? accentColor;

  /// Whether to show the visibility graph
  final bool showVisibilityGraph;

  /// Callback when "Go To" is pressed
  final VoidCallback? onGoTo;

  /// Callback when "Add to Targets" is pressed
  final VoidCallback? onAddToTargets;

  /// Callback when "Frame target" is pressed. When provided, a "Frame target"
  /// action is shown so the user can open the Framing screen for this object
  /// straight from the sky. Wired by the host screen to the framing provider.
  final VoidCallback? onFrameTarget;

  /// Callback when "Add to sequence" is pressed. When provided, an
  /// "Add to sequence" action is shown so the user can drop this object into a
  /// sequence from the sky. Wired by the host screen to the add-to-sequence
  /// flow.
  final VoidCallback? onAddToSequence;

  /// Optional extra widget inserted before the action buttons (e.g. imaging history).
  final Widget? extraContent;

  /// Current cloud cover percentage (0-100). When provided, the altitude chart
  /// shows a background band: green (<20%), yellow (20-60%), red (>60%).
  final double? cloudCoverPercent;

  const ObjectDetailsPanel({
    super.key,
    required this.object,
    this.backgroundColor,
    this.textColor,
    this.accentColor,
    this.showVisibilityGraph = true,
    this.onGoTo,
    this.onAddToTargets,
    this.onFrameTarget,
    this.onAddToSequence,
    this.extraContent,
    this.cloudCoverPercent,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bgColor = backgroundColor ?? const Color(0xFF1A1A2E);
    final txtColor = textColor ?? Colors.white;
    final accent = accentColor ?? const Color(0xFF00E676);

    // Null until an observing site is on record. Altitude, rise/set and the
    // visibility grade are all measured from the observer's horizon, so those
    // sections are withheld rather than computed against a stand-in site.
    final site = ref.watch(observerLocationProvider).site;
    // Minute resolution, not the 1 Hz clock: nothing this panel shows moves
    // visibly inside a second, and the rise/set solves below are 289-sample
    // sweeps that would otherwise be re-run on the UI isolate every tick.
    final obsTime = ref.watch(observationMinuteProvider);

    final altAz = site == null
        ? null
        : AstronomyCalculations.objectAltAz(
            raDeg: object.coordinates.ra * 15, // Convert hours to degrees
            decDeg: object.coordinates.dec,
            dt: obsTime,
            latitudeDeg: site.latitude,
            longitudeDeg: site.longitude,
          );

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: txtColor.withValues(alpha: 0.1)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with name, type, and optional thumbnail for DSOs
            if (object is DeepSkyObject)
              _buildHeaderWithThumbnail(
                txtColor,
                accent,
                object as DeepSkyObject,
              )
            else
              _buildHeader(txtColor, accent),
            const SizedBox(height: 12),

            if (site == null) ...[
              _buildNoSiteNote(txtColor),
              const SizedBox(height: 16),
            ] else ...[
              // Visibility score indicator (new)
              Center(
                child: _buildVisibilityIndicator(
                  _calculateVisibilityScore(ref, site, altAz!.$1),
                ),
              ),
              const SizedBox(height: 12),

              // Quick stats bar (new)
              _buildQuickStats(ref, site, altAz.$1, txtColor),
              const SizedBox(height: 16),
            ],

            // Coordinates section
            _buildCoordinatesSection(txtColor),
            const SizedBox(height: 16),

            // Catalog IDs section
            _buildCatalogSection(txtColor, accent),
            const SizedBox(height: 16),

            // Physical properties section
            _buildPhysicalPropertiesSection(txtColor),
            const SizedBox(height: 16),

            if (site != null) ...[
              // Current visibility section
              _buildVisibilitySection(altAz!.$1, altAz.$2, txtColor, accent),

              if (showVisibilityGraph) ...[
                const SizedBox(height: 16),
                // Visibility graph (altitude over time)
                _buildVisibilityGraph(ref, txtColor, accent),
                const SizedBox(height: 16),
                // Airmass chart
                _buildAirmassChart(ref, txtColor, accent),
              ],

              const SizedBox(height: 16),

              // Rise/Transit/Set times
              _buildRiseTransitSetSection(ref, site, txtColor),
            ],

            // Extra content slot (e.g. imaging history)
            if (extraContent != null) ...[
              const SizedBox(height: 16),
              extraContent!,
            ],

            const SizedBox(height: 16),

            // Action buttons
            _buildActionButtons(accent),
          ],
        ),
      ),
    );
  }
}

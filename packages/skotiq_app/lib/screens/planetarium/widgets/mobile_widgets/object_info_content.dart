part of '../mobile_widgets.dart';

class MobileObjectInfoContent extends ConsumerWidget {
  final SkotiqColors colors;
  final ScrollController scrollController;
  final SelectedObjectState selectedObject;
  final VoidCallback onSendToFraming;
  final VoidCallback onAddToSequencer;

  /// Queue this object in the shared target queue (the sequencer Builder's
  /// Target Queue panel renders the same provider).
  final VoidCallback onAddToQueue;
  final VoidCallback onSlewToTarget;
  final VoidCallback onSlewAndCenter;
  final bool hasRotator;

  const MobileObjectInfoContent({
    super.key,
    required this.colors,
    required this.scrollController,
    required this.selectedObject,
    required this.onSendToFraming,
    required this.onAddToSequencer,
    required this.onAddToQueue,
    required this.onSlewToTarget,
    required this.onSlewAndCenter,
    required this.hasRotator,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final obj = selectedObject.object;
    if (obj == null) {
      return Center(
        child: Text(
          'No object selected',
          style: TextStyle(color: colors.textMuted),
        ),
      );
    }

    String displayName;
    String catalogTag;
    String typeName;
    if (obj is DeepSkyObject) {
      final info = getDsoDisplayInfo(obj);
      displayName = info.$1;
      catalogTag = info.$2;
      typeName = obj.type.displayName;
    } else if (obj is SolarSystemBody) {
      displayName = obj.name;
      catalogTag = obj.designation.toUpperCase();
      typeName = obj.kind.displayName;
    } else if (obj is Star) {
      displayName = obj.name;
      catalogTag = 'STAR';
      typeName =
          obj.spectralType != null ? 'Star (${obj.spectralType})' : 'Star';
    } else {
      displayName = obj.name;
      catalogTag = obj.id;
      typeName = 'Object';
    }

    final coords = selectedObject.coordinates;
    // Derived from the planetarium clock, not cached at selection time, so
    // scrubbing/time-travelling moves this the way the user expects.
    final altAz = ref.watch(selectedObjectAltAzProvider);
    final sunAltitude = ref.watch(sunAltitudeProvider);
    final grade = altAz == null
        ? null
        : gradeObservability(
            altitudeDeg: altAz.$1,
            sunAltitudeDeg: sunAltitude,
          );
    final gradeColor = switch (grade) {
      ObservabilityGrade.excellent => colors.success,
      ObservabilityGrade.good ||
      ObservabilityGrade.low ||
      ObservabilityGrade.twilight =>
        colors.warning,
      ObservabilityGrade.belowHorizon ||
      ObservabilityGrade.daylight =>
        colors.error,
      null => colors.textMuted,
    };

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        // Header
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              ),
              child: Text(
                catalogTag,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  fontWeight: FontWeight.bold,
                  color: colors.primary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize18,
                      fontWeight: FontWeight.bold,
                      color: colors.textPrimary,
                    ),
                  ),
                  Text(
                    typeName,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (obj.magnitude != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.surfaceAlt,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                ),
                child: Text(
                  'mag ${obj.magnitude!.toStringAsFixed(1)}',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textSecondary,
                  ),
                ),
              ),
          ],
        ),

        const SizedBox(height: 20),

        // Coordinates
        if (coords != null)
          MobileInfoCard(
            title: 'Coordinates',
            colors: colors,
            child: Row(
              children: [
                Expanded(
                  child: MobileInfoRow(
                    label: 'RA',
                    value: CoordinateFormatUtils.formatRA(coords.ra),
                    colors: colors,
                  ),
                ),
                Expanded(
                  child: MobileInfoRow(
                    label: 'Dec',
                    value: CoordinateFormatUtils.formatDec(coords.dec),
                    colors: colors,
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 12),

        // Current position
        if (altAz != null && grade != null)
          MobileInfoCard(
            title: 'Current position',
            colors: colors,
            child: Row(
              children: [
                Expanded(
                  child: MobileInfoRow(
                    label: 'Altitude',
                    value: altAz.$1.toStringAsFixed(1),
                    colors: colors,
                    valueColor: gradeColor,
                  ),
                ),
                Expanded(
                  child: MobileInfoRow(
                    label: 'Azimuth',
                    value: altAz.$2.toStringAsFixed(1),
                    colors: colors,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: gradeColor.withValues(alpha: 0.15),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                  ),
                  child: Text(
                    grade == ObservabilityGrade.belowHorizon
                        ? 'Below'
                        : grade.label,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      fontWeight: FontWeight.w500,
                      color: gradeColor,
                    ),
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 20),

        // Action buttons
        Row(
          children: [
            Expanded(
              child: MobileActionButton(
                icon: SkotiqIcons.crosshair,
                label: 'Slew',
                colors: colors,
                onTap: () {
                  Navigator.of(context).pop();
                  onSlewToTarget();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: MobileActionButton(
                icon: SkotiqIcons.target,
                label: 'Center',
                colors: colors,
                onTap: () {
                  Navigator.of(context).pop();
                  onSlewAndCenter();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: MobileActionButton(
                icon: SkotiqIcons.frame,
                label: 'Framing',
                colors: colors,
                onTap: () {
                  Navigator.of(context).pop();
                  onSendToFraming();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: MobileActionButton(
                icon: LucideIcons.listPlus,
                label: 'Add to Sequence',
                colors: colors,
                isPrimary: true,
                onTap: () {
                  Navigator.of(context).pop();
                  onAddToSequencer();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        MobileActionButton(
          icon: LucideIcons.listChecks,
          label: 'Add to Target Queue',
          colors: colors,
          onTap: () {
            Navigator.of(context).pop();
            onAddToQueue();
          },
        ),

        const SizedBox(height: 16),
      ],
    );
  }
}

/// Mobile info card container
class MobileInfoCard extends StatelessWidget {
  final String title;
  final SkotiqColors colors;
  final Widget child;

  const MobileInfoCard({
    super.key,
    required this.title,
    required this.colors,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              fontWeight: FontWeight.w600,
              color: colors.textMuted,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Mobile info row
class MobileInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;
  final Color? valueColor;

  const MobileInfoRow({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize10,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize13,
            fontWeight: FontWeight.w600,
            color: valueColor ?? colors.textPrimary,
            fontFeatures: const [ui.FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// Mobile action button
class MobileActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final SkotiqColors colors;
  final bool isPrimary;
  final VoidCallback onTap;

  const MobileActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.colors,
    this.isPrimary = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: isPrimary ? colors.primary : colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(
            color: isPrimary
                ? colors.primary.withValues(alpha: 0.85)
                : colors.border,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isPrimary ? onPrimary : colors.textPrimary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SkotiqTypography.h6.copyWith(
                    color: isPrimary ? onPrimary : colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

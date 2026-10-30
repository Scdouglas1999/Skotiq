part of '../annotation_overlay.dart';

/// Compact object info tooltip widget
class ObjectInfoTooltip extends ConsumerWidget {
  final CelestialObjectAnnotation object;
  final VoidCallback? onClose;
  final VoidCallback? onMoreInfo;

  const ObjectInfoTooltip({
    super.key,
    required this.object,
    this.onClose,
    this.onMoreInfo,
  });

  void _addToObservingList(WidgetRef ref, BuildContext context) async {
    final lists =
        ref.read(observingListsProvider).valueOrNull ?? <ObservingList>[];
    final notifier = ref.read(observingListNotifierProvider.notifier);

    int? targetListId;
    if (lists.isEmpty) {
      // Create a default list
      targetListId = await notifier.createList(name: 'My Observing List');
    } else {
      // Use the active list, or the first available
      targetListId = ref.read(activeObservingListIdProvider) ?? lists.first.id;
    }

    if (targetListId == null) return;

    await notifier.addItem(
      listId: targetListId,
      objectName: object.commonName ?? object.name,
      catalogId: object.catalogId ?? object.name,
      objectType: object.type.name,
      ra: object.ra / 15.0, // Convert degrees to hours for the table
      dec: object.dec,
      magnitude: object.magnitude,
      sizeArcmin: object.size,
    );

    final uiState = ref.read(observingListNotifierProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(uiState.errorMessage ??
              uiState.statusMessage ??
              'Added ${object.name}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _createSequenceForObject(
      WidgetRef ref, BuildContext context) async {
    // RA stored in degrees in annotation, sequence needs hours
    final raHours = object.ra / 15.0;

    final target = await catalogTargetSuggestion(
      ref: ref,
      targetName: object.commonName ?? object.name,
      raHours: raHours,
      decDegrees: object.dec,
      catalogId: object.catalogId ?? object.name,
      objectType: annotationObjectTypeLabel(object.type),
      magnitude: object.magnitude,
      sizeArcmin: object.size,
    );

    if (!context.mounted) return;
    final added = await addPlanTonightTargetToSequencer(
      context: context,
      ref: ref,
      target: target,
    );

    if (added && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Created sequence target for ${object.commonName ?? object.name}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);

    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceOverlay.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: ImageOverlayColors.shadow.withValues(alpha: 0.4),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ObjectTypeIcon(type: object.type),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      object.commonName ?? object.name,
                      style: const TextStyle(
                        color: _annotationOverlayTextColor,
                        fontSize: SkotiqTypography.fontSize14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (object.commonName != null)
                      Text(
                        object.name,
                        style: TextStyle(
                          color: ImageOverlayColors.foreground
                              .withValues(alpha: 0.65),
                          fontSize: SkotiqTypography.fontSize11,
                        ),
                      ),
                  ],
                ),
              ),
              if (onClose != null)
                // The tap lived on a bare gesture wrapper, which publishes an action
                // and no role, so assistive tech read a live control as an inert
                // disabled panel. The flags are only published when given.
                Semantics(
                    button: true,
                    enabled: true,
                    label: 'Close',
                    child: GestureDetector(
                      onTap: onClose,
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: ImageOverlayColors.foreground
                            .withValues(alpha: 0.6),
                      ),
                    )),
            ],
          ),
          const SizedBox(height: 8),
          _InfoRow(label: 'Type', value: _getTypeName(object.type)),
          if (object.magnitude != null)
            _InfoRow(
                label: 'Magnitude',
                value: object.magnitude!.toStringAsFixed(2)),
          if (object.size != null)
            _InfoRow(
                label: 'Size', value: '${object.size!.toStringAsFixed(1)}\''),
          _InfoRow(
            label: 'RA',
            value: _formatRA(object.ra),
          ),
          _InfoRow(
            label: 'Dec',
            value: _formatDec(object.dec),
          ),
          const SizedBox(height: 8),
          // Action buttons row
          Row(
            children: [
              Expanded(
                child: _TooltipActionButton(
                  icon: Icons.playlist_add,
                  label: 'Add to list',
                  onTap: () => _addToObservingList(ref, context),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _TooltipActionButton(
                  icon: Icons.auto_fix_high,
                  label: 'Sequence',
                  onTap: () => _createSequenceForObject(ref, context),
                ),
              ),
            ],
          ),
          if (onMoreInfo != null) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: SkotiqButton(
                onPressed: onMoreInfo,
                label: 'More info',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _getTypeName(ObjectType type) {
    switch (type) {
      case ObjectType.galaxy:
        return 'Galaxy';
      case ObjectType.nebula:
        return 'Nebula';
      case ObjectType.planetaryNebula:
        return 'Planetary Nebula';
      case ObjectType.starCluster:
        return 'Star Cluster';
      case ObjectType.star:
        return 'Star';
      case ObjectType.doubleStar:
        return 'Double Star';
      default:
        return 'Unknown';
    }
  }

  String _formatRA(double ra) => CoordinateFormat.raFromDegrees(
        ra,
        seconds: SecondsPrecision.oneDecimalPadded,
      );

  String _formatDec(double dec) =>
      CoordinateFormat.dec(dec, seconds: SecondsPrecision.oneDecimalPadded);
}

class _ObjectTypeIcon extends StatelessWidget {
  final ObjectType type;

  const _ObjectTypeIcon({required this.type});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color color;

    switch (type) {
      case ObjectType.galaxy:
        icon = Icons.blur_circular;
        color = AnnotationTypeColors.galaxy;
        break;
      case ObjectType.nebula:
        icon = Icons.cloud;
        color = AnnotationTypeColors.nebula;
        break;
      case ObjectType.planetaryNebula:
        icon = Icons.radio_button_unchecked;
        color = AnnotationTypeColors.planetaryNebula;
        break;
      case ObjectType.starCluster:
        icon = Icons.scatter_plot;
        color = AnnotationTypeColors.starCluster;
        break;
      case ObjectType.star:
      case ObjectType.doubleStar:
        icon = Icons.star;
        color = ImageOverlayColors.foreground;
        break;
      default:
        icon = Icons.help_outline;
        color = AnnotationTypeColors.asterism;
    }

    return Icon(icon, color: color, size: 20);
  }
}

class _TooltipActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _TooltipActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // The tap lived on a bare gesture wrapper, which publishes an action
    // and no role, so assistive tech read a live control as an inert
    // disabled panel. The flags are only published when given.
    return Semantics(
        button: true,
        enabled: true,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: ImageOverlayColors.foreground.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              border: Border.all(
                  color: ImageOverlayColors.foreground.withValues(alpha: 0.15)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 13,
                    color:
                        ImageOverlayColors.foreground.withValues(alpha: 0.8)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      color:
                          ImageOverlayColors.foreground.withValues(alpha: 0.8),
                      fontSize: SkotiqTypography.fontSize10,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ));
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: ImageOverlayColors.foreground.withValues(alpha: 0.6),
              fontSize: SkotiqTypography.fontSize11,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: _annotationOverlayTextColor,
              fontSize: SkotiqTypography.fontSize11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

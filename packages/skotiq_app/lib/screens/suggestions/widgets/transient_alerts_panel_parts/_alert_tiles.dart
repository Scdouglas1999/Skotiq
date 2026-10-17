// Unacknowledged badge, alert tiles and type badges.
part of '../transient_alerts_panel.dart';

// Unacknowledged badge

class _UnacknowledgedBadge extends ConsumerWidget {
  final SkotiqColors colors;

  const _UnacknowledgedBadge({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(unacknowledgedAlertCountProvider);
    if (count == 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.warning,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: SkotiqTypography.fontSize10,
          fontWeight: FontWeight.w700,
          color: colors.background,
        ),
      ),
    );
  }
}

// Transient alert tile

class _TransientAlertTile extends ConsumerStatefulWidget {
  final TransientAlert alert;
  final TransientAlertState? alertState;

  const _TransientAlertTile({
    super.key,
    required this.alert,
    this.alertState,
  });

  @override
  ConsumerState<_TransientAlertTile> createState() =>
      _TransientAlertTileState();
}

class _TransientAlertTileState extends ConsumerState<_TransientAlertTile> {
  bool _queueing = false;

  Future<void> _queue() async {
    if (_queueing) return;
    setState(() => _queueing = true);
    try {
      await queueTransientForTonight(ref, widget.alert);
    } finally {
      if (mounted) setState(() => _queueing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final alert = widget.alert;
    final effectiveState = widget.alertState ?? TransientAlertState.newAlert;
    final isNew = effectiveState == TransientAlertState.newAlert;
    final isDismissed = effectiveState == TransientAlertState.dismissed;
    final isQueued = effectiveState == TransientAlertState.queued;
    final isObserved = effectiveState == TransientAlertState.observed;

    return Opacity(
      opacity: isDismissed ? 0.5 : 1.0,
      child: Semantics(
          button: true,
          enabled: isNew,
          child: InkWell(
            onTap: isNew
                ? () => _runAlertStateAction(
                      context,
                      () => ref
                          .read(transientAlertStatesProvider.notifier)
                          .acknowledge(alert.id),
                    )
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Priority/type indicator
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: _TypeBadge(type: alert.type),
                  ),
                  const SizedBox(width: 10),

                  // Main content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                alert.name,
                                style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize13,
                                  fontWeight:
                                      isNew ? FontWeight.w700 : FontWeight.w500,
                                  color: colors.textPrimary,
                                ),
                              ),
                            ),
                            if (isNew)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: colors.primary.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(
                                      SkotiqTokens.radiusInline4),
                                ),
                                child: Text(
                                  'NEW',
                                  style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize9,
                                    fontWeight: FontWeight.w700,
                                    color: colors.primary,
                                  ),
                                ),
                              ),
                            if (isQueued)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: colors.success.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(
                                      SkotiqTokens.radiusInline4),
                                ),
                                child: Text(
                                  'QUEUED',
                                  style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize9,
                                    fontWeight: FontWeight.w700,
                                    color: colors.success,
                                  ),
                                ),
                              ),
                            if (isObserved)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: colors.info.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(
                                      SkotiqTokens.radiusInline4),
                                ),
                                child: Text(
                                  'OBSERVED',
                                  style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize9,
                                    fontWeight: FontWeight.w700,
                                    color: colors.info,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // Type, magnitude, coordinates
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            Text(
                              TransientTypeStyle.label(alert.type),
                              style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize11,
                                  color: colors.textMuted),
                            ),
                            if (alert.magnitude != null)
                              Text(
                                'mag ${alert.magnitude!.toStringAsFixed(1)}',
                                style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize11,
                                  color: colors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            Text(
                              'RA ${_formatRa(alert.raHours)} Dec ${_formatDec(alert.decDegrees)}',
                              style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize11,
                                  color: colors.textMuted),
                            ),
                            Text(
                              DateFormat('MMM d').format(alert.discoveryTime),
                              style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize11,
                                  color: colors.textMuted),
                            ),
                          ],
                        ),
                        if (alert.classification != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            alert.classification!,
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize10,
                              color: colors.textMuted,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Action buttons
                  if (!isDismissed && !isQueued && !isObserved) ...[
                    const SizedBox(width: 8),
                    Column(
                      children: [
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: IconButton(
                            icon: _queueing
                                ? SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: SkotiqMark(
                                        size: 14, color: colors.success),
                                  )
                                : Icon(
                                    LucideIcons.plus,
                                    size: 14,
                                    color: colors.success,
                                  ),
                            tooltip: 'Queue for tonight',
                            onPressed: _queueing ? null : _queue,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: IconButton(
                            icon: Icon(LucideIcons.x,
                                size: 14, color: colors.textMuted),
                            tooltip: 'Dismiss',
                            onPressed: () => _runAlertStateAction(
                              context,
                              () => ref
                                  .read(transientAlertStatesProvider.notifier)
                                  .dismiss(alert.id),
                            ),
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          )),
    );
  }

  String _formatRa(double raHours) => CoordinateFormat.ra(
        raHours,
        style: SexagesimalStyle.compactLeadPlainLetters,
        seconds: SecondsPrecision.integerFloored,
      );

  String _formatDec(double decDegrees) => CoordinateFormat.decDm(
        decDegrees,
        style: SexagesimalStyle.compactLeadPlainLetters,
      );
}

// Type badge

class _TypeBadge extends StatelessWidget {
  final TransientType type;

  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final color = TransientTypeStyle.color(type, colors);

    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Icon(TransientTypeStyle.icon(type), size: 14, color: color),
    );
  }
}

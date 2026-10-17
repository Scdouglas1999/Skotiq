// Cull toolbar, selection pill and lasso painter.
part of '../sub_cull_rail.dart';

class _CullToolbar extends StatelessWidget {
  final bool blink;
  final bool selectMode;
  final int selectedCount;
  final double hfrThreshold;

  /// Render-time verdict on the curve-driven cull. The toolbar renders the
  /// quantified action only when this is offerable.
  final CullRecommendationOffer offer;

  /// Live accepted-sub count, quoted in the stale explanation so the user can
  /// see *why* the analysis no longer applies, and read out beside the toolbar
  /// as the count of subs the integration will fold.
  final int acceptedCount;

  /// Subs this night captured but the cull is holding back.
  final int rejectedCount;
  final VoidCallback onToggleBlink;
  final VoidCallback onToggleSelect;
  final ValueChanged<double> onHfrChanged;
  final VoidCallback onBulkCull;
  final VoidCallback? onRejectSelected;
  final VoidCallback? onClearSelection;
  final VoidCallback? onCullToRecommended;

  const _CullToolbar({
    required this.blink,
    required this.selectMode,
    required this.selectedCount,
    required this.hfrThreshold,
    required this.offer,
    required this.acceptedCount,
    required this.rejectedCount,
    required this.onToggleBlink,
    required this.onToggleSelect,
    required this.onHfrChanged,
    required this.onBulkCull,
    required this.onRejectSelected,
    required this.onClearSelection,
    required this.onCullToRecommended,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final keepN = offer.keepN;
    final gainPct = offer.gainPct;

    return Wrap(
      spacing: SkotiqTokens.spaceMd,
      runSpacing: SkotiqTokens.spaceSm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // The two numbers the whole screen is about. They used to be a subtitle
        // sentence under the page title ("41 accepted · 6 rejected"), which is
        // a measurement written as prose in the one place 04-shell §4 has no
        // slot for. They belong here, beside the controls that change them.
        ReadoutRow(
          gap: SkotiqTokens.spaceLg,
          children: [
            Readout(
              value: '$acceptedCount',
              label: 'Accepted',
              size: ReadoutSize.sm,
            ),
            Readout(
              value: '$rejectedCount',
              label: 'Rejected',
              size: ReadoutSize.sm,
            ),
          ],
        ),
        SkotiqButton(
          label: blink ? 'Stop blink' : 'Blink mode',
          icon: SkotiqIcons.play,
          variant: blink ? ButtonVariant.primary : ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: onToggleBlink,
        ),
        SkotiqButton(
          label: selectMode ? 'Done selecting' : 'Select / lasso',
          icon: SkotiqIcons.crosshair,
          variant: selectMode ? ButtonVariant.primary : ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: onToggleSelect,
        ),
        if (selectMode) ...[
          _SelectionPill(count: selectedCount, colors: colors),
          SkotiqButton(
            label: 'Reject selected',
            icon: SkotiqIcons.error,
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
            onPressed: onRejectSelected,
          ),
          SkotiqButton(
            label: 'Clear',
            icon: SkotiqIcons.close,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: onClearSelection,
          ),
        ],
        if (onCullToRecommended != null)
          Tooltip(
            message:
                'Drop to the optimizer-recommended best $keepN subs (+${gainPct.toStringAsFixed(0)}% SNR)',
            child: SkotiqButton(
              label: 'Keep best $keepN (+${gainPct.toStringAsFixed(0)}%)',
              icon: SkotiqIcons.success,
              variant: ButtonVariant.primary,
              size: ButtonSize.small,
              onPressed: onCullToRecommended,
            ),
          )
        else if (offer.status == CullOfferStatus.stale)
          Tooltip(
            message: 'The optimizer ran over ${offer.populationSize} '
                '${offer.populationSize == 1 ? 'sub' : 'subs'}; '
                '$acceptedCount ${acceptedCount == 1 ? 'is' : 'are'} accepted '
                'now, so its keep-set no longer maps to them. Re-integrate to '
                'recompute the curve over the current selection.',
            child: const SkotiqChip(
              label: 'Cull analysis out of date',
              icon: SkotiqIcons.warning,
            ),
          )
        else if (offer.status == CullOfferStatus.alreadyOptimal)
          Tooltip(
            // Two different states share this status and they must not share a
            // sentence. "Keeps everything" is only true when keepN covers the
            // population; when the optimizer picked a SMALLER keep-set that
            // simply predicts no gain, saying it "would keep all N" misreports
            // what the optimizer actually recommended.
            message: keepN >= offer.populationSize
                ? 'The optimizer would keep all $acceptedCount accepted '
                    '${acceptedCount == 1 ? 'sub' : 'subs'} — there is '
                    'nothing to cull.'
                : 'The optimizer would keep $keepN of $acceptedCount, but '
                    'predicts no SNR gain from dropping the rest '
                    '(${gainPct.toStringAsFixed(0)}%), so the full stack is '
                    'the better one.',
            child: const SkotiqChip(
              label: 'Keep-set already optimal',
              icon: SkotiqIcons.success,
            ),
          ),
        if (!selectMode)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Cull HFR >',
                style: SkotiqTypography.bodySm
                    .copyWith(color: colors.textSecondary),
              ),
              SizedBox(
                width: 160,
                child: Slider(
                  value: hfrThreshold.clamp(1.0, 8.0),
                  min: 1.0,
                  max: 8.0,
                  divisions: 28,
                  activeColor: colors.primary,
                  label: hfrThreshold.toStringAsFixed(1),
                  onChanged: onHfrChanged,
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  hfrThreshold.toStringAsFixed(1),
                  style:
                      SkotiqTypography.mono.copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
        if (!selectMode)
          SkotiqButton(
            label: 'Reject HFR above',
            icon: SkotiqIcons.error,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: onBulkCull,
          ),
      ],
    );
  }
}

class _SelectionPill extends StatelessWidget {
  final int count;
  final SkotiqColors colors;
  const _SelectionPill({required this.count, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: SkotiqTokens.opacityStatusFill),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusFull),
        border: Border.all(color: colors.primary),
      ),
      child: Text(
        '$count selected',
        style: SkotiqTypography.labelSm.copyWith(color: colors.primary),
      ),
    );
  }
}

class _LassoPainter extends CustomPainter {
  final Rect rect;
  final Color color;

  _LassoPainter({required this.rect, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = color.withValues(alpha: SkotiqTokens.opacityStatusFill)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, fill);
    canvas.drawRect(rect, stroke);
  }

  @override
  bool shouldRepaint(_LassoPainter old) =>
      old.rect != rect || old.color != color;
}

part of '../object_details_panel.dart';

extension _ObjectDetailsPanelActionSections on ObjectDetailsPanel {
  Widget _buildActionButtons(Color accent) {
    // Second row of "act on this target from the sky" actions, shown only when
    // the host wired the callbacks (Frame target → Framing screen, Add to
    // sequence → add-to-sequence flow). Styled to mirror the primary row: a
    // ghost OutlinedButton paired with a FilledButton accent.
    final hasFrame = onFrameTarget != null;
    final hasAddToSequence = onAddToSequence != null;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(LucideIcons.crosshair, size: 16, color: accent),
                label: Text('Go To', style: TextStyle(color: accent)),
                onPressed: onGoTo,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: accent.withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(LucideIcons.plus, size: 16),
                label: const Text('Add Target'),
                onPressed: onAddToTargets,
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
        if (hasFrame || hasAddToSequence) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              if (hasFrame)
                Expanded(
                  child: OutlinedButton.icon(
                    icon: Icon(LucideIcons.scan, size: 16, color: accent),
                    label: Text(
                      'Frame target',
                      style: TextStyle(color: accent),
                    ),
                    onPressed: onFrameTarget,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: accent.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              if (hasFrame && hasAddToSequence) const SizedBox(width: 12),
              if (hasAddToSequence)
                Expanded(
                  child: OutlinedButton.icon(
                    icon: Icon(LucideIcons.listPlus, size: 16, color: accent),
                    label: Text(
                      'Add to sequence',
                      style: TextStyle(color: accent),
                    ),
                    onPressed: onAddToSequence,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: accent.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, Color txtColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: txtColor.withValues(alpha: 0.7),
              fontSize: 12,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: txtColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

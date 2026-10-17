import 'dart:io';

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/image_decode_size.dart';

/// The NxM panel grid: one tile per [MosaicProjectPanel], laid out row-major to
/// match the grid (`cols` wide), each showing the panel's status, captured
/// frame count, and — once integrated — a thumbnail of its per-panel master.
///
/// Pure presentation: it is handed the panels, the resolved per-panel masters
/// (keyed by `integrated_master_id`), and the grid dimensions; it never reads
/// the DB. Status colour + label come from the design system tokens only.
class MosaicPanelGrid extends StatelessWidget {
  /// Panels ordered by `panel_index` (row-major).
  final List<MosaicProjectPanel> panels;

  /// Per-panel masters keyed by `mosaic_panels.integrated_master_id`.
  final Map<int, IntegratedMaster> panelMasters;

  /// Grid columns (panels per row).
  final int cols;

  /// When true (the project is published to a hub and a collaborative service
  /// is wired) each tile renders per-panel distributed
  /// affordances: 'Claim' on an unclaimed panel, 'Release' on one this rig
  /// holds, and 'Upload' on an integrated-but-not-yet-uploaded panel. Off by
  /// default so a local-only project shows the plain grid.
  final bool collaborative;

  /// Invoked with a panel's index to take the hub claim baton for it.
  final void Function(int panelIndex)? onClaimPanel;

  /// Invoked with a panel's index to upload its integrated master to the hub.
  final void Function(int panelIndex)? onUploadPanel;

  /// Invoked with a panel's index to hand THIS device's own claim back to the
  /// pool. Surfaced on a panel this rig holds a live claim on, for owner
  /// and participant alike — without it a contributor cannot undo their own
  /// claim and the panel stays locked until the hub TTL expires or the owner
  /// force-releases it one panel at a time.
  final void Function(int panelIndex)? onReleasePanel;

  /// Owner/admin recovery: invoked with a panel's index to force-release a
  /// squatting claim or a poisoned upload back to `pending` on the hub. Only
  /// surfaced on a claimed or uploaded panel; the hub enforces owner/admin
  /// ownership. Null on a rig that is not the mosaic owner path.
  final void Function(int panelIndex)? onForceReleasePanel;

  /// Disables the per-panel collaborative buttons while any collaborative
  /// action is in flight, so a tap cannot stack a second hub call.
  final bool collaborativeBusy;

  const MosaicPanelGrid({
    super.key,
    required this.panels,
    required this.panelMasters,
    required this.cols,
    this.collaborative = false,
    this.onClaimPanel,
    this.onUploadPanel,
    this.onReleasePanel,
    this.onForceReleasePanel,
    this.collaborativeBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (panels.isEmpty) {
      return const EmptyState.compact(
        icon: SkotiqIcons.grid,
        title: 'No panels',
        body: 'This project has no panels laid out yet.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = SkotiqTokens.spaceSm;
        const minTileWidth = 120.0;
        final fitColumns =
            ((constraints.maxWidth + spacing) / (minTileWidth + spacing))
                .floor()
                .clamp(1, panels.length);
        final columns = cols.clamp(1, panels.length).clamp(1, fitColumns);
        final tileWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final panel in panels)
              SizedBox(
                width: tileWidth,
                child: _PanelTile(
                  panel: panel,
                  master: panel.integratedMasterId == null
                      ? null
                      : panelMasters[panel.integratedMasterId],
                  collaborative: collaborative,
                  onClaim: onClaimPanel,
                  onUpload: onUploadPanel,
                  onRelease: onReleasePanel,
                  onForceRelease: onForceReleasePanel,
                  collaborativeBusy: collaborativeBusy,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One panel tile — a [SkotiqCard] holding the panel number, its status
/// pill, a master thumbnail (when integrated) or a status-tinted placeholder,
/// and the captured-frame count.
class _PanelTile extends StatelessWidget {
  final MosaicProjectPanel panel;
  final IntegratedMaster? master;
  final bool collaborative;
  final void Function(int panelIndex)? onClaim;
  final void Function(int panelIndex)? onUpload;
  final void Function(int panelIndex)? onRelease;
  final void Function(int panelIndex)? onForceRelease;
  final bool collaborativeBusy;

  const _PanelTile({
    required this.panel,
    this.master,
    this.collaborative = false,
    this.onClaim,
    this.onUpload,
    this.onRelease,
    this.onForceRelease,
    this.collaborativeBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final preview = master?.previewPngPath;
    final hasThumb = preview != null && _exists(preview);

    // Per-panel distributed affordances. Claim a still-unclaimed panel;
    // upload an integrated panel whose master has not yet reached the hub. A
    // claimed-but-not-integrated panel shows neither (it is being captured), and
    // an already-uploaded panel shows neither (its work is done).
    final showClaim = collaborative && onClaim != null && !panel.isClaimed;
    final showUpload = collaborative &&
        onUpload != null &&
        panel.isIntegrated &&
        !panel.isUploaded;

    // Self-release: a live claim on the LOCAL mirror is only ever written by
    // this device's own successful claim, so `isClaimed` here means "this rig
    // holds the baton" — exactly the case the hub's per-account release accepts.
    // An uploaded panel is past the point of release (the hub refuses it), so
    // recovering that one stays the owner's force-release.
    final showRelease = collaborative &&
        onRelease != null &&
        panel.isClaimed &&
        !panel.isUploaded;

    // Owner/admin recovery: a claimed or already-uploaded panel can be
    // evicted back to `pending` to break a squatting claim or clear a poisoned
    // upload. Only meaningful in those two states — a pending panel is already
    // free. The hub enforces owner/admin ownership on the call itself.
    final showForceRelease = collaborative &&
        onForceRelease != null &&
        (panel.isClaimed || panel.isUploaded);

    // Attribution: once a panel is claimed, show which rig/user owns it so
    // the distributed capture has visible provenance on the grid.
    final assignedLabel = collaborative ? panel.assignedLabel : null;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                'Panel ${panel.panelIndex + 1}',
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
              ),
              const Spacer(),
              _PanelStatusDot(status: panel.status),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: SkotiqTokens.borderRadiusSm,
              // `previewPngPath` is the panel master's full-frame preview,
              // so the cell decodes at cell width rather than at 16 Mpx —
              // times every panel in the mosaic.
              child: hasThumb
                  ? LayoutBuilder(
                      builder: (context, constraints) => Image.file(
                        File(preview),
                        fit: BoxFit.cover,
                        cacheWidth: thumbnailDecodeWidth(
                          context,
                          constraints.maxWidth,
                        ),
                        errorBuilder: (_, __, ___) =>
                            _Placeholder(status: panel.status),
                      ),
                    )
                  : _Placeholder(status: panel.status),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Row(
            children: [
              Expanded(
                child: Text(
                  mosaicPanelStatusLabel(panel.status),
                  style: SkotiqTypography.captionSm.copyWith(
                    color: mosaicPanelStatusColor(panel.status, colors),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              Text(
                '${panel.capturedCount} sub${panel.capturedCount == 1 ? '' : 's'}',
                style: SkotiqTypography.captionSm
                    .copyWith(color: colors.textMuted),
              ),
            ],
          ),
          if (assignedLabel != null) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            Row(
              children: [
                Icon(
                  SkotiqIcons.user,
                  size: SkotiqTokens.iconXs,
                  color: colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                Expanded(
                  child: Text(
                    assignedLabel,
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          if (showClaim ||
              showUpload ||
              (collaborative && panel.isUploaded)) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            if (showClaim)
              SkotiqButton(
                label: 'Claim',
                icon: SkotiqIcons.download,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed:
                    collaborativeBusy ? null : () => onClaim!(panel.panelIndex),
              )
            else if (showUpload)
              SkotiqButton(
                label: 'Upload',
                icon: SkotiqIcons.upload,
                size: ButtonSize.small,
                onPressed: collaborativeBusy
                    ? null
                    : () => onUpload!(panel.panelIndex),
              )
            else if (collaborative && panel.isUploaded)
              Row(
                children: [
                  Icon(
                    SkotiqIcons.success,
                    size: SkotiqTokens.iconXs,
                    color: colors.success,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceXs),
                  Text(
                    'Uploaded',
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.success),
                  ),
                ],
              ),
          ],
          if (showRelease) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            SkotiqButton(
              label: 'Release',
              icon: SkotiqIcons.unlock,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed:
                  collaborativeBusy ? null : () => onRelease!(panel.panelIndex),
            ),
          ],
          if (showForceRelease) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            SkotiqButton(
              label: 'Force release',
              icon: SkotiqIcons.unlock,
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: collaborativeBusy
                  ? null
                  : () => onForceRelease!(panel.panelIndex),
            ),
          ],
        ],
      ),
    );
  }

  bool _exists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }
}

/// The status-tinted placeholder shown when a panel has no master thumbnail
/// (pending / capturing / captured / failed): a status icon over a faint tint.
class _Placeholder extends StatelessWidget {
  final MosaicPanelStatus status;

  const _Placeholder({required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final tint = mosaicPanelStatusColor(status, colors);
    return Container(
      color: tint.withValues(alpha: 0.08),
      alignment: Alignment.center,
      child: Icon(
        _statusIcon(status),
        size: SkotiqTokens.iconLg,
        color: tint.withValues(alpha: 0.7),
      ),
    );
  }

  IconData _statusIcon(MosaicPanelStatus status) {
    switch (status) {
      case MosaicPanelStatus.pending:
        return SkotiqIcons.clock;
      case MosaicPanelStatus.capturing:
        return SkotiqIcons.camera;
      case MosaicPanelStatus.captured:
        return SkotiqIcons.image;
      case MosaicPanelStatus.integrated:
        return SkotiqIcons.layers;
      case MosaicPanelStatus.failed:
        return SkotiqIcons.warning;
    }
  }
}

/// A small status dot for the panel tile header.
class _PanelStatusDot extends StatelessWidget {
  final MosaicPanelStatus status;

  const _PanelStatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return StatusDot(
      color: mosaicPanelStatusColor(status, colors),
      size: SkotiqTokens.spaceSm,
    );
  }
}

/// The display label for a [MosaicPanelStatus]. Shared with the header summary.
String mosaicPanelStatusLabel(MosaicPanelStatus status) {
  switch (status) {
    case MosaicPanelStatus.pending:
      return 'Pending';
    case MosaicPanelStatus.capturing:
      return 'Capturing';
    case MosaicPanelStatus.captured:
      return 'Captured';
    case MosaicPanelStatus.integrated:
      return 'Integrated';
    case MosaicPanelStatus.failed:
      return 'Failed';
  }
}

/// The design-system colour for a [MosaicPanelStatus]. Pulls only from the
/// passed [colors] (no raw hex): muted for pending, primary for in-flight /
/// captured, success for integrated, error for failed.
Color mosaicPanelStatusColor(MosaicPanelStatus status, SkotiqColors colors) {
  switch (status) {
    case MosaicPanelStatus.pending:
      return colors.textMuted;
    case MosaicPanelStatus.capturing:
      return colors.primary;
    case MosaicPanelStatus.captured:
      return colors.info;
    case MosaicPanelStatus.integrated:
      return colors.success;
    case MosaicPanelStatus.failed:
      return colors.error;
  }
}

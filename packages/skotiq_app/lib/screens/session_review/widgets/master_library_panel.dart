import 'dart:io';

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart' show unavailableControlName;
import '../../../utils/image_decode_size.dart';

/// Lists the persisted [IntegratedMaster]s for the current target and surfaces
/// the multi-night accumulation actions: open, finalize, add tonight's data,
/// start a new accumulating master, and delete.
///
/// Pure presentation — every mutation is delegated to the supplied callbacks so
/// the owning controller remains the single source of truth.
class MasterLibraryPanel extends StatelessWidget {
  final List<IntegratedMaster> masters;

  /// Accepted-light count in scope, so "add tonight" can be disabled when empty.
  final int acceptedSubCount;

  /// True while any integration / accumulation run is in flight.
  final bool busy;

  final void Function(IntegratedMaster) onOpen;

  /// Open the master in the Darkroom, where its recipe is editable.
  ///
  /// Separate from [onOpen], which shows the stretched preview in a dialog: one
  /// looks at the pixels the integration produced, the other edits the
  /// interpretation on top of them.
  final void Function(IntegratedMaster) onOpenInDarkroom;

  /// Why this machine cannot open the Darkroom at all, or null when it can.
  ///
  /// Stated by the OWNER of the screen, before the card is built, because the
  /// answer is about the machine rather than the master. The button used to be
  /// drawn live on a remote client and explained itself only after the press —
  /// so the operator learned the app's enabled state was not to be trusted.
  final String? darkroomRefusal;

  final void Function(IntegratedMaster) onAddTonight;
  final void Function(IntegratedMaster) onFinalize;
  final void Function(IntegratedMaster) onDelete;
  final VoidCallback onCreateAccumulating;

  const MasterLibraryPanel({
    super.key,
    required this.masters,
    required this.acceptedSubCount,
    required this.busy,
    required this.onOpen,
    required this.onOpenInDarkroom,
    this.darkroomRefusal,
    required this.onAddTonight,
    required this.onFinalize,
    required this.onDelete,
    required this.onCreateAccumulating,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          icon: SkotiqIcons.layers,
          title: 'Masters',
          trailing: SkotiqButton(
            label: 'New accumulating',
            icon: SkotiqIcons.add,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed:
                (busy || acceptedSubCount == 0) ? null : onCreateAccumulating,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        if (masters.isEmpty)
          SkotiqPanel(
            padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
            child: Row(
              children: [
                Icon(SkotiqIcons.layers, size: 18, color: colors.textMuted),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    'No masters yet. Integrate the night, or start an '
                    'accumulating master to grow across multiple nights.',
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          ...masters.map(
            (m) => Padding(
              padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
              child: _MasterCard(
                master: m,
                acceptedSubCount: acceptedSubCount,
                busy: busy,
                onOpen: () => onOpen(m),
                onOpenInDarkroom: () => onOpenInDarkroom(m),
                darkroomRefusal: darkroomRefusal,
                onAddTonight: () => onAddTonight(m),
                onFinalize: () => onFinalize(m),
                onDelete: () => onDelete(m),
              ),
            ),
          ),
      ],
    );
  }
}

class _MasterCard extends StatelessWidget {
  final IntegratedMaster master;
  final int acceptedSubCount;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onOpenInDarkroom;

  /// Why this machine cannot open the Darkroom at all — see
  /// [MasterLibraryPanel.darkroomRefusal].
  final String? darkroomRefusal;
  final VoidCallback onAddTonight;
  final VoidCallback onFinalize;
  final VoidCallback onDelete;

  const _MasterCard({
    required this.master,
    required this.acceptedSubCount,
    required this.busy,
    required this.onOpen,
    required this.onOpenInDarkroom,
    required this.darkroomRefusal,
    required this.onAddTonight,
    required this.onFinalize,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final accumulating =
        master.accumulationMode == AccumulationMode.runningWeightedMean;
    final canOpen =
        master.previewPngPath != null || master.masterFitsPath != null;
    // Two separate reasons the Darkroom cannot be opened from this card, and
    // the one that applies is the one the control states: the master has no
    // linear FITS, or this machine is not the imaging host. Both are known
    // BEFORE the press, which is why both are on the button.
    final refineRefusal = master.masterFitsPath == null
        ? 'This master has no linear FITS yet. Finalize the accumulation '
            'first — the Darkroom renders from linear pixels, not from the '
            'preview.'
        : darkroomRefusal;
    final canRefine = refineRefusal == null;

    return SkotiqCard(
      onTap: canOpen && !busy ? onOpen : null,
      enableHover: canOpen,
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Thumb(previewPath: master.previewPngPath, colors: colors),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        master.name,
                        style: SkotiqTypography.sectionTitle.copyWith(
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _StatusBadge(
                      label: accumulating
                          ? (master.status == IntegratedMasterStatus.finalized
                              ? 'Accumulating · finalized'
                              : 'Accumulating')
                          : 'Batch',
                      color: accumulating ? colors.info : colors.success,
                    ),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  '${master.frameCount} frame'
                  '${master.frameCount == 1 ? '' : 's'} · '
                  '${formatHms(master.totalIntegrationSeconds)} integration'
                  '${master.filter != null ? ' · ${master.filter}' : ''}',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                Text(
                  '${master.width}×${master.height} · '
                  '${master.isColor ? 'colour' : 'mono'} · '
                  'updated ${_relativeDate(master.updatedAt)}',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Wrap(
                  spacing: SkotiqTokens.spaceSm,
                  runSpacing: SkotiqTokens.spaceSm,
                  children: [
                    if (canOpen)
                      _MiniButton(
                        label: 'Open',
                        icon: SkotiqIcons.image,
                        onPressed: busy ? null : onOpen,
                      ),
                    // The Darkroom edits the recipe over the LINEAR master, so
                    // it needs the FITS — a preview PNG is a picture of a
                    // decision already taken. An accumulating master writes its
                    // FITS only at finalize, which is why the control says so
                    // rather than opening an editor with no pixels.
                    _MiniButton(
                      key: const ValueKey('master_open_in_darkroom'),
                      label: 'Darkroom',
                      icon: SkotiqIcons.sliders,
                      onPressed: (busy || !canRefine) ? null : onOpenInDarkroom,
                      tooltip: 'Edit this master\'s recipe in the Darkroom',
                      unavailableReason: refineRefusal,
                    ),
                    if (accumulating)
                      _MiniButton(
                        label: 'Add tonight',
                        icon: SkotiqIcons.add,
                        onPressed: (busy || acceptedSubCount == 0)
                            ? null
                            : onAddTonight,
                      ),
                    if (accumulating)
                      _MiniButton(
                        label: master.status == IntegratedMasterStatus.finalized
                            ? 'Re-finalize'
                            : 'Finalize',
                        icon: SkotiqIcons.download,
                        onPressed: busy ? null : onFinalize,
                      ),
                    _MiniButton(
                      label: 'Delete',
                      icon: SkotiqIcons.error,
                      destructive: true,
                      onPressed: busy ? null : onDelete,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _relativeDate(DateTime when) {
    final d = when.toLocal();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}

class _Thumb extends StatelessWidget {
  /// Tile edge in logical pixels. Also the decode width: `previewPngPath` is
  /// the master's full-frame preview, so without a `cacheWidth` this 72 px
  /// tile decodes a 16 Mpx PNG into 65 MB of RGBA.
  static const double _edgePx = 72;

  final String? previewPath;
  final SkotiqColors colors;

  const _Thumb({required this.previewPath, required this.colors});

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: _edgePx,
      height: _edgePx,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border),
      ),
      child: Icon(SkotiqIcons.layers, size: 24, color: colors.textMuted),
    );
    final path = previewPath;
    if (path == null) return placeholder;
    final file = File(path);
    bool exists;
    try {
      exists = file.existsSync();
    } catch (_) {
      exists = false;
    }
    if (!exists) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      child: Image.file(
        file,
        width: _edgePx,
        height: _edgePx,
        fit: BoxFit.cover,
        cacheWidth: thumbnailDecodeWidth(context, _edgePx),
        errorBuilder: (_, __, ___) => placeholder,
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      height: SkotiqChip.height,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqChip.horizontalPadding,
      ),
      // The chip decoration, not a pill: 02 allows four radii (4 / 6 / 8 / 12)
      // and `radiusFull` is not one of them. The tone supplies the fill at
      // `opacityStatusFill` and the ink.
      decoration: SkotiqDecorations.chip(colors, tone: color),
      child: Text(
        label,
        style: SkotiqTypography.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;

  /// Why the control is here. A disabled control with no explanation reads as
  /// a bug.
  final String? tooltip;

  /// Why the control cannot run, or null when it can.
  ///
  /// Separate from [tooltip] because it goes somewhere else as well: into the
  /// accessible NAME. Carried as a tooltip alone it reached a pointer and
  /// nothing else — the Linux AT-SPI bridge does not fold
  /// `SemanticsProperties.tooltip` into the name, so a screen reader was
  /// handed `Darkroom [DISABLED]` with no word about why. It is the tooltip
  /// too, replacing [tooltip], because a refusal is what a hovering operator
  /// needs to read over a description of what the control would have done.
  final String? unavailableReason;

  const _MiniButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
    this.tooltip,
    this.unavailableReason,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final fg = onPressed == null
        ? colors.textMuted
        : destructive
            ? colors.error
            : colors.textSecondary;
    final message = unavailableReason ?? tooltip;
    if (message != null) {
      return Tooltip(message: message, child: _build(colors, fg));
    }
    return _build(colors, fg);
  }

  Widget _build(SkotiqColors colors, Color fg) {
    final reason = onPressed == null ? unavailableReason : null;
    return Semantics(
        // A node of its own only when it has to REPLACE what is under it: an
        // annotation that excludes its child's semantics has nothing left to
        // merge into, so the renamed refusal needs the container to land on.
        // An available button keeps merging into the InkWell's own node, which
        // is what carries its tap.
        container: reason != null,
        button: true,
        enabled: onPressed != null,
        // The refusal in the name, and the visible label excluded so the two
        // do not both land in one node as "Darkroom Darkroom — <reason>".
        label: reason == null ? null : unavailableControlName(label, reason),
        excludeSemantics: reason != null,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm,
              vertical: SkotiqTokens.spaceXs,
            ),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: fg),
                const SizedBox(width: SkotiqTokens.spaceXs),
                Text(
                  label,
                  style: SkotiqTypography.labelSm.copyWith(color: fg),
                ),
              ],
            ),
          ),
        ));
  }
}

// Adds bare target headers from Framing to the open, saved, or a new sequence.
// The picker is not barrier-dismissible, errors are surfaced, and inserted
// headers are read back before success is reported.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Identifies the destination the user picked in the add-to-sequence dialog.
@immutable
class _SequenceDestination {
  /// Display label shown in the picker (sequence name, or "New empty sequence").
  final String label;

  /// Optional secondary line (e.g. target count) shown under [label].
  final String? subtitle;

  /// The saved sequence to open as the destination. `null` for the current
  /// in-editor sequence or for the "new empty sequence" option.
  final Sequence? savedSequence;

  /// True for the destination that targets the sequence already open in the
  /// editor (no load/copy required — just append).
  final bool isCurrent;

  /// True for the "create a brand-new empty sequence" destination.
  final bool isNew;

  const _SequenceDestination.current({required this.label, this.subtitle})
      : savedSequence = null,
        isCurrent = true,
        isNew = false;

  const _SequenceDestination.saved(this.savedSequence,
      {required this.label, this.subtitle})
      : isCurrent = false,
        isNew = false;

  const _SequenceDestination.newEmpty({required this.label})
      : savedSequence = null,
        subtitle = null,
        isCurrent = false,
        isNew = true;
}

/// Build a bare [TargetHeaderNode] (no child instructions) for a framed target.
///
/// Carries the framing composition forward: [rotationDegrees] (when non-zero)
/// becomes the header's `rotation` so the Sequencer's slew/center/rotate step
/// reproduces the framing the user dialed in. RA/Dec/name come straight from
/// the resolved [target].
TargetHeaderNode bareTargetHeaderForFramedTarget({
  required FramingTarget target,
  double? rotationDegrees,
}) {
  final rotation = (rotationDegrees != null && rotationDegrees != 0)
      ? rotationDegrees
      : null;
  return TargetHeaderNode(
    name: target.name,
    targetName: target.name,
    raHours: target.raHours,
    decDegrees: target.decDegrees,
    rotation: rotation,
  );
}

/// Build one bare [TargetHeaderNode] per drawn mosaic panel.
///
/// With Mosaic enabled the framing canvas draws an NxM grid of panels, each at
/// its own RA/Dec — that grid IS the composition the user made. Inserting only
/// [bareTargetHeaderForFramedTarget] threw the panels away and dropped a single
/// header at the grid's CENTRE, so a 2x2 mosaic silently became one frame of the
/// middle of it.
///
/// Each header carries the panel's own centre and is named
/// `"<target> Panel N"`, in the panel order the sidebar lists (capture order),
/// so the Sequencer shows the same panels in the same order as the canvas.
/// Panels also get [MosaicPanelInfo] so the frames they capture are stamped with
/// their mosaic identity in FITS, exactly as the wizard-built path does.
List<TargetHeaderNode> bareTargetHeadersForMosaicPanels({
  required FramingTarget target,
  required List<FramingMosaicPanel> panels,
  double? rotationDegrees,
}) {
  final rotation = (rotationDegrees != null && rotationDegrees != 0)
      ? rotationDegrees
      : null;
  final baseName = target.name.isEmpty ? 'Mosaic' : target.name;
  return [
    for (var i = 0; i < panels.length; i++)
      TargetHeaderNode(
        name: '$baseName Panel ${panels[i].index + 1}',
        targetName: '$baseName Panel ${panels[i].index + 1}',
        raHours: panels[i].centerRaHours,
        decDegrees: panels[i].centerDecDegrees,
        rotation: rotation,
        priority: i,
        mosaicPanel: MosaicPanelInfo(
          mosaicName: baseName,
          panelIndex: panels[i].index,
          totalPanels: panels.length,
          row: panels[i].row,
          column: panels[i].column,
        ),
      ),
  ];
}

/// Present the destination picker and insert a bare target header for [target].
///
/// Returns `true` when a header was added, `false` when the user cancelled or
/// the editor refused (locked sequence / declined clobber). Mirrors the return
/// contract of the existing `addTargetHeaderWithPrompt` helper so callers can
/// gate their success snackbar on it.
Future<bool> addFramedTargetToExistingSequence({
  required BuildContext context,
  required WidgetRef ref,
  required FramingTarget target,
  double? rotationDegrees,
  List<FramingMosaicPanel> mosaicPanels = const [],
}) async {
  // Preserve a drawn mosaic as one target group per panel.
  final panels =
      mosaicPanels.length >= 2 ? mosaicPanels : const <FramingMosaicPanel>[];
  final current = ref.read(currentSequenceProvider);
  List<Sequence>? saved;
  while (saved == null) {
    final savedAsync = ref.read(savedSequencesProvider);
    if (savedAsync.hasValue && !savedAsync.isLoading && !savedAsync.hasError) {
      saved = savedAsync.requireValue;
      break;
    }
    try {
      saved = await ref.read(savedSequencesProvider.future);
    } catch (error) {
      if (!context.mounted) return false;
      final retry = await _showSequenceLibraryError(context, error);
      if (retry != true || !context.mounted) return false;
      ref.invalidate(savedSequencesProvider);
    }
  }
  if (!context.mounted) return false;

  // De-dupe: the open sequence often also appears in the saved list (same
  // databaseId). Show it once, as the "current" destination.
  final currentDbId = current?.databaseId;
  final destinations = <_SequenceDestination>[
    if (current != null)
      _SequenceDestination.current(
        label: current.name.isEmpty ? 'Current sequence' : current.name,
        subtitle: _targetCountSubtitle(current),
      ),
    for (final seq in saved)
      if (!(currentDbId != null && seq.databaseId == currentDbId))
        _SequenceDestination.saved(
          seq,
          label: seq.name.isEmpty ? 'Untitled sequence' : seq.name,
          subtitle: _targetCountSubtitle(seq),
        ),
    const _SequenceDestination.newEmpty(
      label: 'New empty sequence',
    ),
  ];

  // Default selection: the open sequence if there is one, else the first saved
  // sequence, else the "new empty" option.
  final initialIndex =
      current != null ? 0 : (saved.isNotEmpty ? 0 : destinations.length - 1);

  final chosen = await showDialog<_SequenceDestination>(
    context: context,
    // This is a commit surface with its own Cancel. Barrier dismissal made
    // "I pressed Add target and nothing happened" indistinguishable from
    // "I cancelled": both closed the dialog and returned null, and the caller
    // reports nothing on null. A stray click must not be able to throw away a
    // confirmed choice in silence.
    barrierDismissible: false,
    builder: (ctx) => _DestinationPickerDialog(
      targetName: target.name,
      destinations: destinations,
      initialIndex: initialIndex,
      mosaicPanelCount: panels.length,
    ),
  );
  if (chosen == null || !context.mounted) return false;

  final headers = panels.isEmpty
      ? [
          bareTargetHeaderForFramedTarget(
              target: target, rotationDegrees: rotationDegrees),
        ]
      : bareTargetHeadersForMosaicPanels(
          target: target,
          panels: panels,
          rotationDegrees: rotationDegrees,
        );
  final notifier = ref.read(currentSequenceProvider.notifier);
  void addAll() {
    for (final header in headers) {
      notifier.addTargetHeader(header);
    }
  }

  /// Confirm the headers are really in the editor's sequence before telling
  /// the caller (and therefore the user) that they are.
  bool insertLanded() {
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return false;
    return headers.every((header) => sequence.nodes.containsKey(header.id));
  }

  /// Report a failure the user can act on instead of closing in silence.
  void reportNotAdded() {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Could not add ${target.name.isEmpty ? 'the target' : target.name} '
          'to the sequence. Open the Sequencer and add it there.',
        ),
      ),
    );
  }

  try {
    if (chosen.isNew) {
      notifier.createSequence(
        name: target.name.isEmpty ? 'New Sequence' : target.name,
        discardUnsaved: false,
      );
      addAll();
    } else if (chosen.isCurrent) {
      addAll();
    } else {
      // A different saved sequence — open a fresh-ID copy into the editor,
      // then append the header(s).
      notifier.loadCopyForEditing(chosen.savedSequence!);
      addAll();
    }
    if (!insertLanded()) {
      reportNotAdded();
      return false;
    }
    return true;
  } on UnsavedChangesException catch (e) {
    if (!context.mounted) return false;
    final discard = await _confirmDiscard(
      context,
      currentName: e.currentSequenceName,
      destinationName: chosen.label,
    );
    if (discard != true || !context.mounted) return false;
    try {
      if (chosen.isNew) {
        notifier.createSequence(
          name: target.name.isEmpty ? 'New Sequence' : target.name,
          discardUnsaved: true,
        );
      } else {
        notifier.loadCopyForEditing(chosen.savedSequence!,
            discardUnsaved: true);
      }
      addAll();
      if (!insertLanded()) {
        reportNotAdded();
        return false;
      }
      return true;
    } on SequenceLockedException catch (lockErr) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(lockErr.message)));
      }
      return false;
    }
  } on SequenceLockedException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  } on NoActiveSequenceException catch (e) {
    // Should not happen — createSequence precedes addTargetHeader on the new
    // path and the current/saved paths guarantee a loaded sequence. Surface
    // rather than silently no-op if the invariant is ever broken.
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  } catch (e) {
    // Anything else would otherwise leave this Future with an unhandled error:
    // the button's onPressed does not await a result it can inspect, so the
    // exception goes to the zone handler and the user is shown nothing at all
    // while the dialog closes as if the target had been added.
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not add '
            '${target.name.isEmpty ? 'the target' : target.name} '
            'to the sequence: $e',
          ),
        ),
      );
    }
    return false;
  }
}

Future<bool?> _showSequenceLibraryError(
  BuildContext context,
  Object error,
) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => SkotiqDialog(
      title: 'Could not load saved sequences',
      icon: LucideIcons.alertTriangle,
      width: 440,
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          label: 'Retry',
          size: ButtonSize.small,
        ),
      ],
      child: Text(
        'Skotiq could not verify the sequence library: $error\n\n'
        'No destination list or new-sequence option will be shown until the '
        'library loads successfully.',
      ),
    ),
  );
}

String? _targetCountSubtitle(Sequence sequence) {
  final count = sequence.nodes.values.whereType<TargetHeaderNode>().length;
  if (count == 0) return 'No targets yet';
  return '$count target${count == 1 ? '' : 's'}';
}

Future<bool?> _confirmDiscard(
  BuildContext context, {
  required String currentName,
  required String destinationName,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => SkotiqDialog(
      title: 'Discard unsaved changes?',
      icon: SkotiqIcons.warning,
      width: 440,
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          label: 'Discard and continue',
          size: ButtonSize.small,
        ),
      ],
      child: Text(
        '"$currentName" has unsaved changes. Switching to "$destinationName" '
        'will discard them.',
      ),
    ),
  );
}

/// Radio-list dialog letting the user choose where the framed target goes.
class _DestinationPickerDialog extends StatefulWidget {
  final String targetName;
  final List<_SequenceDestination> destinations;
  final int initialIndex;

  /// How many mosaic panels will be inserted (0 when no mosaic is drawn). The
  /// dialog states it explicitly so a drawn mosaic cannot be silently dropped.
  final int mosaicPanelCount;

  const _DestinationPickerDialog({
    required this.targetName,
    required this.destinations,
    required this.initialIndex,
    this.mosaicPanelCount = 0,
  });

  @override
  State<_DestinationPickerDialog> createState() =>
      _DestinationPickerDialogState();
}

class _DestinationPickerDialogState extends State<_DestinationPickerDialog> {
  late int _selected = widget.initialIndex;

  bool get _isMosaic => widget.mosaicPanelCount >= 2;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final panelCount = widget.mosaicPanelCount;
    return SkotiqDialog(
      title: _isMosaic ? 'Add mosaic to sequence' : 'Add target to sequence',
      icon: LucideIcons.listPlus,
      width: 460,
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: () =>
              Navigator.of(context).pop(widget.destinations[_selected]),
          label: _isMosaic ? 'Add $panelCount panels' : 'Add target',
          icon: SkotiqIcons.add,
          size: ButtonSize.small,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _isMosaic
                ? 'Insert the drawn mosaic as $panelCount target groups — one '
                    'per panel, each at its own coordinates. You add the '
                    'imaging instructions under them in the Sequencer.'
                : 'Insert "${widget.targetName}" as a new target group. You add '
                    'the imaging instructions under it in the Sequencer.',
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          for (var i = 0; i < widget.destinations.length; i++)
            _DestinationTile(
              destination: widget.destinations[i],
              selected: i == _selected,
              onTap: () => setState(() => _selected = i),
              colors: colors,
            ),
        ],
      ),
    );
  }
}

class _DestinationTile extends StatelessWidget {
  final _SequenceDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final SkotiqColors colors;

  const _DestinationTile({
    required this.destination,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final icon = destination.isNew
        ? LucideIcons.filePlus
        : destination.isCurrent
            ? SkotiqIcons.edit
            : SkotiqIcons.folderOpen;
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        child: Container(
          padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
          decoration: BoxDecoration(
            color: selected
                ? colors.primary.withValues(alpha: 0.12)
                : colors.surfaceElevated,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            border: Border.all(
              color: selected ? colors.primary : colors.border,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? LucideIcons.checkCircle2 : SkotiqIcons.circle,
                size: SkotiqTokens.iconSm,
                color: selected ? colors.primary : colors.textMuted,
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Icon(icon,
                  size: SkotiqTokens.iconSm, color: colors.textSecondary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      destination.label,
                      style: SkotiqTypography.bodyMedium
                          .copyWith(color: colors.textPrimary),
                    ),
                    if (destination.subtitle != null)
                      Text(
                        destination.subtitle!,
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textMuted),
                      ),
                  ],
                ),
              ),
              if (destination.isCurrent) _Badge(label: 'Open', colors: colors),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final SkotiqColors colors;

  const _Badge({required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      ),
      child: Text(
        label,
        style: SkotiqTypography.caption.copyWith(color: colors.primary),
      ),
    );
  }
}

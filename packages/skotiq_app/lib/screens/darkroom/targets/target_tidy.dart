/// The Darkroom's own housekeeping: which targets are projects, and the
/// corrections a user can make (hide, list as a project, rename, merge, file
/// lights under a target, delete with files). Every correction is one
/// deliberate action with an Undo; nothing here runs by itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import '../../../utils/snackbar_helper.dart';
import 'darkroom_targets_model.dart';
import 'darkroom_targets_providers.dart';

final darkroomFileTrashProvider = FutureProvider<FileTrash>(
  (ref) => PlatformFileTrash.detect(),
);

final darkroomTargetEditsProvider = Provider<DarkroomTargetEdits>(
  (ref) => DarkroomTargetEdits(
    ref.watch(databaseProvider),
    trash: () => ref.read(darkroomFileTrashProvider.future),
  ),
);

DarkroomTargetGroup darkroomGroupOf(DarkroomTarget t) => DarkroomTargetGroup(
      key: t.key,
      row: t.row,
      frames: t.frames,
      masters: t.masters,
    );

/// Runs [edit], re-reads the targets, opens [goTo] when given, and offers
/// Undo, which puts the edit back and opens [undoGoTo].
Future<bool> applyDarkroomTargetEdit(
  BuildContext context,
  Future<TargetEdit> Function(DarkroomTargetEdits edits) edit, {
  String? goTo,
  String? undoGoTo,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);
  // Undo can come after the widget that started the edit is gone.
  final container = ProviderScope.containerOf(context, listen: false);
  void reread() {
    container.invalidate(darkroomTargetPlacementsProvider);
    container.invalidate(darkroomTargetsProvider);
  }

  try {
    final edits = container.read(darkroomTargetEditsProvider);
    final done = await edit(edits);
    reread();
    if (goTo != null) router.go(darkroomTargetLocation(goTo));
    messenger.showSuccessSnackBar(
      done.summary,
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          try {
            await edits.undo(done);
            reread();
            if (undoGoTo != null) router.go(darkroomTargetLocation(undoGoTo));
          } catch (e) {
            messenger.showErrorSnackBar(
              'Could not undo: ${userFacingError(e)}',
            );
          }
        },
      ),
    );
    return true;
  } catch (e) {
    messenger.showErrorSnackBar(userFacingError(e));
    return false;
  }
}

/// "6 min", "1.1 h": kept light the way the target rows print it.
String _kept(double seconds) => describeIntegration(seconds);

String _minutes(int minutes) =>
    minutes >= 60 && minutes % 60 == 0 ? '${minutes ~/ 60} h' : '$minutes min';

/// Opens the project rule settings.
class DarkroomProjectRuleButton extends StatelessWidget {
  const DarkroomProjectRuleButton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkotiqIconButton(
      key: const ValueKey('darkroom_project_rule'),
      icon: SkotiqIcons.settings2,
      tooltip: 'Which targets are projects',
      size: IconButtonSize.sm,
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => const DarkroomProjectRuleDialog(),
      ),
    );
  }
}

/// The two minimums that make a target a project.
class DarkroomProjectRuleDialog extends ConsumerStatefulWidget {
  const DarkroomProjectRuleDialog({super.key});

  @override
  ConsumerState<DarkroomProjectRuleDialog> createState() =>
      _DarkroomProjectRuleDialogState();
}

class _DarkroomProjectRuleDialogState
    extends ConsumerState<DarkroomProjectRuleDialog> {
  TextEditingController? _minutes;
  TextEditingController? _frames;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _minutes?.dispose();
    _frames?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final minutes = int.tryParse(_minutes!.text.trim());
    final frames = int.tryParse(_frames!.text.trim());
    if (minutes == null || minutes < 0 || frames == null || frames < 0) {
      setState(() => _error = 'Enter whole numbers, 0 or more.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ProjectRule(minKeptMinutes: minutes, minKeptFrames: frames)
          .save(ref.read(settingsDaoProvider));
      ref.invalidate(darkroomProjectRuleProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'The setting was not saved: ${userFacingError(e)}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final rule = ref.watch(darkroomProjectRuleProvider).valueOrNull;
    if (rule != null && _minutes == null) {
      _minutes = TextEditingController(text: '${rule.minKeptMinutes}');
      _frames = TextEditingController(text: '${rule.minKeptFrames}');
    }
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return SkotiqDialog(
      title: 'Which targets are projects',
      width: SkotiqDialog.widthConfirm,
      closeEnabled: !_saving,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          key: const ValueKey('darkroom_project_rule_save'),
          label: 'Save',
          onPressed: rule == null || _saving ? null : _save,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'A target is listed as a project once its kept lights reach both '
            'minimums, and moves there by itself as a run adds lights. '
            'Everything else is under Other captures. Nothing is deleted.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          if (rule == null)
            const ShimmerLoading(child: SkeletonText(width: 240, height: 14))
          else ...[
            FormRow(
              label: 'Kept light',
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 120,
                  child: SkotiqTextField(
                    key: const ValueKey('darkroom_project_rule_minutes'),
                    controller: _minutes,
                    suffix: 'min',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: digits,
                  ),
                ),
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            FormRow(
              label: 'Kept lights',
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 120,
                  child: SkotiqTextField(
                    key: const ValueKey('darkroom_project_rule_frames'),
                    controller: _frames,
                    suffix: 'subs',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: digits,
                    onSubmitted: (_) => _save(),
                  ),
                ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              _error!,
              style: SkotiqTypography.bodySm.copyWith(color: colors.error),
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceLg),
        ],
      ),
    );
  }
}

enum _TargetAction { hide, list, rename, merge, delete }

/// The "more" menu on a target: the corrections a user can make to it.
class DarkroomTargetMenu extends ConsumerWidget {
  const DarkroomTargetMenu({super.key, required this.target});

  final DarkroomTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = target;
    return SkotiqMenuButton<_TargetAction>(
      key: const ValueKey('darkroom_target_menu'),
      tooltip: 'More actions for ${t.key}',
      entries: [
        if (t.identified && t.isProject)
          const SkotiqMenuChoice(_TargetAction.hide, 'Move to Other captures'),
        if (t.identified && !t.isProject)
          const SkotiqMenuChoice(_TargetAction.list, 'List as a project'),
        SkotiqMenuChoice(
          _TargetAction.rename,
          t.identified ? 'Rename…' : 'Name these lights…',
        ),
        SkotiqMenuChoice(
          _TargetAction.merge,
          t.identified ? 'Merge into another target…' : 'File under a target…',
        ),
        const SkotiqMenuDivider(),
        SkotiqMenuChoice(
          _TargetAction.delete,
          t.identified
              ? 'Delete target and its files…'
              : 'Delete these lights and their files…',
          destructive: true,
        ),
      ],
      onSelected: (action) => switch (action) {
        _TargetAction.hide => darkroomPlaceTarget(context, ref, t, false),
        _TargetAction.list => darkroomPlaceTarget(context, ref, t, true),
        _TargetAction.rename => _rename(context, ref),
        _TargetAction.merge => _merge(context, ref),
        _TargetAction.delete => _delete(context, ref),
      },
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(target: target),
    );
    if (name == null || !context.mounted) return;
    await applyDarkroomTargetEdit(
      context,
      (edits) => edits.rename(darkroomGroupOf(target), name),
      goTo: name.trim(),
      undoGoTo: target.key,
    );
  }

  Future<void> _merge(BuildContext context, WidgetRef ref) async {
    final all = await ref.read(darkroomTargetsProvider.future);
    if (!context.mounted) return;
    final into = await showDialog<DarkroomTarget>(
      context: context,
      builder: (_) => _MergeDialog(from: target, targets: all),
    );
    if (into == null || !context.mounted) return;
    await applyDarkroomTargetEdit(
      context,
      (edits) => edits.merge(darkroomGroupOf(target), darkroomGroupOf(into)),
      goTo: into.key,
      undoGoTo: target.key,
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      final edits = ref.read(darkroomTargetEditsProvider);
      final plan = await edits.planDeletion(darkroomGroupOf(target));
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _DeleteDialog(target: target, plan: plan),
      );
      if (confirmed != true) return;
      final failed = await edits.delete(plan);
      ref.invalidate(darkroomTargetPlacementsProvider);
      ref.invalidate(darkroomTargetsProvider);
      router.go(darkroomTabLocation(DarkroomTab.targets));
      if (failed.isEmpty) {
        messenger.showSuccessSnackBar(
          plan.restorable
              ? 'Deleted ${target.key}. Its files are in the Trash.'
              : 'Deleted ${target.key} and its files.',
        );
      } else {
        messenger.showErrorSnackBar(
          '${failed.length} file${failed.length == 1 ? '' : 's'} could not '
          'be removed, so their records stay: ${failed.first}',
        );
      }
    } catch (e) {
      messenger.showErrorSnackBar(
        'Could not delete ${target.key}: ${userFacingError(e)}',
      );
    }
  }
}

/// Lists [target] among the projects ([asProject]) or under Other captures,
/// with the smallest correction that does it: none when the rule already
/// agrees.
Future<void> darkroomPlaceTarget(
  BuildContext context,
  WidgetRef ref,
  DarkroomTarget target,
  bool asProject,
) {
  final byRule =
      targetStanding(target.captures, target.rule) == TargetStanding.project;
  final placement = byRule == asProject
      ? TargetPlacement.auto
      : (asProject ? TargetPlacement.project : TargetPlacement.hidden);
  return applyDarkroomTargetEdit(
    context,
    (edits) => edits.place(target.key, placement),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.target});

  final DarkroomTarget target;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(
    text: widget.target.identified ? widget.target.key : '',
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the target a name');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.target;
    return SkotiqDialog(
      title: t.identified ? 'Rename ${t.key}' : 'Name these lights',
      width: SkotiqDialog.widthConfirm,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          key: const ValueKey('darkroom_name_save'),
          label: t.identified ? 'Rename' : 'Save',
          onPressed: _submit,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!t.identified) ...[
            Text(
              'The ${t.frames.length} lights become a saved target of this '
              'name, placed where they were taken.',
              style: SkotiqTypography.bodySm.copyWith(
                color: context.skotiqColors.textSecondary,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
          ],
          FormRow(
            label: 'Name',
            child: SkotiqTextField(
              key: const ValueKey('darkroom_name_field'),
              controller: _name,
              autofocus: true,
              dense: true,
              errorText: _error,
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
        ],
      ),
    );
  }
}

/// Picks the target [from]'s lights and masters are filed under. Targets at
/// the same position come first.
class _MergeDialog extends StatefulWidget {
  const _MergeDialog({required this.from, required this.targets});

  final DarkroomTarget from;
  final List<DarkroomTarget> targets;

  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  String _query = '';
  DarkroomTarget? _picked;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final from = widget.from;
    final near = darkroomTargetsNearby(from, widget.targets).toSet();
    final needle = normalizeDarkroomTargetName(_query);
    final choices = [
      for (final t in widget.targets)
        if (t.identified &&
            t.key != from.key &&
            (needle.isEmpty ||
                normalizeDarkroomTargetName(t.key).contains(needle)))
          t,
    ]..sort((a, b) {
        final byNear = (near.contains(b) ? 1 : 0) - (near.contains(a) ? 1 : 0);
        return byNear != 0 ? byNear : a.key.compareTo(b.key);
      });
    final picked = _picked;
    return SkotiqDialog(
      title: from.identified
          ? 'Merge ${from.key} into another target'
          : 'File these lights under a target',
      width: SkotiqDialog.widthConfirm,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          key: const ValueKey('darkroom_merge_confirm'),
          label: from.identified ? 'Merge' : 'File under it',
          onPressed:
              picked == null ? null : () => Navigator.of(context).pop(picked),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            from.identified
                ? 'For one object saved under two names. Its '
                    '${from.frames.length} lights and ${from.masters.length} '
                    'masters are filed under the target you pick; '
                    '${from.key} stays in your target list with nothing '
                    'captured. You can undo this right after.'
                : 'The ${from.frames.length} lights are filed under the '
                    'target you pick. You can undo this right after.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqSearchField(
            hint: 'Search targets',
            onChanged: (q) => setState(() => _query = q),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          if (choices.isEmpty)
            Padding(
              padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
              child: Text(
                'No other target to merge into.',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          for (final t in choices)
            ListRow(
              key: ValueKey('darkroom_merge_choice_${t.key}'),
              title: t.key,
              subtitle: [
                '${t.frames.length} lights',
                if (t.keptSeconds > 0) _kept(t.keptSeconds),
                if (near.contains(t)) 'same position',
              ].join(' · '),
              selected: t == picked,
              onTap: () => setState(() => _picked = t),
            ),
          const SizedBox(height: SkotiqTokens.spaceLg),
        ],
      ),
    );
  }
}

/// The confirmation that lists everything "Delete target and its files"
/// removes.
class _DeleteDialog extends StatelessWidget {
  const _DeleteDialog({required this.target, required this.plan});

  final DarkroomTarget target;
  final TargetDeletion plan;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final lights = target.frames.length;
    final masters = target.masters.length;
    final kept = target.keptSeconds;
    final lines = [
      '$lights light frame${lights == 1 ? '' : 's'}'
          '${kept > 0 ? ' (${_kept(kept)} kept)' : ''}: '
          '${plan.lightFiles.length} file'
          '${plan.lightFiles.length == 1 ? '' : 's'}',
      if (masters > 0)
        '$masters master${masters == 1 ? '' : 's'}: '
            '${plan.masterFiles.length} file'
            '${plan.masterFiles.length == 1 ? '' : 's'}',
      for (final row in plan.targetRows) '${row.name} from your target list',
    ];
    final body = SkotiqTypography.body.copyWith(color: colors.textPrimary);
    return SkotiqDialog(
      title: target.identified
          ? 'Delete ${target.key} and its files?'
          : 'Delete these lights and their files?',
      width: SkotiqDialog.widthConfirm,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SkotiqButton(
          key: const ValueKey('darkroom_delete_confirm'),
          label: plan.restorable ? 'Move to Trash' : 'Delete for good',
          variant: ButtonVariant.destructive,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('This removes:', style: body),
          const SizedBox(height: SkotiqTokens.spaceSm),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(
                left: SkotiqTokens.spaceMd,
                bottom: SkotiqTokens.spaceXs,
              ),
              child: Text('• $line', style: body),
            ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            plan.restorable
                ? 'The files go to the Trash, where you can restore them. '
                    'Calibration frames and other targets are not touched.'
                : 'This computer has no Trash: the files are deleted for '
                    'good and cannot be restored. Calibration frames and '
                    'other targets are not touched.',
            style: SkotiqTypography.bodySm.copyWith(
              color: plan.restorable ? colors.textSecondary : colors.error,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
        ],
      ),
    );
  }
}

/// The other listed targets whose saved position is on [target]'s: maybe
/// the same object under another name.
List<DarkroomTarget> darkroomTargetsNearby(
  DarkroomTarget target,
  List<DarkroomTarget> all,
) {
  final row = target.row;
  if (row == null) return const [];
  final nearIds = {
    for (final t in darkroomTargetsAtPosition(
      row.ra,
      row.dec,
      [
        for (final o in all)
          if (o.row != null && o.key != target.key) o.row!,
      ],
    ))
      t.id,
  };
  return [
    for (final o in all)
      if (o.row != null && nearIds.contains(o.row!.id)) o,
  ];
}

/// What the Darkroom can tell the user about [target]: why it is not a
/// project, saved targets its stray lights were taken on, and a target at the
/// same position that may be the same object.
class DarkroomTargetSuggestions extends ConsumerWidget {
  const DarkroomTargetSuggestions({super.key, required this.target});

  final DarkroomTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = target;
    final all = ref.watch(darkroomTargetsProvider).valueOrNull ?? const [];
    final rows = ref.watch(allDbTargetsProvider).valueOrNull ?? const [];
    final banners = <Widget>[];
    if (!t.identified) {
      banners.add(
        const SkotiqBanner(
          key: ValueKey('darkroom_other_reason'),
          title: 'These lights name no target.',
          message: 'They were taken without a target, a run or a plate solve '
              'that places them on one. Name them, or file them under a '
              'target from the menu.',
        ),
      );
      for (final (row, frames) in _fieldsOf(t.frames, rows).take(2)) {
        final count = frames.length;
        final byHand = frames.every((f) => f.producingRunId?.isEmpty ?? true);
        final runTarget = all
            .where((o) => o.row?.id == row.id)
            .any((o) => o.captures.runLights > 0);
        banners.add(
          SkotiqBanner(
            key: ValueKey('darkroom_field_${row.name}'),
            title: '$count of these lights were taken on '
                '${row.name}\'s field.',
            message: byHand && runTarget
                ? 'They were taken by hand. Filed under ${row.name}, they go '
                    'into its masters with its run\'s lights.'
                : 'File them under ${row.name} to keep them with it.',
            action: SkotiqButton(
              label: 'File under ${row.name}',
              size: ButtonSize.small,
              variant: ButtonVariant.secondary,
              onPressed: () => applyDarkroomTargetEdit(
                context,
                (edits) => edits.assign(frames, row),
              ),
            ),
          ),
        );
      }
    } else if (!t.isProject) {
      final hidden = t.placement == TargetPlacement.hidden;
      banners.add(
        SkotiqBanner(
          key: const ValueKey('darkroom_other_reason'),
          title: hidden
              ? 'You moved this to Other captures.'
              : 'Not a project yet: ${t.otherReason.toLowerCase()}.',
          message: hidden
              ? 'It stays there until you list it as a project.'
              : 'It moves to the projects by itself once it has at least '
                  '${_minutes(t.rule.minKeptMinutes)} of kept light and '
                  '${t.rule.minKeptFrames} kept lights.',
          action: SkotiqButton(
            key: const ValueKey('darkroom_list_as_project'),
            label: 'List as a project',
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            onPressed: () => darkroomPlaceTarget(context, ref, t, true),
          ),
        ),
      );
    }
    if (t.identified) {
      for (final other in darkroomTargetsNearby(t, all).take(1)) {
        banners.add(
          SkotiqBanner(
            key: ValueKey('darkroom_same_position_${other.key}'),
            title: '${other.key} is at the same position.',
            message: 'If the two are one object under two names, merge '
                '${other.key} into ${t.key}.',
            action: SkotiqButton(
              label: 'Merge into ${t.key}',
              size: ButtonSize.small,
              variant: ButtonVariant.secondary,
              onPressed: () => applyDarkroomTargetEdit(
                context,
                (edits) =>
                    edits.merge(darkroomGroupOf(other), darkroomGroupOf(t)),
                undoGoTo: t.key,
              ),
            ),
          ),
        );
      }
    }
    if (banners.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, b) in banners.indexed) ...[
            if (i > 0) const SizedBox(height: SkotiqTokens.spaceSm),
            b,
          ],
        ],
      ),
    );
  }

  /// Saved targets [frames] were plate-solved on, with the lights on each,
  /// the target holding most lights first.
  static List<(DbTarget, List<DbCapturedImage>)> _fieldsOf(
    List<DbCapturedImage> frames,
    List<DbTarget> rows,
  ) {
    final byRow = <int, (DbTarget, List<DbCapturedImage>)>{};
    for (final f in frames) {
      for (final row in darkroomTargetsAt(f, rows)) {
        byRow.putIfAbsent(row.id, () => (row, [])).$2.add(f);
      }
    }
    return byRow.values.toList()
      ..sort((a, b) => b.$2.length.compareTo(a.$2.length));
  }
}

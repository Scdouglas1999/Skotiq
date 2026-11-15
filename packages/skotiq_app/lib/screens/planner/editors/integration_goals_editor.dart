import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';

/// The integration-goals editor for one target in a dialog, offering the
/// active profile's filters. Plan > Projects and Analytics > Projects open it,
/// so a goal set in one is the goal the other shows.
Future<void> showIntegrationGoalsDialog(
  BuildContext context,
  WidgetRef ref, {
  required int targetId,
  required String targetName,
}) {
  final profile = ref.read(activeEquipmentProfileProvider);
  return showDialog<void>(
    context: context,
    builder: (_) => SkotiqDialog(
      title: 'Goals for $targetName',
      width: 640,
      child: IntegrationGoalsEditor(
        targetId: targetId,
        targetName: targetName,
        availableFilters: profile != null
            ? List<String>.from(profile.filterNames)
            : const <String>[],
      ),
    ),
  );
}

/// Per-target integration-goals editor.
///
/// One row per existing goal (filter, exposure seconds, frame count,
/// priority, captured-count read-only) plus an "Add filter" footer that
/// inserts a new goal. Persists immediately through
/// [IntegrationGoalService] (no Save button); the engine's
/// candidatesUpdated trigger is fired by the calling screen so the
/// scheduler re-evaluates with fresh integration targets.
class IntegrationGoalsEditor extends ConsumerStatefulWidget {
  final int targetId;
  final String targetName;
  final List<String> availableFilters;

  const IntegrationGoalsEditor({
    super.key,
    required this.targetId,
    required this.targetName,
    required this.availableFilters,
  });

  @override
  ConsumerState<IntegrationGoalsEditor> createState() =>
      _IntegrationGoalsEditorState();
}

class _IntegrationGoalsEditorState
    extends ConsumerState<IntegrationGoalsEditor> {
  bool _busy = false;
  int _operationGeneration = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous != null && !identical(previous, next)) {
          _retireOperation();
        }
      },
    );
  }

  @override
  void didUpdateWidget(IntegrationGoalsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetId != widget.targetId) _retireOperation();
  }

  @override
  void dispose() {
    _operationGeneration++;
    _backendSubscription?.close();
    super.dispose();
  }

  void _retireOperation() {
    _operationGeneration++;
    if (mounted && _busy) setState(() => _busy = false);
  }

  Future<bool> _addGoal({
    required String filter,
    required double exposureSeconds,
    required int frameCount,
    required int priority,
    required SkotiqBackend authority,
    required IntegrationGoalService service,
  }) async {
    if (_busy) return false;
    if (!_isCurrentAuthority(authority)) {
      _showAuthorityChanged();
      return false;
    }
    final targetId = widget.targetId;
    final operationGeneration = ++_operationGeneration;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await service.upsert(IntegrationGoal(
        targetId: targetId,
        filter: filter,
        exposureSeconds: exposureSeconds,
        frameCount: frameCount,
        priority: priority,
        createdAt: DateTime.now().toUtc(),
      ));
      if (!_isCurrentOperation(
        authority,
        targetId,
        operationGeneration,
      )) {
        return false;
      }
      ref.invalidate(integrationGoalProgressProvider(targetId));
      ref.invalidate(allIntegrationGoalsProvider);
      return true;
    } catch (e) {
      if (_isCurrentOperation(authority, targetId, operationGeneration)) {
        messenger
            .showErrorSnackBar('Failed to add goal: ${userFacingError(e)}');
      }
      return false;
    } finally {
      if (_isCurrentOperation(authority, targetId, operationGeneration)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _updateGoal(IntegrationGoal goal,
      {required int frameCount,
      required int priority,
      required SkotiqBackend authority,
      required IntegrationGoalService service}) async {
    if (_busy) return;
    if (goal.id == null) {
      throw StateError('Cannot update an unsaved integration goal');
    }
    if (!_isCurrentAuthority(authority)) {
      _showAuthorityChanged();
      return;
    }
    final targetId = widget.targetId;
    final operationGeneration = ++_operationGeneration;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await service.upsert(goal.copyWith(
        frameCount: frameCount,
        priority: priority,
      ));
      if (!_isCurrentOperation(
        authority,
        targetId,
        operationGeneration,
      )) {
        return;
      }
      ref.invalidate(integrationGoalProgressProvider(targetId));
      ref.invalidate(allIntegrationGoalsProvider);
    } catch (e) {
      if (_isCurrentOperation(authority, targetId, operationGeneration)) {
        messenger
            .showErrorSnackBar('Failed to update goal: ${userFacingError(e)}');
      }
    } finally {
      if (_isCurrentOperation(authority, targetId, operationGeneration)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _deleteGoal(
    IntegrationGoal goal,
    SkotiqBackend authority,
    IntegrationGoalService service,
  ) async {
    if (_busy) return;
    if (goal.id == null) return;
    if (!_isCurrentAuthority(authority)) {
      _showAuthorityChanged();
      return;
    }
    final targetId = widget.targetId;
    final operationGeneration = ++_operationGeneration;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await service.delete(goal.id!);
      if (!_isCurrentOperation(
        authority,
        targetId,
        operationGeneration,
      )) {
        return;
      }
      ref.invalidate(integrationGoalProgressProvider(targetId));
      ref.invalidate(allIntegrationGoalsProvider);
    } catch (e) {
      if (_isCurrentOperation(authority, targetId, operationGeneration)) {
        messenger
            .showErrorSnackBar('Failed to delete goal: ${userFacingError(e)}');
      }
    } finally {
      if (_isCurrentOperation(authority, targetId, operationGeneration)) {
        setState(() => _busy = false);
      }
    }
  }

  bool _isCurrentAuthority(SkotiqBackend authority) =>
      mounted && ref.backendScopeOver(authority).isCurrent;

  bool _isCurrentOperation(
    SkotiqBackend authority,
    int targetId,
    int operationGeneration,
  ) =>
      operationGeneration == _operationGeneration &&
      widget.targetId == targetId &&
      _isCurrentAuthority(authority);

  void _showAuthorityChanged() {
    if (!mounted) return;
    _showGoalError(
      context,
      'The imaging host changed. Reopen the integration-goal editor.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final progressAsync =
        ref.watch(integrationGoalProgressProvider(widget.targetId));
    final exposureContext =
        ref.watch(smartNightExposureContextProvider).valueOrNull;
    final authority = ref.watch(backendProvider);
    final service = ref.watch(integrationGoalServiceProvider);
    // An empty filter list is the normal state of an OSC / DSLR / wheel-less
    // rig, and Smart Night already plans a single unfiltered row for it
    // (plan_tonight_sequencer_helper.dart). Only a wheel that IS connected and
    // still reports no slots is a real fault, and only that case may refuse to
    // let the operator set a goal — otherwise the scheduler can never be given
    // a target on a rig that has no wheel at all.
    //
    // Watched only in that branch: the wheel provider drags the live device /
    // profile graph in behind it, and a profile that already names filters has
    // no question to answer.
    final oldTotalGoalSecs = ref
            .watch(allDbTargetsProvider)
            .valueOrNull
            ?.where((t) => t.id == widget.targetId)
            .firstOrNull
            ?.goalIntegrationSecs ??
        0.0;
    final wheelOnlineWithNoSlots = widget.availableFilters.isEmpty &&
        ref.watch(filterWheelStateProvider).connectionState ==
            DeviceConnectionState.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              'Goals',
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                'frames wanted in each filter',
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
              ),
            ),
            if (_busy)
              SizedBox(
                width: SkotiqTokens.iconSm,
                height: SkotiqTokens.iconSm,
                child: SkotiqSpinner(
                  size: SkotiqTokens.iconSm,
                  color: colors.textMuted,
                ),
              ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        progressAsync.when(
          loading: () => const Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
            child: const SizedBox(
              width: 18,
              height: 18,
              child:
                  const SkotiqMark(motion: SkotiqMarkMotion.loading, size: 18),
            ),
          ),
          error: (e, _) => Text(
            'Could not load the goals: ${userFacingError(e)}',
            style: SkotiqTypography.bodySm.copyWith(color: colors.error),
          ),
          data: (progress) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (progress.isEmpty && oldTotalGoalSecs > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
                  child: Text(
                    'Current goal: ${DurationFormat.decimalHours(oldTotalGoalSecs)} '
                    'over all filters. Adding a filter goal below replaces it.',
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textSecondary),
                  ),
                )
              else if (progress.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
                  child: Text(
                    'No goal yet. Add a filter to tell the autopilot how much '
                    'to collect.',
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textMuted),
                  ),
                ),
              for (final p in progress)
                _GoalRow(
                  progress: p,
                  onUpdate: (count, priority) => _updateGoal(p.goal,
                      frameCount: count,
                      priority: priority,
                      authority: authority,
                      service: service),
                  onDelete: () => _deleteGoal(p.goal, authority, service),
                  busy: _busy,
                ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              _AddGoalRow(
                availableFilters: widget.availableFilters,
                wheelOnlineWithNoSlots: wheelOnlineWithNoSlots,
                existingFilters: progress.map((p) => p.goal.filter).toSet(),
                exposureContext: exposureContext,
                onAdd: ({
                  required filter,
                  required exposureSeconds,
                  required frameCount,
                  required priority,
                }) =>
                    _addGoal(
                  filter: filter,
                  exposureSeconds: exposureSeconds,
                  frameCount: frameCount,
                  priority: priority,
                  authority: authority,
                  service: service,
                ),
                busy: _busy,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GoalRow extends StatefulWidget {
  final IntegrationGoalProgress progress;
  final Future<void> Function(int frameCount, int priority) onUpdate;
  final Future<void> Function() onDelete;
  final bool busy;

  const _GoalRow({
    required this.progress,
    required this.onUpdate,
    required this.onDelete,
    required this.busy,
  });

  @override
  State<_GoalRow> createState() => _GoalRowState();
}

class _GoalRowState extends State<_GoalRow> {
  late final TextEditingController _countCtl;
  late final TextEditingController _priorityCtl;

  @override
  void initState() {
    super.initState();
    _countCtl =
        TextEditingController(text: widget.progress.goal.frameCount.toString());
    _priorityCtl =
        TextEditingController(text: widget.progress.goal.priority.toString());
  }

  @override
  void didUpdateWidget(_GoalRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress.goal != widget.progress.goal) {
      _countCtl.text = widget.progress.goal.frameCount.toString();
      _priorityCtl.text = widget.progress.goal.priority.toString();
    }
  }

  @override
  void dispose() {
    _countCtl.dispose();
    _priorityCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final p = widget.progress;
    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textMuted);
    final frames = SizedBox(
      width: _kGoalNumberWidth,
      child: SkotiqTextField(
        controller: _countCtl,
        enabled: !widget.busy,
        dense: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.right,
        onSubmitted: (v) {
          final parsed = int.tryParse(v.trim());
          if (parsed == null || parsed < 1) {
            _countCtl.text = p.goal.frameCount.toString();
            _showGoalError(context, 'Frame count must be a positive integer.');
            return;
          }
          widget.onUpdate(parsed, p.goal.priority);
        },
      ),
    );
    final priority = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Priority', style: muted),
        const SizedBox(width: SkotiqTokens.spaceSm),
        SizedBox(
          width: _kGoalPriorityWidth,
          child: SkotiqTextField(
            controller: _priorityCtl,
            enabled: !widget.busy,
            dense: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.right,
            onSubmitted: (v) {
              final parsed = int.tryParse(v.trim());
              if (parsed == null) {
                _priorityCtl.text = p.goal.priority.toString();
                _showGoalError(context, 'Priority must be an integer.');
                return;
              }
              widget.onUpdate(p.goal.frameCount, parsed);
            },
          ),
        ),
      ],
    );
    final progress = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${p.capturedCount} / ${p.goal.frameCount} captured',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.bodySm.copyWith(
              color: p.isComplete ? colors.success : colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          SkotiqProgressBar(
            value: p.goal.frameCount > 0
                ? (p.capturedCount / p.goal.frameCount).clamp(0.0, 1.0)
                : 0.0,
            state: p.isComplete
                ? SkotiqProgressState.success
                : SkotiqProgressState.normal,
          ),
        ],
      ),
    );
    final delete = SkotiqIconButton(
      icon: LucideIcons.trash2,
      tooltip: 'Delete goal',
      size: IconButtonSize.sm,
      onPressed: widget.busy ? null : () => widget.onDelete(),
    );
    final head = [
      SizedBox(
        width: _kGoalFilterWidth,
        child: Text(
          _goalFilterLabel(p.goal.filter),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              SkotiqTypography.bodyStrong.copyWith(color: colors.textPrimary),
        ),
      ),
      Text('${QuantityFormat.trimmed(p.goal.exposureSeconds)} s ×', style: muted),
      const SizedBox(width: SkotiqTokens.spaceSm),
      frames,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= _kGoalRowInlineWidth) {
            return Row(
              children: [
                ...head,
                const SizedBox(width: SkotiqTokens.spaceLg),
                priority,
                const SizedBox(width: SkotiqTokens.spaceLg),
                progress,
                const SizedBox(width: SkotiqTokens.spaceSm),
                delete,
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ...head,
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  progress,
                  const SizedBox(width: SkotiqTokens.spaceXs),
                  delete,
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              Padding(
                padding: const EdgeInsets.only(left: _kGoalFilterWidth),
                child: priority,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Widths of a goal row's fixed parts.
const double _kGoalFilterWidth = 48;
const double _kGoalNumberWidth = 64;
const double _kGoalPriorityWidth = 48;

const double _kGoalRowInlineWidth = 520;

class _AddGoalRow extends StatefulWidget {
  final List<String> availableFilters;

  /// True only for the real fault: a filter wheel is connected and still
  /// reports zero slots. A rig with no wheel at all is NOT this case.
  final bool wheelOnlineWithNoSlots;
  final Set<String> existingFilters;
  final SmartNightExposureContext? exposureContext;
  final Future<bool> Function({
    required String filter,
    required double exposureSeconds,
    required int frameCount,
    required int priority,
  }) onAdd;
  final bool busy;

  const _AddGoalRow({
    required this.availableFilters,
    required this.wheelOnlineWithNoSlots,
    required this.existingFilters,
    required this.exposureContext,
    required this.onAdd,
    required this.busy,
  });

  @override
  State<_AddGoalRow> createState() => _AddGoalRowState();
}

class _AddGoalRowState extends State<_AddGoalRow> {
  String? _selectedFilter;
  final _exposureCtl = TextEditingController(text: '180');
  final _frameCtl = TextEditingController(text: '20');
  final _priorityCtl = TextEditingController(text: '5');

  @override
  void dispose() {
    _exposureCtl.dispose();
    _frameCtl.dispose();
    _priorityCtl.dispose();
    super.dispose();
  }

  bool get _canAdd =>
      _selectedFilter != null &&
      !widget.existingFilters.any((f) =>
          f.trim().toLowerCase() == _selectedFilter!.trim().toLowerCase());

  void _selectFilter(String? filter) {
    setState(() {
      _selectedFilter = filter;
      final seconds =
          widget.exposureContext?.recommendForFilter(filter).seconds;
      if (seconds != null && seconds.isFinite && seconds > 0) {
        _exposureCtl.text = QuantityFormat.trimmed(seconds);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final unfilteredRig = widget.availableFilters.isEmpty;
    // A wheel-less rig gets exactly one selectable slot: the unfiltered
    // sentinel Smart Night already plans against, so a goal created here and a
    // sequence built by Smart Night describe the same frames.
    final selectable = unfilteredRig
        ? const [smartNightUnfilteredName]
        : widget.availableFilters;
    final remaining = selectable
        .where((f) => !widget.existingFilters.any((existing) =>
            existing.trim().toLowerCase() == f.trim().toLowerCase()))
        .toList();

    if (widget.wheelOnlineWithNoSlots) {
      return Text(
        'The connected filter wheel reports no filter slots. Reconnect the '
        'wheel or name its filters on the equipment profile before setting '
        'integration goals.',
        style: SkotiqTypography.bodySm.copyWith(color: colors.warning),
      );
    }
    if (remaining.isEmpty) {
      return Text(
        unfilteredRig
            ? 'This rig images unfiltered and already has its goal.'
            : 'Every filter in the active equipment profile has a goal.',
        style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
      );
    }

    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textMuted);
    final filter = SkotiqDropdown(
      value: _selectedFilter,
      hint: 'Filter',
      items: remaining,
      itemLabels: [for (final f in remaining) _goalFilterLabel(f)],
      isExpanded: true,
      onChanged: widget.busy ? null : _selectFilter,
    );
    Widget field(TextEditingController controller, {String? suffix}) =>
        SkotiqTextField(
          controller: controller,
          enabled: !widget.busy,
          dense: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.right,
          suffix: suffix,
        );
    final add = SkotiqButton(
      label: 'Add',
      icon: LucideIcons.plus,
      size: ButtonSize.small,
      variant: ButtonVariant.secondary,
      onPressed: widget.busy || !_canAdd ? null : _submit,
    );
    final exposure = SizedBox(
      width: 80,
      child: field(_exposureCtl, suffix: 's'),
    );
    final frames =
        SizedBox(width: _kGoalNumberWidth, child: field(_frameCtl));
    final priority = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Priority', style: muted),
        const SizedBox(width: SkotiqTokens.spaceSm),
        SizedBox(width: _kGoalPriorityWidth, child: field(_priorityCtl)),
      ],
    );
    final times = Padding(
      padding: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceSm),
      child: Text('×', style: muted),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _kGoalRowInlineWidth) {
          return Row(
            children: [
              SizedBox(width: 120, child: filter),
              const SizedBox(width: SkotiqTokens.spaceSm),
              exposure,
              times,
              frames,
              const SizedBox(width: SkotiqTokens.spaceLg),
              priority,
              const Spacer(),
              add,
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: filter),
                const SizedBox(width: SkotiqTokens.spaceSm),
                exposure,
                times,
                frames,
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Row(children: [priority, const Spacer(), add]),
          ],
        );
      },
    );
  }

  Future<void> _submit() async {
    final exposure = double.tryParse(_exposureCtl.text.trim());
    final frames = int.tryParse(_frameCtl.text.trim());
    final priority = int.tryParse(_priorityCtl.text.trim());
    if (exposure == null || exposure <= 0) {
      _showGoalError(context, 'Exposure seconds must be a positive number.');
      return;
    }
    if (frames == null || frames < 1) {
      _showGoalError(context, 'Frame count must be at least 1.');
      return;
    }
    if (priority == null) {
      _showGoalError(context, 'Priority must be an integer.');
      return;
    }
    final selectedFilter = _selectedFilter;
    if (selectedFilter == null) return;
    final added = await widget.onAdd(
      filter: selectedFilter,
      exposureSeconds: exposure,
      frameCount: frames,
      priority: priority,
    );
    if (mounted && added) _selectFilter(null);
  }
}

/// Display name for a goal's filter, spelling the unfiltered sentinel out.
///
/// [smartNightUnfilteredName] is the empty string — the wire contract for
/// "capture the frame as it comes" — so rendering `goal.filter` verbatim leaves
/// a blank cell that reads as a layout bug. 'No filter' matches the chip the
/// Recommendation card already renders for the same rig.
String _goalFilterLabel(String filter) =>
    filter.trim().isEmpty ? 'No filter' : filter;

void _showGoalError(BuildContext context, String message) =>
    context.showErrorSnackBar(message);

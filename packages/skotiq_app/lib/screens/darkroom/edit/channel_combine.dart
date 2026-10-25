/// Combining a target's per-filter masters into one color recipe.
///
/// The operation registry plans the combination: it reads each master's filter,
/// picks a palette (LRGB, RGB, HaRGB, SHO, HOO and the rest), registers every
/// master onto a reference and drafts a recipe whose first step is
/// `channel_combine@1`. The recipe renders over the reference master and reads
/// the others as sources, so nothing is written to disk until an export.
///
/// This is the general form of the session review's narrowband mixer: the same
/// masters, any palette the filters allow, and the result opens in the editor
/// like any other recipe, with every later step adjustable.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../darkroom_controller.dart';
import 'darkroom_image_library.dart';

/// A palette the plan offered.
class DarkroomCombinePalette {
  /// The wire token the registry takes back (`lrgb`, `sho`, ...).
  final String id;

  /// Its name in words (`LRGB`, `SHO (Hubble palette)`).
  final String name;

  const DarkroomCombinePalette({required this.id, required this.name});
}

/// A master the plan left out, with the reason.
class DarkroomCombineExclusion {
  final String path;
  final String? filter;
  final String reason;

  const DarkroomCombineExclusion({
    required this.path,
    required this.filter,
    required this.reason,
  });
}

/// What the registry answered for one set of masters.
class DarkroomCombinePlan {
  /// True when the masters combine; [steps] is the drafted recipe then.
  final bool combined;

  /// The palette chosen, or null when the masters do not combine.
  final DarkroomCombinePalette? palette;

  /// Why this palette, or why none, in the registry's words.
  final String reason;

  /// The other palettes the same masters allow.
  final List<DarkroomCombinePalette> alternatives;

  final List<DarkroomCombineExclusion> excluded;

  /// The master every other is registered onto; the recipe's base.
  final String? referencePath;

  /// The largest median star offset the registration check measured between a
  /// master and the reference, in pixels.
  final double? worstOffsetPx;

  final List<DarkroomStep> steps;
  final List<RecipeDraftNote> notes;

  const DarkroomCombinePlan({
    required this.combined,
    required this.palette,
    required this.reason,
    required this.alternatives,
    required this.excluded,
    required this.referencePath,
    required this.worstOffsetPx,
    required this.steps,
    required this.notes,
  });

  /// Read the registry's reply to a composite request.
  ///
  /// Throws [DarkroomRecipeFormatException] when the reply carries no plan, or
  /// says the masters combine and carries no draft.
  factory DarkroomCombinePlan.fromReply(Map<String, dynamic> reply) {
    final plan = reply['composite'];
    if (plan is! Map<String, dynamic>) {
      throw const DarkroomRecipeFormatException(
        'The registry answered the combine request without a plan.',
      );
    }
    final alternatives = [
      for (final alt in (plan['alternatives'] as List? ?? const []))
        if (alt is Map && alt['palette'] is String)
          DarkroomCombinePalette(
            id: alt['palette'] as String,
            name: (alt['name'] as String?) ?? alt['palette'] as String,
          ),
    ];
    final excluded = [
      for (final entry in (plan['excluded'] as List? ?? const []))
        if (entry is Map)
          DarkroomCombineExclusion(
            path: '${entry['path']}',
            filter: entry['filter'] as String?,
            reason: '${entry['reason']}',
          ),
    ];
    final reason = (plan['reason'] as String?) ?? '';
    if (plan['combined'] != true) {
      return DarkroomCombinePlan(
        combined: false,
        palette: null,
        reason: reason,
        alternatives: alternatives,
        excluded: excluded,
        referencePath: null,
        worstOffsetPx: null,
        steps: const [],
        notes: const [],
      );
    }
    final referencePath = reply['masterPath'];
    if (referencePath is! String) {
      throw const DarkroomRecipeFormatException(
        'The registry planned a combination but named no reference master to '
        'render it over.',
      );
    }
    final steps = decodeDarkroomDraft(reply);
    return DarkroomCombinePlan(
      combined: true,
      palette: DarkroomCombinePalette(
        id: '${plan['palette']}',
        name: (plan['paletteName'] as String?) ?? '${plan['palette']}',
      ),
      reason: reason,
      alternatives: alternatives,
      excluded: excluded,
      referencePath: referencePath,
      worstOffsetPx: (plan['worstMedianOffsetPx'] as num?)?.toDouble(),
      steps: steps,
      notes: darkroomComposedAccount(steps, decodeDarkroomDraftNotes(reply)),
    );
  }
}

/// Plans a combination and writes it as a recipe.
class DarkroomChannelCombiner {
  final DarkroomSeam _darkroom;
  final RecipesDao _recipes;

  const DarkroomChannelCombiner({
    required DarkroomSeam darkroom,
    required RecipesDao recipes,
  })  : _darkroom = darkroom,
        _recipes = recipes;

  /// Ask the registry to plan [masters] as one color image, in [palette] when
  /// one is named and in the conventional palette for the filters otherwise.
  Future<DarkroomCombinePlan> plan(
    List<IntegratedMaster> masters, {
    String? palette,
  }) async {
    final reply = await _darkroom.registry({
      'composite': {
        'inputs': [
          for (final master in masters)
            {
              'path': master.masterFitsPath,
              if (master.filter != null) 'filter': master.filter,
              'integrationSeconds': master.totalIntegrationSeconds,
            },
        ],
        if (palette != null) 'palette': palette,
      },
    });
    return DarkroomCombinePlan.fromReply(reply);
  }

  /// Write [plan] as a new recipe over its reference master and return the
  /// recipe's id.
  Future<int> save(
    DarkroomCombinePlan plan, {
    required String target,
    required List<IntegratedMaster> masters,
  }) async {
    final referencePath = plan.referencePath;
    if (!plan.combined || referencePath == null) {
      throw StateError('These masters do not combine: ${plan.reason}');
    }
    final reference =
        masters.where((m) => m.masterFitsPath == referencePath).firstOrNull;
    return _recipes.create(
      targetId: reference?.targetId,
      masterId: reference?.id,
      baseMasterPath: referencePath,
      name: '$target ${plan.palette?.name ?? 'color'} combine',
      stepsJson: jsonEncode([for (final step in plan.steps) step.toJson()]),
      createdBy: RecipeAuthor.user,
      draftNotes: plan.notes,
      schemaVersion: kDarkroomRecipeSchemaVersion,
    );
  }
}

final darkroomChannelCombinerProvider = Provider<DarkroomChannelCombiner>(
  (ref) => DarkroomChannelCombiner(
    darkroom: ref.watch(darkroomSeamProvider),
    recipes: ref.watch(recipesDaoProvider),
  ),
);

/// Open the combine dialog over [targets] and return the id of the recipe it
/// wrote, or null when the operator closed it first.
Future<int?> showDarkroomChannelCombineDialog(
  BuildContext context, {
  required List<DarkroomLibraryTarget> targets,
  String? initialTarget,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => DarkroomChannelCombineDialog(
      targets: targets,
      initialTarget: initialTarget,
    ),
  );
}

/// The targets that have at least two per-filter masters to combine.
List<DarkroomLibraryTarget> darkroomCombinableTargets(
  List<DarkroomLibraryTarget> targets,
) =>
    [
      for (final target in targets)
        if (target.channelMasters.length >= 2) target,
    ];

/// Choose a target's masters and a palette, see the plan, open it as a recipe.
class DarkroomChannelCombineDialog extends ConsumerStatefulWidget {
  final List<DarkroomLibraryTarget> targets;
  final String? initialTarget;

  const DarkroomChannelCombineDialog({
    super.key,
    required this.targets,
    this.initialTarget,
  });

  @override
  ConsumerState<DarkroomChannelCombineDialog> createState() =>
      _DarkroomChannelCombineDialogState();
}

class _DarkroomChannelCombineDialogState
    extends ConsumerState<DarkroomChannelCombineDialog> {
  late List<DarkroomLibraryTarget> _targets;
  DarkroomLibraryTarget? _target;
  final Set<int> _selected = {};

  /// The palette the operator picked, or null for the registry's own choice.
  String? _palette;

  DarkroomCombinePlan? _plan;

  /// The selection and palette [_plan] answers, so a changed selection is
  /// planned again before it is saved.
  String? _plannedKey;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _targets = darkroomCombinableTargets(widget.targets);
    _target =
        _targets.where((t) => t.name == widget.initialTarget).firstOrNull ??
            _targets.firstOrNull;
    _selectAll();
  }

  void _selectAll() {
    _selected
      ..clear()
      ..addAll(
          [for (final i in _target?.channelMasters ?? const []) i.master.id]);
  }

  List<IntegratedMaster> get _masters => [
        for (final image in _target?.channelMasters ?? const [])
          if (_selected.contains(image.master.id)) image.master,
      ];

  String get _key =>
      '${_target?.name}|${(_selected.toList()..sort()).join(',')}|$_palette';

  Future<void> _runPlan() async {
    final masters = _masters;
    if (masters.length < 2 || _busy) return;
    final key = _key;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final plan = await ref
          .read(darkroomChannelCombinerProvider)
          .plan(masters, palette: _palette);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _plannedKey = key;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'The masters could not be planned as one color image: '
            '${error is DarkroomSeamException ? error.message : error}';
      });
    }
  }

  Future<void> _open() async {
    final plan = _plan;
    final target = _target;
    if (plan == null || target == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await ref.read(darkroomChannelCombinerProvider).save(
            plan,
            target: target.name,
            masters: _masters,
          );
      if (!mounted) return;
      Navigator.of(context).pop(id);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'The combined recipe could not be written: $error';
      });
    }
  }

  void _changed(VoidCallback change) {
    setState(() {
      change();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final plan = _plannedKey == _key ? _plan : null;
    final canOpen = plan != null && plan.combined && !_busy;
    return SkotiqDialog(
      title: 'Combine channels',
      icon: SkotiqIcons.layers,
      width: 600,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (plan == null)
          SkotiqButton(
            key: const ValueKey('darkroom_combine_plan'),
            label: _busy ? 'Planning…' : 'Plan the combination',
            icon: SkotiqIcons.layers,
            size: ButtonSize.small,
            isLoading: _busy,
            onPressed: _masters.length < 2 || _busy ? null : _runPlan,
          )
        else
          SkotiqButton(
            key: const ValueKey('darkroom_combine_open'),
            label: 'Open in the editor',
            icon: SkotiqIcons.edit,
            size: ButtonSize.small,
            isLoading: _busy,
            onPressed: canOpen ? _open : null,
          ),
      ],
      child: _targets.isEmpty
          ? Text(
              'No target has two or more per-filter masters yet. Build masters '
              'for a target from the Targets tab, then combine them here.',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'The masters are registered onto one another and combined '
                  'as the first step of a new recipe. The rest of the draft '
                  'is measured from the combined image and every step stays '
                  'adjustable. The masters on disk are not changed.',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
                if (_targets.length > 1) ...[
                  Text(
                    'TARGET',
                    style: kDarkroomOverline.copyWith(color: colors.textMuted),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Wrap(
                    spacing: SkotiqTokens.spaceXs,
                    runSpacing: SkotiqTokens.spaceXs,
                    children: [
                      for (final t in _targets)
                        SkotiqChip(
                          label: t.name,
                          selected: t.name == _target?.name,
                          onTap: _busy
                              ? null
                              : () => _changed(() {
                                    _target = t;
                                    _palette = null;
                                    _plan = null;
                                    _selectAll();
                                  }),
                        ),
                    ],
                  ),
                  const SizedBox(height: SkotiqTokens.spaceMd),
                ],
                Text(
                  'MASTERS',
                  style: kDarkroomOverline.copyWith(color: colors.textMuted),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                for (final image in _target?.channelMasters ?? const [])
                  _masterRow(colors, image),
                const SizedBox(height: SkotiqTokens.spaceMd),
                Text(
                  'PALETTE',
                  style: kDarkroomOverline.copyWith(color: colors.textMuted),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                _palettes(),
                if (_error != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  SkotiqBanner(
                    key: const ValueKey('darkroom_combine_error'),
                    title: 'Not combined',
                    tone: BannerTone.error,
                    message: _error!,
                  ),
                ],
                if (plan != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  _planSummary(colors, plan),
                ],
              ],
            ),
    );
  }

  Widget _masterRow(SkotiqColors colors, DarkroomLibraryImage image) {
    final master = image.master;
    final checked = _selected.contains(master.id);
    return Semantics(
      container: true,
      checked: checked,
      label: '${image.kind} master, ${master.frameCount} frames, '
          '${describeIntegration(master.totalIntegrationSeconds)}',
      excludeSemantics: true,
      onTap: _busy ? null : () => _toggle(master.id),
      child: InkWell(
        onTap: _busy ? null : () => _toggle(master.id),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
          child: Row(
            children: [
              SkotiqCheckbox(
                value: checked,
                onChanged: _busy ? null : (_) => _toggle(master.id),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              SizedBox(
                width: 56,
                child: Text(
                  image.kind,
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  p.basename(master.masterFitsPath ?? master.name),
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                '${master.frameCount} frames · '
                '${describeIntegration(master.totalIntegrationSeconds)}',
                style: SkotiqTypography.monoXs.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggle(int id) => _changed(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  /// The palettes on offer: the registry's own choice, and once a plan has
  /// answered, the alternatives it said these masters allow. Taken from the
  /// last plan even after the selection changed, so picking an alternative
  /// does not take the other choices off the screen.
  Widget _palettes() {
    final offered = <String, DarkroomCombinePalette>{
      if (_plan?.palette != null) _plan!.palette!.id: _plan!.palette!,
      for (final alt in _plan?.alternatives ?? const <DarkroomCombinePalette>[])
        alt.id: alt,
    };
    return Wrap(
      spacing: SkotiqTokens.spaceXs,
      runSpacing: SkotiqTokens.spaceXs,
      children: [
        SkotiqChip(
          label: 'Chosen from the filters',
          selected: _palette == null,
          onTap: _busy ? null : () => _changed(() => _palette = null),
        ),
        for (final option in offered.values)
          SkotiqChip(
            label: option.name,
            selected: _palette == option.id,
            onTap: _busy ? null : () => _changed(() => _palette = option.id),
          ),
      ],
    );
  }

  Widget _planSummary(SkotiqColors colors, DarkroomCombinePlan plan) {
    final lines = <String>[
      plan.reason,
      if (plan.referencePath != null)
        'Registered onto ${p.basename(plan.referencePath!)}.',
      if (plan.worstOffsetPx != null)
        'Largest star offset after registration: '
            '${plan.worstOffsetPx!.toStringAsFixed(2)} px.',
      for (final e in plan.excluded)
        'Left out ${e.filter ?? p.basename(e.path)}: ${e.reason}',
      if (plan.combined)
        'The draft has ${plan.steps.length} step'
            '${plan.steps.length == 1 ? '' : 's'}.',
    ];
    return SkotiqBanner(
      key: const ValueKey('darkroom_combine_plan_summary'),
      title: plan.combined
          ? 'Combines as ${plan.palette?.name ?? 'color'}'
          : 'These masters do not combine',
      tone: plan.combined ? BannerTone.success : BannerTone.warning,
      message: lines.where((l) => l.trim().isNotEmpty).join('\n'),
    );
  }
}

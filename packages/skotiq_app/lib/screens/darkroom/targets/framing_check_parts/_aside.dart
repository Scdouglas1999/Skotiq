part of '../framing_check.dart';

class _Aside extends ConsumerWidget {
  const _Aside({
    required this.target,
    required this.job,
    required this.session,
    required this.limiting,
    required this.byPath,
    required this.busy,
    required this.error,
    required this.onHighlight,
    required this.onLeaveOut,
    required this.onBuild,
    required this.onDismissError,
  });

  final DarkroomTarget target;
  final DarkroomBuildJob job;
  final DarkroomFramingSession session;
  final List<DarkroomLimitingFrame> limiting;
  final Map<String, DbCapturedImage> byPath;
  final bool busy;
  final String? error;
  final ValueChanged<String?> onHighlight;
  final void Function(DarkroomFramingSession, Map<String, String>) onLeaveOut;
  final VoidCallback onBuild;
  final VoidCallback onDismissError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final preview = job.preview!;
    final plan = job.plan!;
    final planJson = plan.toJson();
    final noFlat = [
      ...?(planJson['noFlatFilters'] as List?)?.cast<String>(),
    ];
    final partialFlat = <String>{
      for (final g in planJson['groups'] as List)
        if ((g as Map)['calibration']?['flat'] == null) g['filter'] as String,
    }.where((f) => !noFlat.contains(f)).toList()
      ..sort(compareDarkroomFilters);
    final missingFlats = [...noFlat, ...partialFlat]
      ..sort(compareDarkroomFilters);
    final needsAck = missingFlats.isNotEmpty && !session.withoutFlats;
    final belowMinimum = !preview.meetsMinimum;
    final buildReason = busy
        ? 'Working.'
        : belowMinimum
            ? 'The kept field is below the '
                '${percent(preview.minRetainedArea, digits: 0)} minimum. '
                'Leave out the limiting subs or lower the minimum.'
            : needsAck
                ? 'Decide on the filters without a flat first.'
                : null;
    final included = preview.included.length;
    final autoLeftOut = preview.notIncluded.length;
    final summary = limiting.isEmpty
        ? 'of the field is covered by every sub.'
        : 'of the field is covered by every sub. '
            '${limiting.length == 1 ? 'One sub cuts' : '${limiting.length} subs cut'} '
            'the rest away.';
    final setSession =
        ref.read(darkroomFramingSessionProvider(target.key).notifier);
    final mono = SkotiqTypography.monoXs.copyWith(
      color: colors.textSecondary,
      letterSpacing: 1.3,
    );
    final retained = (preview.retainedArea * 100).toStringAsFixed(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              SkotiqTokens.space2xl,
              SkotiqTokens.spaceXl,
              SkotiqTokens.space2xl,
              SkotiqTokens.spaceLg,
            ),
            children: [
              if (error != null) ...[
                SkotiqBanner(
                  tone: BannerTone.error,
                  title: 'That did not work.',
                  message: error,
                  onDismiss: onDismissError,
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
              ],
              Text('FIELD KEPT', style: mono),
              const SizedBox(height: SkotiqTokens.spaceXs),
              Semantics(
                label: 'Field kept: $retained percent',
                excludeSemantics: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      retained,
                      key: const ValueKey('darkroom_field_kept'),
                      style: SkotiqTypography.heroFigure.copyWith(
                        color:
                            belowMinimum ? colors.warning : colors.textPrimary,
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceXs),
                    Text(
                      '%',
                      style: SkotiqTypography.display.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                summary,
                style: SkotiqTypography.body.copyWith(
                  color: colors.textPrimary.withValues(alpha: .85),
                ),
              ),
              if (belowMinimum) ...[
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  'That is below the '
                  '${percent(preview.minRetainedArea, digits: 0)} minimum '
                  'set for this build.',
                  style:
                      SkotiqTypography.bodySm.copyWith(color: colors.warning),
                ),
              ],
              const SizedBox(height: SkotiqTokens.spaceXl),
              if (limiting.isNotEmpty) ...[
                _LimitingCard(
                  total: limiting.length,
                  limiting: limiting.take(_limitingShown).toList(),
                  byPath: byPath,
                  busy: busy,
                  onHighlight: onHighlight,
                  onLeaveOut: (paths) => onLeaveOut(session, {
                    ...session.leftOut,
                    for (final path in paths) path: darkroomLeftOutReason,
                  }),
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
              ],
              for (final entry in session.leftOut.entries
                  .where((e) => e.value == darkroomLeftOutReason))
                Padding(
                  padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
                  child: _LeftOutRow(
                    name: p.basenameWithoutExtension(entry.key),
                    busy: busy,
                    onPutBack: () => onLeaveOut(session, {
                      for (final e in session.leftOut.entries)
                        if (e.key != entry.key) e.key: e.value,
                    }),
                  ),
                ),
              _NightsChooser(
                target: target,
                session: session,
                reference: plan.referencePath,
                busy: busy,
                onChanged: (leftOut) => onLeaveOut(session, leftOut),
              ),
              const SizedBox(height: SkotiqTokens.spaceLg),
              _SettingRow(
                label: 'Subs',
                value: '$included kept'
                    '${autoLeftOut == 0 ? '' : ', $autoLeftOut under the overlap limit'}',
              ),
              _SettingRow(
                label: 'Calibration',
                value: missingFlats.isEmpty
                    ? 'Dark, bias and flat for every filter'
                    : 'No flat for ${missingFlats.join(', ')}',
                tone: missingFlats.isEmpty ? null : colors.warning,
              ),
              const _SettingRow(
                label: 'Rejection',
                value: 'Chosen by sub count',
              ),
              const _SettingRow(
                label: 'Output',
                value: 'Linear master per filter, cropped to the common area',
              ),
              _FolderRow(session: session, targetKey: target.key, busy: busy),
              _Advanced(job: job, busy: busy),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SkotiqTokens.space2xl,
            SkotiqTokens.spaceSm,
            SkotiqTokens.space2xl,
            SkotiqTokens.spaceXl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (missingFlats.isNotEmpty) ...[
                _CheckRow(
                  key: const ValueKey('darkroom_without_flats'),
                  value: session.withoutFlats,
                  label: 'Build ${missingFlats.join(', ')} without flats. '
                      'Dust shadows and vignetting stay in.',
                  onChanged: busy
                      ? null
                      : (v) =>
                          setSession.state = session.copyWith(withoutFlats: v),
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
              ],
              Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: buildReason ??
                          'Build every filter in the '
                              'background.',
                      child: SkotiqButton(
                        key: const ValueKey('darkroom_framing_build'),
                        label: 'Build masters',
                        size: ButtonSize.large,
                        isLoading: busy,
                        onPressed: buildReason == null ? onBuild : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  SkotiqButton(
                    label: 'Back',
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.large,
                    onPressed: () =>
                        context.go(darkroomTargetLocation(target.key)),
                  ),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                buildReason != null && !busy
                    ? buildReason
                    : 'Builds run in the background. Follow along in '
                        'Activity.',
                style: SkotiqTypography.caption.copyWith(
                  color: buildReason != null && !busy
                      ? colors.warning
                      : colors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LimitingCard extends StatelessWidget {
  const _LimitingCard({
    required this.total,
    required this.limiting,
    required this.byPath,
    required this.busy,
    required this.onHighlight,
    required this.onLeaveOut,
  });

  /// Every limiting sub; [limiting] is the most limiting few.
  final int total;
  final List<DarkroomLimitingFrame> limiting;
  final Map<String, DbCapturedImage> byPath;
  final bool busy;
  final ValueChanged<String?> onHighlight;
  final ValueChanged<List<String>> onLeaveOut;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      key: const ValueKey('darkroom_limiting_card'),
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.borderHighlight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            total == 1
                ? 'One sub is holding it back'
                : '$total subs are holding it back',
            style: SkotiqTypography.bodyStrong.copyWith(
              color: colors.textPrimary,
            ),
          ),
          if (total > limiting.length)
            Text(
              'The ${limiting.length} that cost the most field:',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          for (final f in limiting)
            MouseRegion(
              onEnter: (_) => onHighlight(f.path),
              onExit: (_) => onHighlight(null),
              child: Padding(
                padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
                child: Row(
                  children: [
                    _SubThumb(image: byPath[f.path]),
                    const SizedBox(width: SkotiqTokens.spaceMd),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.basenameWithoutExtension(f.path),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SkotiqTypography.monoSm.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _when(f, byPath[f.path]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SkotiqTypography.caption.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                          Text(
                            'Without it: ${percent(f.retainedWithout)} kept',
                            maxLines: 1,
                            style: SkotiqTypography.caption.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (limiting.length > 1) ...[
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      SkotiqButton(
                        label: 'Leave out',
                        variant: ButtonVariant.secondary,
                        size: ButtonSize.small,
                        onPressed: busy ? null : () => onLeaveOut([f.path]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqButton(
            key: const ValueKey('darkroom_leave_out'),
            label: limiting.length == 1
                ? 'Leave it out'
                : (total > limiting.length
                    ? 'Leave these ${limiting.length} out'
                    : 'Leave all ${limiting.length} out'),
            variant: ButtonVariant.secondary,
            onPressed: busy
                ? null
                : () => onLeaveOut([for (final f in limiting) f.path]),
          ),
        ],
      ),
    );
  }

  static String _when(DarkroomLimitingFrame f, DbCapturedImage? image) {
    if (image == null) return f.group;
    final side = image.pierSide == null ? '' : ' · ${image.pierSide}';
    return '${darkroomShortDate(image.capturedAt)}, '
        '${hhmm(image.capturedAt)}$side';
  }
}

class _SubThumb extends ConsumerWidget {
  const _SubThumb({required this.image});

  final DbCapturedImage? image;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final id = image?.id;
    final bytes = id == null ? null : ref.watch(subThumbnailProvider(id));
    return Container(
      width: _limitThumb,
      height: _limitThumb,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: SkotiqTokens.borderRadiusXs,
        border: Border.all(color: colors.warning),
      ),
      child: switch (bytes) {
        AsyncData<Uint8List>(:final value) => Image.memory(
            value,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        _ => Icon(SkotiqIcons.image,
            size: SkotiqTokens.iconSm, color: colors.textMuted),
      },
    );
  }
}

class _LeftOutRow extends StatelessWidget {
  const _LeftOutRow({
    required this.name,
    required this.busy,
    required this.onPutBack,
  });

  final String name;
  final bool busy;
  final VoidCallback onPutBack;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceXs,
        SkotiqTokens.spaceXs,
        SkotiqTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$name left out',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          SkotiqButton(
            label: 'Put it back',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: busy ? null : onPutBack,
          ),
        ],
      ),
    );
  }
}

/// A switch per night of the plan; a night switched off leaves out all its
/// subs. The reference sub's night stays on.
class _NightsChooser extends StatelessWidget {
  const _NightsChooser({
    required this.target,
    required this.session,
    required this.reference,
    required this.busy,
    required this.onChanged,
  });

  final DarkroomTarget target;
  final DarkroomFramingSession session;
  final String reference;
  final bool busy;
  final ValueChanged<Map<String, String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final inPlan = {
      for (final l in session.original.lights) l['path'] as String
    };
    final nights = [
      for (final n in target.nights)
        (
          n,
          [
            for (final s in n.subs)
              if (inPlan.contains(_pathOf(s.imageId))) _pathOf(s.imageId)!,
          ],
        ),
    ].where((e) => e.$2.isNotEmpty).toList();
    if (nights.length < 2) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'NIGHTS IN THIS BUILD',
          style: SkotiqTypography.monoXs.copyWith(
            color: colors.textSecondary,
            letterSpacing: 1.3,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        for (final (night, paths) in nights)
          _CheckRow(
            key: ValueKey('darkroom_night_${night.key}'),
            value: paths.any((path) => !session.leftOut.containsKey(path)),
            label: '${darkroomNightLabel(night.evening)} · '
                '${paths.length} subs'
                '${paths.contains(reference) ? ' · holds the reference' : ''}',
            onChanged: busy || paths.contains(reference)
                ? null
                : (on) => onChanged(
                      on
                          ? {
                              for (final e in session.leftOut.entries)
                                if (!paths.contains(e.key)) e.key: e.value,
                            }
                          : {
                              ...session.leftOut,
                              for (final path in paths)
                                path: darkroomNightLeftOutReason,
                            },
                    ),
          ),
      ],
    );
  }

  String? _pathOf(int imageId) =>
      target.frames.where((f) => f.id == imageId).firstOrNull?.filePath;
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      borderRadius: SkotiqTokens.borderRadiusSm,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
        child: Row(
          children: [
            SkotiqCheckbox(
              value: value,
              onChanged:
                  onChanged == null ? null : (v) => onChanged!(v ?? false),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                label,
                style: SkotiqTypography.bodySm.copyWith(
                  color: onChanged == null
                      ? colors.textSecondary
                      : colors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.value,
    this.tone,
    this.trailing,
  });

  final String label;
  final String value;
  final Color? tone;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: SkotiqTypography.bodySm.copyWith(
                color: tone ?? colors.textPrimary,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: SkotiqTokens.spaceXs),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _FolderRow extends ConsumerWidget {
  const _FolderRow({
    required this.session,
    required this.targetKey,
    required this.busy,
  });

  final DarkroomFramingSession session;
  final String targetKey;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = session.folder ??
        ref.watch(darkroomMastersRootProvider).valueOrNull ??
        'Documents';
    return Tooltip(
      message: root,
      child: _SettingRow(
        label: 'Save to',
        value: root,
        trailing: SkotiqButton(
          label: 'Change',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: busy
              ? null
              : () async {
                  final folder = await ref.read(darkroomFolderPickerProvider)();
                  if (folder == null) return;
                  ref
                      .read(darkroomFramingSessionProvider(targetKey).notifier)
                      .state = session.copyWith(folder: folder);
                },
        ),
      ),
    );
  }
}

/// The framing limits: smallest field to accept, least overlap per sub and
/// roundest stars.
class _Advanced extends ConsumerStatefulWidget {
  const _Advanced({required this.job, required this.busy});

  final DarkroomBuildJob job;
  final bool busy;

  @override
  ConsumerState<_Advanced> createState() => _AdvancedState();
}

class _AdvancedState extends ConsumerState<_Advanced> {
  bool _open = false;
  double? _minimum;
  double? _overlap;
  double? _eccentricity;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _later(Future<void> Function() apply) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => apply());
  }

  Future<void> _replanWith(String key, double value) async {
    final job = ref.read(darkroomBuildJobsProvider);
    final plan = job?.plan;
    if (job == null || plan == null) return;
    await ref.read(darkroomBuildJobsProvider.notifier).replan(
          DarkroomBuildPlan.fromJson({...plan.toJson(), key: value}),
        );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final plan = widget.job.plan!.toJson();
    final minimum = _minimum ?? (plan['minRetainedArea'] as num).toDouble();
    final overlap = _overlap ?? (plan['minOverlap'] as num).toDouble();
    final eccentricity =
        _eccentricity ?? (plan['maxEccentricity'] as num).toDouble();
    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
          child: Text(
            text,
            style: SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SkotiqButton(
            key: const ValueKey('darkroom_framing_limits'),
            label: _open ? 'Hide framing limits' : 'Framing limits',
            icon: _open ? SkotiqIcons.chevronUp : SkotiqIcons.chevronDown,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => setState(() => _open = !_open),
          ),
        ),
        if (_open) ...[
          label('Smallest field to accept: ${percent(minimum, digits: 0)}'),
          SkotiqSlider(
            value: minimum,
            min: .5,
            max: 1,
            divisions: 50,
            onChanged: widget.busy
                ? null
                : (v) {
                    setState(() => _minimum = v);
                    _later(
                      () => ref
                          .read(darkroomBuildJobsProvider.notifier)
                          .setMinRetainedArea(v),
                    );
                  },
          ),
          label('Least overlap per sub: ${percent(overlap, digits: 0)}'),
          SkotiqSlider(
            value: overlap,
            min: .8,
            max: 1,
            divisions: 20,
            onChanged: widget.busy
                ? null
                : (v) {
                    setState(() => _overlap = v);
                    _later(() => _replanWith('minOverlap', v));
                  },
          ),
          label(
            'Roundest stars required: eccentricity up to '
            '${eccentricity.toStringAsFixed(2)}',
          ),
          SkotiqSlider(
            value: eccentricity,
            min: .3,
            max: .9,
            divisions: 60,
            onChanged: widget.busy
                ? null
                : (v) {
                    setState(() => _eccentricity = v);
                    _later(() => _replanWith('maxEccentricity', v));
                  },
          ),
          Text(
            'Reference: ${p.basename(widget.job.plan!.referencePath)}',
            style: SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
          ),
        ],
      ],
    );
  }
}

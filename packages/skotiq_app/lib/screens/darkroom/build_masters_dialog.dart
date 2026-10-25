import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../session_review/widgets/sub_cull_rail.dart' show subThumbnailProvider;
import 'build_masters/job_views.dart';

const _fitsFiles = XTypeGroup(
  label: 'FITS images',
  extensions: ['fits', 'fit', 'fts'],
);

/// Height of the dialog; its body scrolls.
const double _dialogHeight = 780;

/// Size of a frame thumbnail in the review list.
const double _thumbnailSize = 48;

/// Open the master build. The build itself runs as a background job, so the
/// window can be closed and reopened while it works.
Future<void> showBuildMastersDialog(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const BuildMastersDialog(),
    );

/// Guided multi-night master build: choose a target and frames, review
/// calibration, check framing with the registration pre-pass, then build in
/// the background.
class BuildMastersDialog extends ConsumerStatefulWidget {
  const BuildMastersDialog({super.key});
  @override
  ConsumerState<BuildMastersDialog> createState() => _BuildMastersDialogState();
}

class _BuildMastersDialogState extends ConsumerState<BuildMastersDialog> {
  Map<String, List<DbCapturedImage>> _targets = {};
  List<DbCapturedImage> _frames = [];
  List<DarkroomBuildGroup> _groups = [];
  final Set<int> _excluded = {};
  final Set<String> _openNights = {};
  final Set<String> _openGroups = {};
  final Set<String> _withoutFlats = {};
  String? _target;
  String? _reference;
  bool _busy = false;
  bool _loaded = false;
  bool _reviewed = false;
  double _overlap = .95;
  double _eccentricity = .65;
  double _minRetained = defaultMinRetainedArea;
  String _progress = 'Reading captured lights';
  String? _error;

  DarkroomBuildService get _service => ref.read(darkroomBuildServiceProvider);
  DarkroomBuildJobs get _jobs => ref.read(darkroomBuildJobsProvider.notifier);

  Future<void> _action(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Captured lights are read when the setup is first shown, not while a
  /// build is on screen.
  /// Start background work that outlives this window. Errors raised before
  /// the job takes over (another build running, an unreadable saved plan)
  /// are shown here; later ones are the job's own.
  void _background(Future<void> work) => unawaited(
        work.catchError((Object e) {
          if (mounted) setState(() => _error = '$e');
        }),
      );

  Future<void> _load() => _action(() async {
        _progress = 'Reading captured lights';
        final targets = await loadDarkroomTargets(ref.read(databaseProvider));
        if (mounted) setState(() => _targets = targets);
      });

  void _changed() {
    _groups = [];
    _reviewed = false;
    _withoutFlats.clear();
  }

  Future<void> _prepare() => _action(() async {
        _progress = 'Matching calibration by night and equipment';
        _groups = await _service.prepare(
          _frames.where((f) => !_excluded.contains(f.id)).toList(),
        );
        if (_groups.isEmpty) {
          throw StateError('No accepted light frames remain.');
        }
        _reference = DarkroomBuildService.chooseReference(_groups);
        _reviewed = false;
        _withoutFlats.clear();
      });

  void _set(DarkroomBuildGroup group, String kind, String? path) {
    if (path == null) {
      group.calibration.remove(kind);
    } else {
      group.calibration[kind] = path;
      if (kind == 'dark') group.calibration.remove('bias');
      if (kind == 'bias') group.calibration.remove('dark');
    }
    _reviewed = false;
  }

  Future<void> _pickMaster(DarkroomBuildGroup group, String kind) =>
      _action(() async {
        final file = await openFile(acceptedTypeGroups: [_fitsFiles]);
        if (file != null) _set(group, kind, file.path);
      });

  Future<void> _pickForFilter(String filter) => _action(() async {
        final file = await openFile(
          acceptedTypeGroups: [_fitsFiles],
          confirmButtonText: 'Use this $filter flat for every night',
        );
        if (file == null) return;
        DarkroomBuildService.applyToFilter(_groups, filter, 'flat', file.path);
        _withoutFlats.remove(filter);
        _reviewed = false;
      });

  Future<void> _buildCalibration(DarkroomBuildGroup group, String kind) =>
      _action(() async {
        final files = await openFiles(acceptedTypeGroups: [_fitsFiles]);
        if (files.isEmpty) return;
        final folder = await getDirectoryPath(
          confirmButtonText: 'Save calibration master here',
        );
        if (folder == null) return;
        final output = p.join(
          folder,
          '${kind}_${DateTime.now().microsecondsSinceEpoch}.fits',
        );
        _progress = 'Building the $kind master';
        String? bias;
        if (kind == 'flat') {
          // A bias or dark-flat is chosen deliberately; a long light dark is
          // never used to calibrate short flats.
          final file = await openFile(
            acceptedTypeGroups: [_fitsFiles],
            confirmButtonText: 'Select master bias or dark-flat',
          );
          if (file == null) {
            throw StateError(
              'Select a matching master bias or dark-flat before building flats.',
            );
          }
          bias = file.path;
        }
        await _service.buildCalibration(
          kind: kind,
          paths: files.map((f) => f.path).toList(),
          output: output,
          bias: bias,
          forGroup: group,
        );
        _set(group, kind, output);
      });

  Future<void> _checkFraming() => _action(() async {
        _progress = 'Checking calibration choices';
        await _service.checkCalibration(_groups);
        final plan = _service.plan(
          target: _target!,
          groups: _groups,
          referencePath: _reference!,
          minOverlap: _overlap,
          maxEccentricity: _eccentricity,
          minRetainedArea: _minRetained,
          excluded: [
            for (final f in _frames.where(
              (f) => !f.isAccepted || _excluded.contains(f.id),
            ))
              {
                'filter': f.filter,
                'path': f.filePath,
                'reason': f.isAccepted
                    ? 'Excluded during review'
                    : f.rejectionReason ?? 'Capture quality rejection',
              },
          ],
        );
        _background(_jobs.checkFraming(target: _target!, plan: plan));
      });

  Future<void> _build(DarkroomBuildJob job) => _action(() async {
        final parent = await getDirectoryPath(
          confirmButtonText: 'Save masters here',
        );
        if (parent == null) return;
        final name = job.target.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
        final directory = Directory(
          p.join(
              parent, 'Skotiq-$name-${DateTime.now().microsecondsSinceEpoch}'),
        );
        _background(_jobs.accept(directory));
      });

  Future<void> _resumeFrom() => _action(() async {
        final folder = await getDirectoryPath(
          confirmButtonText: 'Resume this Skotiq build',
        );
        if (folder == null) return;
        _background(_jobs.resume(Directory(folder)));
      });

  Future<void> _resumeJob(DarkroomBuildJob job) => _action(() async {
        _jobs.dismiss();
        _background(_jobs.resume(Directory(job.directory!)));
      });

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(darkroomBuildJobsProvider);
    if (job == null && !_loaded) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load());
      });
    }
    final (body, actions) = switch (job?.stage) {
      null => (_setup(context), _setupActions()),
      DarkroomJobStage.framing ||
      DarkroomJobStage.building ||
      DarkroomJobStage.exporting =>
        (
          BuildProgressPanel(job: job!),
          [
            if (job.stage != DarkroomJobStage.framing)
              SkotiqButton(
                label: 'Stop after the current light',
                variant: ButtonVariant.destructive,
                onPressed: () => _action(_jobs.stop),
              ),
            SkotiqButton(
              label: 'Close',
              variant: ButtonVariant.secondary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      DarkroomJobStage.awaitingReview => (
          FramingReviewPanel(job: job!),
          [
            SkotiqButton(
              label: 'Back to setup',
              variant: ButtonVariant.ghost,
              onPressed: _busy ? null : _jobs.dismiss,
            ),
            SkotiqButton(
              label: 'Build masters',
              onPressed: _busy || job.preview?.meetsMinimum != true
                  ? null
                  : () => _build(job),
            ),
          ],
        ),
      DarkroomJobStage.done => (
          BuildResultPanel(
            job: job!,
            onError: (e) => setState(() => _error = e),
          ),
          [
            SkotiqButton(
              label: 'Start another build',
              variant: ButtonVariant.secondary,
              onPressed: _jobs.dismiss,
            ),
          ],
        ),
      DarkroomJobStage.failed || DarkroomJobStage.stopped => (
          _ended(context, job!),
          [
            SkotiqButton(
              label: 'Start over',
              variant: ButtonVariant.ghost,
              onPressed: _jobs.dismiss,
            ),
            if (job.directory != null && job.plan != null)
              SkotiqButton(
                label: 'Resume this build',
                onPressed: _busy ? null : () => _resumeJob(job),
              ),
          ],
        ),
    };
    return SkotiqDialog(
      title: 'Build masters',
      icon: SkotiqIcons.layers,
      width: SkotiqDialog.widthWizard,
      height: _dialogHeight,
      closeEnabled: !_busy,
      actions: actions,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            SkotiqBanner(
              tone: BannerTone.error,
              title: 'That did not work.',
              message: _error,
              onDismiss: () => setState(() => _error = null),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
          ],
          if (_busy) ...[
            SkotiqProgressBar(value: 0, indeterminate: true, label: _progress),
            const SizedBox(height: SkotiqTokens.spaceMd),
          ],
          body,
        ],
      ),
    );
  }

  Widget _ended(BuildContext context, DarkroomBuildJob job) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkotiqBanner(
            tone: job.stage == DarkroomJobStage.stopped
                ? BannerTone.warning
                : BannerTone.error,
            title: job.stage == DarkroomJobStage.stopped
                ? 'Build stopped.'
                : 'Build failed.',
            message: job.error ?? job.message,
          ),
          if (job.filterResults.isNotEmpty || job.directory != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            BuildProgressPanel(job: job),
          ],
        ],
      );

  List<Widget> _setupActions() => [
        SkotiqButton(
          label: 'Resume saved build',
          variant: ButtonVariant.ghost,
          onPressed: _busy ? null : _resumeFrom,
        ),
        SkotiqButton(
          label: 'Check framing',
          isLoading: _busy && _groups.isNotEmpty,
          onPressed: _busy || !_canCheck ? null : _checkFraming,
        ),
      ];

  bool get _canCheck {
    if (_groups.isEmpty || !_reviewed || _reference == null) return false;
    final coverage = DarkroomBuildService.flatCoverage(_groups);
    return [
      ...coverage.withoutFlats,
      ...coverage.partial,
    ].every(_withoutFlats.contains);
  }

  Widget _setup(BuildContext context) {
    final colors = context.skotiqColors;
    final names = _targets.keys.toList()..sort();
    final included =
        _frames.where((f) => f.isAccepted && !_excluded.contains(f.id)).length;
    final nights = <String, List<DbCapturedImage>>{};
    for (final f in _frames) {
      nights.putIfAbsent(observingNight(f.capturedAt), () => []).add(f);
    }
    final nightKeys = nights.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Combine every night of a target into aligned linear masters. Originals are kept. '
          'Review frames and calibration, check framing, then build in the background.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        _label(context, 'Target across all nights'),
        SkotiqDropdown(
          value: _target,
          hint: names.isEmpty && !_busy
              ? 'No captured lights'
              : 'Choose a target',
          items: names,
          itemLabels: [
            for (final n in names) '$n · ${_targets[n]!.length} captures',
          ],
          isExpanded: true,
          onChanged: _busy
              ? null
              : (v) => setState(() {
                    _target = v;
                    _frames = _targets[v] ?? [];
                    _excluded.clear();
                    _openNights.clear();
                    _changed();
                  }),
        ),
        if (_frames.isNotEmpty) ...[
          _label(
            context,
            'Frames: ${_frames.length} captured, $included included',
          ),
          Text(
            'Nights run from noon to noon, so frames after midnight stay with their evening. '
            'Capture-rejected frames stay excluded.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          for (final night in nightKeys) _night(context, night, nights[night]!),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: 'Prepare calibration',
              variant: _groups.isEmpty
                  ? ButtonVariant.primary
                  : ButtonVariant.secondary,
              onPressed: _busy || included == 0 ? null : _prepare,
            ),
          ),
        ],
        if (_groups.isNotEmpty) ..._calibrationSection(context),
      ],
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(
          top: SkotiqTokens.spaceLg,
          bottom: SkotiqTokens.spaceSm,
        ),
        child: Text(
          text,
          style: SkotiqTypography.labelStrong.copyWith(
            color: context.skotiqColors.textPrimary,
          ),
        ),
      );

  Widget _checkRow(
    BuildContext context, {
    required bool value,
    required ValueChanged<bool>? onChanged,
    required String label,
  }) =>
      InkWell(
        onTap: onChanged == null ? null : () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
          child: Row(
            children: [
              SkotiqCheckbox(
                value: value,
                onChanged:
                    onChanged == null ? null : (v) => onChanged(v ?? false),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  label,
                  style: SkotiqTypography.body.copyWith(
                    color: context.skotiqColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _night(
    BuildContext context,
    String night,
    List<DbCapturedImage> frames,
  ) {
    final open = _openNights.contains(night);
    final usable = frames.where((f) => f.isAccepted).toList();
    final on = usable.where((f) => !_excluded.contains(f.id)).length;
    final filters = {for (final f in frames) f.filter ?? 'No filter'}.toList()
      ..sort();
    return SkotiqCard(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceXs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _checkRow(
                  context,
                  value: on > 0,
                  label:
                      'Night of $night · $on of ${frames.length} frames · ${filters.join(', ')}',
                  onChanged: _busy || usable.isEmpty
                      ? null
                      : (value) => setState(() {
                            for (final f in frames) {
                              value
                                  ? _excluded.remove(f.id)
                                  : _excluded.add(f.id);
                            }
                            _changed();
                          }),
                ),
              ),
              SkotiqIconButton(
                icon: open ? SkotiqIcons.chevronUp : SkotiqIcons.chevronDown,
                tooltip: open ? 'Hide frames' : 'Show frames',
                onPressed: () => setState(
                  () =>
                      open ? _openNights.remove(night) : _openNights.add(night),
                ),
              ),
            ],
          ),
          if (open)
            for (final f in frames)
              Row(
                children: [
                  const SizedBox(width: SkotiqTokens.spaceLg),
                  _BuildFrameThumbnail(imageId: f.id),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: _checkRow(
                      context,
                      value: f.isAccepted && !_excluded.contains(f.id),
                      label: f.isAccepted
                          ? '${f.filter ?? ''} · ${f.fileName} · HFR ${f.hfr?.toStringAsFixed(2) ?? 'unknown'} · ${f.exposureDuration} s'
                          : '${f.fileName}: ${f.rejectionReason ?? 'rejected during capture'}',
                      onChanged: _busy || !f.isAccepted
                          ? null
                          : (v) => setState(() {
                                v
                                    ? _excluded.remove(f.id)
                                    : _excluded.add(f.id);
                                _changed();
                              }),
                    ),
                  ),
                ],
              ),
        ],
      ),
    );
  }

  List<Widget> _calibrationSection(BuildContext context) {
    final colors = context.skotiqColors;
    final coverage = DarkroomBuildService.flatCoverage(_groups);
    final filters = _groups.map((g) => g.filter).toSet().toList()..sort();
    final available = _groups.expand((g) => g.frames).toList();
    final missing = [...coverage.withoutFlats, ...coverage.partial];
    return [
      _label(context, 'Calibration by filter and night'),
      Text(
        'Check that flats belong to the same optical setup: headers cannot show camera rotation or whether dust moved.',
        style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
      ),
      if (coverage.warning != null) ...[
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqBanner(
          tone: BannerTone.warning,
          title: 'Some filters have no flats.',
          message: coverage.warning,
        ),
        for (final filter in missing)
          _checkRow(
            context,
            value: _withoutFlats.contains(filter),
            label: coverage.partial.contains(filter)
                ? 'Build $filter with flats only on the nights that have them'
                : 'Build $filter without flats',
            onChanged: _busy
                ? null
                : (v) => setState(
                      () => v
                          ? _withoutFlats.add(filter)
                          : _withoutFlats.remove(filter),
                    ),
          ),
      ],
      const SizedBox(height: SkotiqTokens.spaceSm),
      for (final filter in filters) _filterCard(context, filter),
      _label(context, 'Alignment reference (every filter shares this field)'),
      SkotiqDropdown(
        value: _reference,
        items: [for (final f in available) f.filePath],
        itemLabels: [
          for (final f in available)
            '${f.filter ?? ''} · ${f.fileName} · night of ${observingNight(f.capturedAt)}',
        ],
        isExpanded: true,
        onChanged: _busy ? null : (v) => setState(() => _reference = v),
      ),
      _label(context,
          'Minimum field overlap per frame: ${percent(_overlap, digits: 0)}'),
      SkotiqSlider(
        value: _overlap,
        min: .8,
        max: 1,
        divisions: 20,
        onChanged: _busy ? null : (v) => setState(() => _overlap = v),
      ),
      _label(
        context,
        'Maximum star eccentricity: ${_eccentricity.toStringAsFixed(2)} (lower is rounder)',
      ),
      SkotiqSlider(
        value: _eccentricity,
        min: .3,
        max: .9,
        divisions: 60,
        onChanged: _busy ? null : (v) => setState(() => _eccentricity = v),
      ),
      _label(
        context,
        'Smallest common crop to accept: ${percent(_minRetained, digits: 0)} of the field',
      ),
      SkotiqSlider(
        value: _minRetained,
        min: .5,
        max: 1,
        divisions: 50,
        onChanged: _busy ? null : (v) => setState(() => _minRetained = v),
      ),
      Text(
        'Check framing registers every light from its stars and shows where each lands, '
        'the crop every filter will share and the frames that limit it. Nothing is integrated until you accept.',
        style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
      ),
      const SizedBox(height: SkotiqTokens.spaceSm),
      _checkRow(
        context,
        value: _reviewed,
        label: 'I reviewed the calibration choices and any missing masters.',
        onChanged: _busy ? null : (v) => setState(() => _reviewed = v),
      ),
    ];
  }

  Widget _filterCard(BuildContext context, String filter) {
    final colors = context.skotiqColors;
    final groups = _groups.where((g) => g.filter == filter).toList();
    final frames = groups.fold<int>(0, (n, g) => n + g.frames.length);
    final flats = {for (final g in groups) g.calibration['flat'] as String?};
    final flatText = flats.length == 1
        ? (flats.single == null
            ? 'no flat'
            : 'flat ${p.basename(flats.single!)}')
        : '${flats.whereType<String>().length} flats';
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      child: SkotiqCard(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$filter · ${groups.length} group${groups.length == 1 ? '' : 's'} · $frames frames · $flatText',
                    style: SkotiqTypography.bodyStrong.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                SkotiqButton(
                  label: 'One flat for all $filter nights',
                  size: ButtonSize.small,
                  variant: ButtonVariant.secondary,
                  onPressed: _busy ? null : () => _pickForFilter(filter),
                ),
              ],
            ),
            for (final g in groups) _groupRow(context, g),
          ],
        ),
      ),
    );
  }

  Widget _groupRow(BuildContext context, DarkroomBuildGroup group) {
    final colors = context.skotiqColors;
    final open = _openGroups.contains(group.label);
    String name(String kind) => group.calibration[kind] == null
        ? 'none'
        : p.basename(group.calibration[kind] as String);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(
            () => open
                ? _openGroups.remove(group.label)
                : _openGroups.add(group.label),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
            child: Row(
              children: [
                Icon(
                  open ? SkotiqIcons.chevronUp : SkotiqIcons.chevronDown,
                  size: 15,
                  color: colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    '${group.label} · ${group.frames.length} frame${group.frames.length == 1 ? '' : 's'}',
                    style: SkotiqTypography.body.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  'flat ${name('flat')} · ${group.calibration['dark'] != null ? 'dark ${name('dark')}' : 'bias ${name('bias')}'}',
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.bodySm.copyWith(
                    color:
                        group.hasFlat ? colors.textSecondary : colors.warning,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (open) ...[
          if (group.equipment != null)
            Text(
              group.equipment!,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          for (final warning in group.warnings)
            Padding(
              padding: const EdgeInsets.only(top: SkotiqTokens.spaceXs),
              child: Text(
                warning,
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          for (final kind in ['bias', 'dark', 'flat'])
            Padding(
              padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
              child: Row(
                children: [
                  SizedBox(
                    width: SkotiqTokens.space5xl,
                    child: Text(
                      kind,
                      style: SkotiqTypography.label.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Tooltip(
                      message: group.calibration[kind] as String? ?? 'None',
                      child: Text(
                        name(kind),
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.body.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  SkotiqButton(
                    label: 'Choose master',
                    size: ButtonSize.small,
                    variant: ButtonVariant.ghost,
                    onPressed: _busy ? null : () => _pickMaster(group, kind),
                  ),
                  SkotiqButton(
                    label: 'Build from frames',
                    size: ButtonSize.small,
                    variant: ButtonVariant.ghost,
                    onPressed:
                        _busy ? null : () => _buildCalibration(group, kind),
                  ),
                  SkotiqIconButton(
                    icon: SkotiqIcons.close,
                    tooltip: 'Use no $kind',
                    onPressed: _busy
                        ? null
                        : () => setState(() => _set(group, kind, null)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: SkotiqTokens.spaceSm),
        ],
      ],
    );
  }
}

class _BuildFrameThumbnail extends ConsumerWidget {
  const _BuildFrameThumbnail({required this.imageId});
  final int imageId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
        width: _thumbnailSize,
        height: _thumbnailSize,
        child: ref.watch(subThumbnailProvider(imageId)).when(
              loading: () => ColoredBox(color: context.skotiqColors.well),
              error: (_, __) => Icon(
                SkotiqIcons.imageOff,
                color: context.skotiqColors.textMuted,
              ),
              data: (bytes) => InkWell(
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    child: InteractiveViewer(
                      child: Image.memory(bytes, fit: BoxFit.contain),
                    ),
                  ),
                ),
                child: Image.memory(bytes, fit: BoxFit.cover),
              ),
            ),
      );
}

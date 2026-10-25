import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import '../../session_review/widgets/sub_cull_rail.dart'
    show subThumbnailProvider;
import '../build_masters/job_views.dart' show describeEta, percent;
import 'darkroom_targets_model.dart';
import 'darkroom_targets_providers.dart';
import 'nights_strip.dart' show darkroomNightLabel, darkroomShortDate;

part 'framing_check_parts/_field.dart';
part 'framing_check_parts/_aside.dart';

/// Limiting subs offered for leaving out, most limiting first.
const int _limitingShown = 3;

const double _asideWide = 420;
const double _asideNarrow = 360;
const double _asideBreak = 1500;
const double _limitThumb = 56;

/// Reason recorded in the build audit for a sub the operator left out here.
const String darkroomLeftOutReason = 'Left out at the framing check';
const String darkroomNightLeftOutReason = 'Night left out at the framing check';

/// Where a new build writes its folder when the operator has not chosen one.
final darkroomMastersRootProvider = FutureProvider<String>(
  (ref) async => p.join(
    (await resolveSkotiqDocumentsDirectory()).path,
    'Skotiq',
    'Masters',
  ),
);

/// Picks a folder; replaceable in tests.
final darkroomFolderPickerProvider = Provider<Future<String?> Function()>(
  (ref) => () => getDirectoryPath(confirmButtonText: 'Save masters here'),
);

/// What the operator decided at a target's framing check, kept while they
/// look elsewhere in the app.
class DarkroomFramingSession {
  const DarkroomFramingSession({
    required this.original,
    this.footprints = const {},
    this.leftOut = const {},
    this.withoutFlats = false,
    this.folder,
  });

  /// The plan as first checked, before anything was left out here.
  final DarkroomBuildPlan original;

  /// Every footprint seen, by light path, so a light put back is not
  /// registered again.
  final Map<String, DarkroomFramePreview> footprints;

  /// Lights left out here, with the reason recorded for each.
  final Map<String, String> leftOut;

  /// The operator agreed to build filters that have no flat.
  final bool withoutFlats;

  /// Parent folder for the build; null for the default.
  final String? folder;

  DarkroomFramingSession copyWith({
    Map<String, DarkroomFramePreview>? footprints,
    Map<String, String>? leftOut,
    bool? withoutFlats,
    String? folder,
  }) =>
      DarkroomFramingSession(
        original: original,
        footprints: footprints ?? this.footprints,
        leftOut: leftOut ?? this.leftOut,
        withoutFlats: withoutFlats ?? this.withoutFlats,
        folder: folder ?? this.folder,
      );

  /// [preview]'s footprints folded in.
  DarkroomFramingSession seen(DarkroomRegistrationPreview? preview) {
    if (preview == null) return this;
    final missing = preview.frames.any((f) => !footprints.containsKey(f.path));
    if (!missing) return this;
    return copyWith(
      footprints: {
        ...footprints,
        for (final f in preview.frames) f.path: f,
      },
    );
  }

  /// A preview carrying every known footprint, for re-evaluating without
  /// registering again.
  DarkroomRegistrationPreview? known(DarkroomRegistrationPreview? current) {
    if (current == null) return null;
    return DarkroomRegistrationPreview(
      width: current.width,
      height: current.height,
      frames: footprints.values.toList(),
      crop: current.crop,
      retainedArea: current.retainedArea,
      minRetainedArea: current.minRetainedArea,
      meetsMinimum: current.meetsMinimum,
      limiting: current.limiting,
    );
  }
}

final darkroomFramingSessionProvider =
    StateProvider.family<DarkroomFramingSession?, String>((ref, key) => null);

/// The framing check of a target's master build: where every sub lands on
/// the reference field, the area all of them share, the subs that limit it,
/// and the settings the build will use.
class DarkroomFramingCheck extends ConsumerStatefulWidget {
  const DarkroomFramingCheck({super.key, required this.target});

  final DarkroomTarget target;

  @override
  ConsumerState<DarkroomFramingCheck> createState() =>
      _DarkroomFramingCheckState();
}

class _DarkroomFramingCheckState extends ConsumerState<DarkroomFramingCheck> {
  bool _preparing = false;
  bool _busy = false;
  String? _error;
  String? _highlighted;

  String get _key => widget.target.key;
  DarkroomBuildJobs get _jobs => ref.read(darkroomBuildJobsProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final job = ref.read(darkroomBuildJobsProvider);
      if (job == null || (!job.active && job.target != _key)) {
        unawaited(_start());
      }
    });
  }

  /// Match calibration, choose the reference and register every kept sub.
  Future<void> _start() async {
    final job = ref.read(darkroomBuildJobsProvider);
    if (job?.active == true) return;
    if (job != null) _jobs.dismiss();
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final service = ref.read(darkroomBuildServiceProvider);
      final kept = [
        for (final f in widget.target.frames)
          if (f.isAccepted) f
      ];
      final groups = await service.prepare(kept);
      if (groups.isEmpty) {
        throw StateError('No kept light frames to build from.');
      }
      final choices = ref.read(darkroomFlatChoicesProvider(_key));
      for (final e in choices.entries) {
        DarkroomBuildService.applyToFilter(groups, e.key, 'flat', e.value);
      }
      await service.checkCalibration(groups);
      final plan = service.plan(
        target: _key,
        groups: groups,
        referencePath: DarkroomBuildService.chooseReference(groups),
        excluded: [
          for (final f in widget.target.frames)
            if (!f.isAccepted)
              {
                'filter': f.filter,
                'path': f.filePath,
                'reason': f.rejectionReason ?? 'Capture quality rejection',
              },
        ],
      );
      ref.read(darkroomFramingSessionProvider(_key).notifier).state =
          DarkroomFramingSession(original: plan);
      unawaited(
        _jobs.checkFraming(target: _key, plan: plan).catchError((Object e) {
          if (mounted) setState(() => _error = '$e');
        }),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Rebuild the plan from the original without [leftOut] and re-evaluate.
  Future<void> _applyLeftOut(
    DarkroomFramingSession session,
    Map<String, String> leftOut,
    DarkroomBuildJob job,
  ) =>
      _run(() async {
        final next = session.copyWith(leftOut: leftOut);
        ref.read(darkroomFramingSessionProvider(_key).notifier).state = next;
        var plan = session.original.withoutLights(leftOut);
        final current = job.plan!.toJson();
        plan = DarkroomBuildPlan.fromJson({
          ...plan.toJson(),
          'minOverlap': current['minOverlap'],
          'maxEccentricity': current['maxEccentricity'],
          'minRetainedArea': current['minRetainedArea'],
        });
        await _jobs.replan(plan, known: next.known(job.preview));
      });

  Future<void> _build(DarkroomBuildJob job, DarkroomFramingSession? session) =>
      _run(() async {
        final String parent = session?.folder ??
            await ref.read(darkroomMastersRootProvider.future);
        final stamp =
            DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
        final name = _key.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
        final directory = Directory(p.join(parent, '$name-$stamp'));
        unawaited(
          _jobs.accept(directory).catchError((Object e) {
            if (mounted) setState(() => _error = '$e');
          }),
        );
        if (mounted) context.go(darkroomTargetLocation(_key));
      });

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(darkroomBuildJobsProvider);
    final session = ref.watch(darkroomFramingSessionProvider(_key));
    final preview = job?.preview;
    if (session != null && preview != null && job?.target == _key) {
      final seen = session.seen(preview);
      if (!identical(seen, session)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref.read(darkroomFramingSessionProvider(_key).notifier).state =
                seen;
          }
        });
      }
    }
    final own = job != null && job.target == _key ? job : null;
    final Widget body;
    if (job != null && job.active && job.target != _key) {
      body = _Notice(
        icon: SkotiqIcons.layers,
        title: 'A build for ${job.target} is running',
        body: 'One build runs at a time. Come back when it finishes, or '
            'stop it in Activity.',
        action: SkotiqButton(
          label: 'Open Activity',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () =>
              context.go(darkroomTabLocation(DarkroomTab.activity)),
        ),
      );
    } else if (own?.stage == DarkroomJobStage.awaitingReview &&
        own!.preview != null) {
      return _Review(
        target: widget.target,
        job: own,
        session: session ?? DarkroomFramingSession(original: own.plan!),
        busy: _busy,
        error: _error ?? own.error,
        highlighted: _highlighted,
        onHighlight: (path) => setState(() => _highlighted = path),
        onLeaveOut: (session, leftOut) => _applyLeftOut(session, leftOut, own),
        onBuild: () => _build(own, session),
        onDismissError: () => setState(() => _error = null),
      );
    } else if (_preparing) {
      body = const _Notice(
        icon: SkotiqIcons.sliders,
        title: 'Matching calibration',
        body: 'Grouping the kept subs by night and equipment and matching '
            'darks, bias and flats from the library.',
        progress: true,
      );
    } else if (own?.stage == DarkroomJobStage.framing) {
      body = _Notice(
        icon: SkotiqIcons.crosshair,
        title: 'Registering every sub',
        body: '${own!.framesDone} of ${own.framesTotal} subs registered from '
            'their stars. ${describeEta(own.eta)}.',
        progress: true,
        value: own.framesTotal == 0 ? null : own.framesDone / own.framesTotal,
        action: SkotiqButton(
          label: 'Stop',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => unawaited(_jobs.stop()),
        ),
      );
    } else if (own != null &&
        (own.stage == DarkroomJobStage.building ||
            own.stage == DarkroomJobStage.exporting)) {
      body = _Notice(
        icon: SkotiqIcons.layers,
        title: 'Building masters',
        body: '${own.message}. ${own.overallDone} of ${own.overallTotal} '
            'subs. ${describeEta(own.eta)}.',
        progress: true,
        value:
            own.overallTotal == 0 ? null : own.overallDone / own.overallTotal,
        action: SkotiqButton(
          label: 'Follow in Activity',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () =>
              context.go(darkroomTabLocation(DarkroomTab.activity)),
        ),
      );
    } else if (own?.stage == DarkroomJobStage.done) {
      body = _Notice(
        icon: SkotiqIcons.success,
        title: 'Masters ready',
        body: own!.message,
        action: SkotiqButton(
          label: 'Check framing again',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: _start,
        ),
      );
    } else if (_error != null ||
        own?.stage == DarkroomJobStage.failed ||
        own?.stage == DarkroomJobStage.stopped) {
      body = _Notice(
        icon: SkotiqIcons.error,
        title: own?.stage == DarkroomJobStage.stopped
            ? 'The check stopped'
            : 'The framing check could not run',
        body: _error ?? own?.error ?? own?.message ?? '',
        tone: context.skotiqColors.error,
        action: SkotiqButton(
          label: 'Try again',
          icon: SkotiqIcons.refresh,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: _start,
        ),
      );
    } else {
      body = const _Notice(
        icon: SkotiqIcons.crosshair,
        title: 'Starting the framing check',
        progress: true,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.space2xl,
        SkotiqTokens.spaceLg,
        SkotiqTokens.space2xl,
        SkotiqTokens.spaceXl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleRow(target: widget.target),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Expanded(child: Center(child: body)),
        ],
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.target, this.trailing});

  final DarkroomTarget target;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      children: [
        SkotiqButton(
          key: const ValueKey('darkroom_framing_back'),
          label: target.key,
          icon: SkotiqIcons.arrowLeft,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => context.go(darkroomTargetLocation(target.key)),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Text(
          'Framing check',
          style: SkotiqTypography.pageTitle.copyWith(color: colors.textPrimary),
        ),
        const Spacer(),
        if (trailing != null)
          Flexible(
            child: Text(
              trailing!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: SkotiqTypography.monoSm.copyWith(
                color: colors.textSecondary,
                letterSpacing: .8,
              ),
            ),
          ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.progress = false,
    this.value,
    this.tone,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  final bool progress;
  final double? value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: SkotiqTokens.iconXl, color: tone ?? colors.textMuted),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Text(
            title,
            textAlign: TextAlign.center,
            style: SkotiqTypography.sectionTitle.copyWith(
              color: colors.textPrimary,
            ),
          ),
          if (body != null && body!.isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              body!,
              textAlign: TextAlign.center,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          if (progress) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            SkotiqProgressBar(
              value: value ?? 0,
              indeterminate: value == null,
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            action!,
          ],
        ],
      ),
    );
  }
}

class _Review extends ConsumerWidget {
  const _Review({
    required this.target,
    required this.job,
    required this.session,
    required this.busy,
    required this.error,
    required this.highlighted,
    required this.onHighlight,
    required this.onLeaveOut,
    required this.onBuild,
    required this.onDismissError,
  });

  final DarkroomTarget target;
  final DarkroomBuildJob job;
  final DarkroomFramingSession session;
  final bool busy;
  final String? error;
  final String? highlighted;
  final ValueChanged<String?> onHighlight;
  final void Function(DarkroomFramingSession, Map<String, String>) onLeaveOut;
  final VoidCallback onBuild;
  final VoidCallback onDismissError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final preview = job.preview!;
    final plan = job.plan!;
    final byPath = {for (final f in target.frames) f.filePath: f};
    final lights = plan.lights;
    final nights = {
      for (final l in lights)
        if (byPath[l['path']] != null)
          observingNight(byPath[l['path']]!.capturedAt),
    };
    final reference = plan.referencePath;
    final limiting = [
      for (final f in preview.limiting)
        if (f.path != reference && !session.leftOut.containsKey(f.path)) f,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final aside =
            constraints.maxWidth >= _asideBreak ? _asideWide : _asideNarrow;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  SkotiqTokens.space2xl,
                  SkotiqTokens.spaceLg,
                  SkotiqTokens.space2xl,
                  SkotiqTokens.spaceXl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TitleRow(
                      target: target,
                      trailing: 'STEP 1 OF 2 · ${preview.included.length} '
                          'SUBS FROM ${nights.length} '
                          'NIGHT${nights.length == 1 ? '' : 'S'}',
                    ),
                    const SizedBox(height: SkotiqTokens.spaceMd),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: colors.well,
                          borderRadius: SkotiqTokens.borderRadiusLg,
                          border: Border.all(color: colors.border),
                        ),
                        padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                        child: DarkroomFramingField(
                          preview: preview,
                          referenceImageId: byPath[reference]?.id,
                          limiting: [
                            for (final f in limiting.take(_limitingShown))
                              f.path,
                          ],
                          highlighted: highlighted,
                        ),
                      ),
                    ),
                    const SizedBox(height: SkotiqTokens.spaceMd),
                    _FieldLegend(
                      preview: preview,
                      referenceName: p.basename(reference),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              width: aside,
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: colors.border)),
              ),
              child: _Aside(
                target: target,
                job: job,
                session: session,
                limiting: limiting,
                byPath: byPath,
                busy: busy,
                error: error,
                onHighlight: onHighlight,
                onLeaveOut: onLeaveOut,
                onBuild: onBuild,
                onDismissError: onDismissError,
              ),
            ),
          ],
        );
      },
    );
  }
}

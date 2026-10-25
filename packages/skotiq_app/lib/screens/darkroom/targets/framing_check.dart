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

class _FieldLegend extends StatelessWidget {
  const _FieldLegend({required this.preview, required this.referenceName});

  final DarkroomRegistrationPreview preview;
  final String referenceName;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final style = SkotiqTypography.caption.copyWith(
      color: colors.textSecondary,
    );
    Widget box(Color c, double w) => Container(
          width: 14,
          height: 10,
          decoration: BoxDecoration(border: Border.all(color: c, width: w)),
        );
    Widget item(Widget mark, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mark,
            const SizedBox(width: SkotiqTokens.spaceSm),
            Text(label, style: style)
          ],
        );
    return Wrap(
      spacing: SkotiqTokens.spaceXl,
      runSpacing: SkotiqTokens.spaceXs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        item(box(colors.textPrimary.withValues(alpha: .45), 1),
            "Each sub's footprint"),
        item(box(colors.warning, 1.5), 'Limits the common area'),
        item(box(colors.primary, 1.5), 'Kept after stacking'),
        Text(
          'Field: $referenceName, ${preview.width} × ${preview.height} px',
          style: SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

/// The reference sub with every footprint, the common area and the subs that
/// limit it drawn over it.
class DarkroomFramingField extends ConsumerWidget {
  const DarkroomFramingField({
    super.key,
    required this.preview,
    required this.referenceImageId,
    required this.limiting,
    this.highlighted,
  });

  final DarkroomRegistrationPreview preview;
  final int? referenceImageId;

  /// Paths of the limiting subs to outline, most limiting first.
  final List<String> limiting;
  final String? highlighted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final id = referenceImageId;
    final image = id == null ? null : ref.watch(subThumbnailProvider(id));
    final retained = (preview.retainedArea * 100).toStringAsFixed(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final aspect = preview.width / math.max(1, preview.height);
        var w = constraints.maxWidth;
        var h = w / aspect;
        if (h > constraints.maxHeight) {
          h = constraints.maxHeight;
          w = h * aspect;
        }
        return Center(
          child: Semantics(
            image: true,
            label: 'Reference field with ${preview.included.length} sub '
                'footprints. The area every sub covers keeps $retained '
                'percent of the field'
                '${limiting.isEmpty ? '' : '; ${limiting.length} subs limit it'}.',
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.background),
                  if (image case AsyncData<Uint8List>(:final value))
                    Image.memory(
                      value,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    ),
                  CustomPaint(
                    painter: _FieldPainter(
                      preview: preview,
                      limiting: limiting,
                      highlighted: highlighted,
                      colors: colors,
                      labelStyle: SkotiqTypography.monoXs,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FieldPainter extends CustomPainter {
  _FieldPainter({
    required this.preview,
    required this.limiting,
    required this.highlighted,
    required this.colors,
    required this.labelStyle,
  });

  final DarkroomRegistrationPreview preview;
  final List<String> limiting;
  final String? highlighted;
  final SkotiqColors colors;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / preview.width;
    final sy = size.height / preview.height;
    Offset map(Offset g) => Offset(g.dx * sx, g.dy * sy);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final crop = preview.crop;
    final shade = Paint()..color = colors.background.withValues(alpha: .66);
    Rect? cropRect;
    if (crop == null) {
      canvas.drawRect(Offset.zero & size, shade);
    } else {
      cropRect = Rect.fromPoints(
        map(Offset(crop[0].toDouble(), crop[1].toDouble())),
        map(Offset(crop[2].toDouble(), crop[3].toDouble())),
      );
      canvas.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(Offset.zero & size)
          ..addRect(cropRect),
        shade,
      );
    }
    Path outline(List<Offset> corners) =>
        Path()..addPolygon([for (final c in corners) map(c)], true);
    final footprint = Paint()
      ..color = colors.textPrimary.withValues(
        alpha: preview.included.length > 40 ? .12 : .32,
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final f in preview.included) {
      if (f.corners == null || limiting.contains(f.path)) continue;
      canvas.drawPath(outline(f.corners!), footprint);
    }
    void label(String text, Offset at, Color color, {bool right = false}) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle.copyWith(color: color)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, right ? at.translate(-tp.width, 0) : at);
    }

    for (final path in limiting.reversed) {
      final f = preview.frames.where((f) => f.path == path).firstOrNull;
      if (f?.corners == null) continue;
      final emphasized = path == highlighted;
      final poly = outline(f!.corners!);
      canvas.drawPath(
        poly,
        Paint()
          ..color = colors.warning
          ..style = PaintingStyle.stroke
          ..strokeWidth = emphasized ? 3 : 1.5,
      );
      final b = poly.getBounds().intersect(Offset.zero & size);
      if (!b.isEmpty) {
        label(
          p.basenameWithoutExtension(path),
          Offset(b.left + 8, b.bottom - 20),
          colors.warning,
        );
      }
    }
    if (cropRect != null) {
      canvas.drawRect(
        cropRect,
        Paint()
          ..color = colors.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      label(
        'common area',
        cropRect.topRight.translate(-8, 8),
        colors.textPrimary,
        right: true,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FieldPainter old) =>
      old.preview != preview ||
      old.highlighted != highlighted ||
      old.colors != colors ||
      !_sameList(old.limiting, limiting);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

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
              if (missingFlats.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: SkotiqTokens.spaceXs,
                  ),
                  child: _CheckRow(
                    key: const ValueKey('darkroom_without_flats'),
                    value: session.withoutFlats,
                    label: 'Build ${missingFlats.join(', ')} without flats. '
                        'Dust shadows and vignetting stay in.',
                    onChanged: busy
                        ? null
                        : (v) => setSession.state =
                            session.copyWith(withoutFlats: v),
                  ),
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
    required this.limiting,
    required this.byPath,
    required this.busy,
    required this.onHighlight,
    required this.onLeaveOut,
  });

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
            limiting.length == 1
                ? 'One sub is holding it back'
                : '${limiting.length} subs are holding it back',
            style: SkotiqTypography.bodyStrong.copyWith(
              color: colors.textPrimary,
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
                            _describe(f, byPath[f.path]),
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
                : 'Leave all ${limiting.length} out',
            variant: ButtonVariant.secondary,
            onPressed: busy
                ? null
                : () => onLeaveOut([for (final f in limiting) f.path]),
          ),
        ],
      ),
    );
  }

  static String _describe(DarkroomLimitingFrame f, DbCapturedImage? image) {
    final kept = 'without it ${percent(f.retainedWithout)} is kept';
    if (image == null) return '${f.group} · $kept';
    final side = image.pierSide == null ? '' : ' · ${image.pierSide}';
    return '${darkroomShortDate(image.capturedAt)}, '
        '${hhmm(image.capturedAt)}$side · $kept';
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

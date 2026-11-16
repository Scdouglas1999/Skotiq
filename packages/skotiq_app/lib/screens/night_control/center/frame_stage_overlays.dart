// The frame stage's pills and the buttons over the frame.
part of 'frame_stage.dart';

FramePillText _framePill(
  BuildContext context,
  WidgetRef ref,
  CapturedImageData image,
) {
  final l10n = context.l10n;
  final clock = ref.watch(clockProvider);
  final time = ClockFormat.hms(clock.fromUtc(image.capturedAt.toUtc()));
  final frame = _stripFrameFor(ref.watch(nightSessionFramesProvider), image);
  if (frame != null) {
    return _stripPill(context, frame, time: time);
  }
  final what =
      nightFilterExposure(image.settings.filter, image.settings.exposureTime);
  final purpose = framePurposeLabel(l10n, image);
  if (purpose != null) {
    return FramePillText(
      title: what == null ? purpose : '$purpose · $what',
      time: time,
      status: l10n.text('nightCtrNotSaved'),
      statusTone: FramePillTone.muted,
    );
  }
  if (nightIsScratchFrame(image.filePath)) {
    final snapshot = l10n.text('nightCtrSnapshot');
    return FramePillText(
      title: what == null ? snapshot : '$snapshot · $what',
      time: time,
      status: l10n.text('nightCtrNotSaved'),
      statusTone: FramePillTone.muted,
    );
  }
  return FramePillText(title: what ?? l10n.text('nightCtrFrame'), time: time);
}

FramePillText _stripPill(
  BuildContext context,
  StripFrameVm frame, {
  String? time,
}) {
  final l10n = context.l10n;
  final accepted = frame.accepted;
  return FramePillText(
    title: _stripTitle(frame) ?? l10n.text('nightCtrFrame'),
    time: time ?? ClockFormat.hms(frame.capturedAt),
    status: switch ((accepted, frame.exclusion)) {
      (false, final FrameExclusionKind kind) => frameExclusionLabel(
          context,
          kind,
        ),
      (true, _) => l10n.text('nightCtrAccepted'),
      (false, _) => l10n.text('nightCtrRejected'),
      (null, _) => null,
    },
    statusTone: switch (accepted) {
      true => FramePillTone.good,
      false => FramePillTone.bad,
      null => FramePillTone.neutral,
    },
    dot: switch (accepted) {
      true => FramePillTone.good,
      false => FramePillTone.bad,
      null => FramePillTone.muted,
    },
  );
}

/// The two pills along the top: the frame on the left, the activity on the
/// right. They share the width and shorten their text before they overlap.
class _TopPills extends ConsumerWidget {
  const _TopPills({
    required this.image,
    required this.selected,
    required this.nowUtc,
  });

  final CapturedImageData? image;
  final StripFrameVm? selected;
  final DateTime nowUtc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final af = ref.watch(nightStageAutofocusProvider);
    final selected = this.selected;
    final image = this.image;

    FramePillText? left;
    if (selected != null) {
      left = _stripPill(context, selected);
    } else if (af != null) {
      final point = af.point;
      final points = af.points;
      final hfr = af.hfr;
      left = FramePillText(
        title: point != null && points != null
            ? l10n.text(
                'nightCtrAfPoint',
                params: <String, String>{
                  'point': '$point',
                  'total': '$points',
                },
              )
            : l10n.text('nightCtrAfStarting'),
        dot: FramePillTone.active,
        mono: hfr == null
            ? null
            : l10n.text(
                'nightCtrHfrValue',
                params: <String, String>{'hfr': hfr.toStringAsFixed(2)},
              ),
      );
    } else if (image != null) {
      left = _framePill(context, ref, image);
    }

    final right = _activityPill(context, ref, image);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (left != null)
          Flexible(child: FramePill(text: left))
        else
          const SizedBox(),
        const SizedBox(width: SkotiqTokens.spaceSm),
        if (right != null)
          Flexible(
            child: FramePill(
              text: right,
              liveRegion: right.dot == FramePillTone.active,
            ),
          ),
      ],
    );
  }

  /// What is happening now: the action holding the run, the exposure out,
  /// or, before a run, the solve of the frame on screen.
  FramePillText? _activityPill(
    BuildContext context,
    WidgetRef ref,
    CapturedImageData? image,
  ) {
    final l10n = context.l10n;
    final action = ref.watch(nightActionStateProvider);
    final message = action.message;
    if (message != null) {
      return FramePillText(
        title: message.resolve(l10n),
        dot: FramePillTone.active,
      );
    }
    final exposure = ref.watch(nightStageExposureProvider);
    final phase = ref.watch(nightRunPhaseProvider);
    if (exposure != null && ref.watch(nightStageAutofocusProvider) == null) {
      // The frame number is the run's next light frame; only the run's own
      // exposures get one.
      int? next;
      String? filter;
      if (phase == NightRunPhase.running) {
        final frames = ref.watch(nightSessionFramesProvider);
        next =
            frames.isEmpty ? 1 : (frames.last.frameNumber ?? frames.length) + 1;
        filter = ref.watch(nightHeaderProvider.select((h) => h.currentFilter));
      }
      return FramePillText(
        title: next == null
            ? l10n.text('nightCtrExposing')
            : l10n.text(
                'nightCtrExposingFrame',
                params: <String, String>{'frame': '$next'},
              ),
        time: nightFilterExposure(filter, exposure.total),
        mono: _exposureClock(l10n, exposure, nowUtc),
      );
    }
    if (nightIsBeforeRun(phase) && image != null) {
      final solve = ref.watch(nightStageSolveProvider);
      if (solve != null) {
        final off = solve.offTargetArcmin;
        return FramePillText(
          title: l10n.text(
            'nightCtrSolved',
            params: <String, String>{
              'ra': CoordinateFormat.raDenseFromDegrees(solve.raDegrees),
              'dec': CoordinateFormat.decDense(solve.decDegrees),
            },
          ),
          status: off == null
              ? null
              : l10n.text(
                  'nightCtrSolveOff',
                  // In the unit every off-target reading uses.
                  params: <String, String>{
                    'offset': AngleFormat.arcsec(off * 60)
                  },
                ),
          statusTone: FramePillTone.good,
        );
      }
    }
    return null;
  }
}

/// `108 s left`, `72 s` when the length is unknown, or null when the
/// elapsed time is unknown. The length itself sits beside it in the pill.
String? _exposureClock(
  SkotiqLocalizations l10n,
  NightExposureVm exposure,
  DateTime nowUtc,
) {
  final done = exposure.elapsedAt(nowUtc);
  final total = exposure.total;
  if (done == null) return null;
  if (total == null) return '${done.floor()} s';
  final left = (total - done).clamp(0.0, total).ceil();
  return l10n.text(
    'nightCtrSecondsLeft',
    params: <String, String>{'seconds': '$left'},
  );
}

/// Along the stage's bottom edge: the way back to the live frame when a saved
/// frame is shown, what the frame's load or star overlay says, and the view
/// buttons. On a narrow stage the status takes its own line above the
/// buttons rather than a third of one, which cut its HFR.
class _StageControls extends ConsumerWidget {
  const _StageControls({
    required this.live,
    required this.selected,
    required this.viewport,
    required this.stacked,
  });

  final CapturedImageData? live;
  final StripFrameVm? selected;
  final Size viewport;
  final bool stacked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = this.selected;
    final CapturedImageData? shown;
    final Widget status;
    if (selected != null) {
      final load = ref.watch(savedFrameProvider(_savedFrameRef(selected)));
      shown = load is SavedFrameReady ? load.image : null;
      status = _SavedFrameStatus(load: load);
    } else {
      shown = live;
      status = _OverlayStatus(stars: currentFrameStarsProvider);
    }
    final buttons = shown == null
        ? null
        : _ViewButtons(
            image: shown,
            viewport: viewport,
            stretch: selected == null,
          );
    final leading = <Widget>[
      if (selected != null) ...<Widget>[
        const _BackToLatest(),
        const SizedBox(width: SkotiqTokens.spaceSm),
      ],
      Flexible(child: status),
    ];
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: leading),
          if (buttons != null) ...<Widget>[
            const SizedBox(height: SkotiqTokens.spaceXs),
            Align(alignment: Alignment.bottomRight, child: buttons),
          ],
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        // The buttons keep their width; the status gets the rest.
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: leading,
          ),
        ),
        if (buttons != null) ...<Widget>[
          const SizedBox(width: SkotiqTokens.spaceSm),
          buttons,
        ],
      ],
    );
  }
}

/// A saved frame's load while it is coming in; once it is on screen, what the
/// star overlay found, else its size at full resolution.
class _SavedFrameStatus extends ConsumerWidget {
  const _SavedFrameStatus({required this.load});

  final SavedFrameLoad load;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = this.load;
    if (load is SavedFrameReady &&
        ref.watch(
          imagingViewerStateProvider.select((v) => v.showStarOverlay),
        )) {
      return _OverlayStatus(stars: savedFrameStarsProvider(load.localPath));
    }
    return Align(
      alignment: Alignment.bottomLeft,
      child: FramePill(
        text: savedFrameLoadPill(context.l10n, load),
        liveRegion: true,
      ),
    );
  }
}

/// What the star overlay found on the frame on screen, beside the view
/// buttons; nothing while the overlay is off.
class _OverlayStatus extends ConsumerWidget {
  const _OverlayStatus({required this.stars});

  /// The frame's stars; watched only while the overlay is on, since watching
  /// runs the detection.
  final ProviderListenable<AsyncValue<StarDetectionResult?>> stars;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    if (!ref.watch(
      imagingViewerStateProvider.select((v) => v.showStarOverlay),
    )) {
      return const SizedBox.shrink();
    }
    final text = starOverlayPill(l10n, ref.watch(stars));
    return Align(
      alignment: Alignment.bottomLeft,
      child: FramePill(text: text, liveRegion: true),
    );
  }
}

class _BackToLatest extends ConsumerWidget {
  const _BackToLatest();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FrameViewButton(
      label: context.l10n.text('nightCtrBackToLatest'),
      icon: LucideIcons.arrowRight,
      onPressed: () =>
          ref.read(nightStageSelectionProvider.notifier).state = null,
    );
  }
}

/// Stretch (the live frame only: a saved frame is drawn through the app's
/// display stretch), Stars, Annotate, Zoom 1:1.
class _ViewButtons extends ConsumerWidget {
  const _ViewButtons({
    required this.image,
    required this.viewport,
    required this.stretch,
  });

  final CapturedImageData image;
  final Size viewport;
  final bool stretch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final viewer = ref.watch(imagingViewerStateProvider);
    final annotate = ref.watch(catalogOverlayEnabledProvider);
    final fitScale = previewFitScale(
      viewportSize: viewport,
      imageSize: Size(image.width.toDouble(), image.height.toDouble()),
    );
    final native = (fitScale * viewer.zoomLevel - 1).abs() < 0.001 &&
        viewer.zoomLevel != 1.0;
    final viewerNotifier = ref.read(imagingViewerStateProvider.notifier);
    return Wrap(
      spacing: SkotiqTokens.spaceXs,
      runSpacing: SkotiqTokens.spaceXs,
      alignment: WrapAlignment.end,
      children: <Widget>[
        if (stretch)
          FrameViewButton(
            label: l10n.text('nightCtrViewStretch'),
            tooltip: l10n.text('nightCtrViewStretchTip'),
            selected: ref.watch(nightStageStretchProvider),
            onPressed: () {
              final notifier = ref.read(autoStretchSettingsProvider.notifier);
              final settings = ref.read(autoStretchSettingsProvider);
              notifier.update(settings.copyWith(enabled: !settings.enabled));
            },
          ),
        FrameViewButton(
          label: l10n.text('nightCtrViewStars'),
          tooltip: l10n.text('nightCtrViewStarsTip'),
          selected: viewer.showStarOverlay,
          onPressed: viewerNotifier.toggleStarOverlay,
        ),
        FrameViewButton(
          label: l10n.text('nightCtrViewAnnotate'),
          tooltip: l10n.text('nightCtrViewAnnotateTip'),
          selected: annotate,
          onPressed: () => ref
              .read(catalogOverlayEnabledProvider.notifier)
              .state = !annotate,
        ),
        FrameViewButton(
          label: l10n.text(native ? 'nightCtrViewFit' : 'nightCtrViewZoom'),
          tooltip: l10n.text(
            native ? 'nightCtrViewFitTip' : 'nightCtrViewZoomTip',
          ),
          onPressed: native
              ? viewerNotifier.fitToWindow
              : () => viewerNotifier.zoom1to1(fitScale: fitScale),
        ),
      ],
    );
  }
}

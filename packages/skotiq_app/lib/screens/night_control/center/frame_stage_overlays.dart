// The frame stage's pills and the buttons over the frame.
part of 'frame_stage.dart';

// ---------------------------------------------------------------------------
// Pills
// ---------------------------------------------------------------------------

enum _PillTone { neutral, good, bad, muted, active }

/// One line of pill copy.
class _PillText {
  const _PillText({
    required this.title,
    this.time,
    this.status,
    this.statusTone = _PillTone.neutral,
    this.dot = _PillTone.muted,
    this.mono,
  });

  final String title;
  final String? time;
  final String? status;
  final _PillTone statusTone;
  final _PillTone dot;

  /// A trailing value in the mono face ("HFR 2.08", "72 / 180 s").
  final String? mono;
}

_PillText _framePill(
  BuildContext context,
  WidgetRef ref,
  CapturedImageData image,
) {
  final l10n = context.l10n;
  final clock = ref.watch(clockProvider);
  final time = nightClockHms(clock.fromUtc(image.capturedAt.toUtc()));
  final frame = _stripFrameFor(ref.watch(nightSessionFramesProvider), image);
  if (frame != null) {
    return _stripPill(context, frame, time: time);
  }
  final what =
      nightFilterExposure(image.settings.filter, image.settings.exposureTime);
  if (nightIsScratchFrame(image.filePath)) {
    final snapshot = l10n.text('nightCtrSnapshot');
    return _PillText(
      title: what == null ? snapshot : '$snapshot · $what',
      time: time,
      status: l10n.text('nightCtrNotSaved'),
      statusTone: _PillTone.muted,
    );
  }
  return _PillText(title: what ?? l10n.text('nightCtrFrame'), time: time);
}

_PillText _stripPill(BuildContext context, StripFrameVm frame, {String? time}) {
  final l10n = context.l10n;
  final accepted = frame.accepted;
  return _PillText(
    title: _stripTitle(frame) ?? l10n.text('nightCtrFrame'),
    time: time ?? nightClockHms(frame.capturedAt),
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
      true => _PillTone.good,
      false => _PillTone.bad,
      null => _PillTone.neutral,
    },
    dot: switch (accepted) {
      true => _PillTone.good,
      false => _PillTone.bad,
      null => _PillTone.muted,
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

    _PillText? left;
    if (selected != null) {
      left = _stripPill(context, selected);
    } else if (af != null) {
      final point = af.point;
      final points = af.points;
      final hfr = af.hfr;
      left = _PillText(
        title: point != null && points != null
            ? l10n.text(
                'nightCtrAfPoint',
                params: <String, String>{
                  'point': '$point',
                  'total': '$points',
                },
              )
            : l10n.text('nightCtrAfStarting'),
        dot: _PillTone.active,
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
          Flexible(child: _Pill(text: left))
        else
          const SizedBox(),
        const SizedBox(width: SkotiqTokens.spaceSm),
        if (right != null)
          Flexible(
              child: _Pill(
                  text: right, liveRegion: right.dot == _PillTone.active)),
      ],
    );
  }

  /// What is happening now: the action holding the run, the exposure out,
  /// or, before a run, the solve of the frame on screen.
  _PillText? _activityPill(
    BuildContext context,
    WidgetRef ref,
    CapturedImageData? image,
  ) {
    final l10n = context.l10n;
    final action = ref.watch(nightActionStateProvider);
    final message = action.message;
    if (message != null) {
      return _PillText(title: message.resolve(l10n), dot: _PillTone.active);
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
      return _PillText(
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
        return _PillText(
          title: l10n.text(
            'nightCtrSolved',
            params: <String, String>{
              'ra': CoordinateFormat.raFromDegrees(
                solve.raDegrees,
                style: SexagesimalStyle.compactLetters,
                seconds: SecondsPrecision.integerFloored,
              ),
              'dec': CoordinateFormat.dec(
                solve.decDegrees,
                style: SexagesimalStyle.compactLetters,
                seconds: SecondsPrecision.integerFloored,
              ),
            },
          ),
          status: off == null
              ? null
              : l10n.text(
                  'nightCtrSolveOff',
                  params: <String, String>{
                    'offset': off < 10
                        ? off.toStringAsFixed(1)
                        : off.toStringAsFixed(0),
                  },
                ),
          statusTone: _PillTone.good,
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

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.liveRegion = false});

  final _PillText text;
  final bool liveRegion;

  Color _tone(SkotiqColors colors, _PillTone tone) => switch (tone) {
        _PillTone.neutral => colors.textSecondary,
        _PillTone.good => colors.success,
        _PillTone.bad => colors.error,
        _PillTone.muted => colors.textMuted,
        _PillTone.active => colors.warning,
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final spans = <InlineSpan>[
      TextSpan(
        text: text.title,
        style:
            TextStyle(fontWeight: FontWeight.w600, color: colors.textPrimary),
      ),
      if (text.time != null)
        TextSpan(
          text: '   ${text.time}',
          style: TextStyle(color: colors.textMuted),
        ),
      if (text.mono != null)
        TextSpan(
          text: '   ${text.mono}',
          style: SkotiqTypography.withTabular(
            SkotiqTypography.monoSm.copyWith(color: colors.textPrimary),
          ),
        ),
      if (text.status != null)
        TextSpan(
          text: '   ${text.status}',
          style: TextStyle(color: _tone(colors, text.statusTone)),
        ),
    ];
    return Semantics(
      liveRegion: liveRegion,
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.86),
          borderRadius: SkotiqTokens.borderRadiusFull,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: _tone(colors, text.dot),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Flexible(
              child: Text.rich(
                TextSpan(children: spans),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the star overlay found on the frame on screen, beside the view
/// buttons; nothing while the overlay is off.
class _OverlayStatus extends ConsumerWidget {
  const _OverlayStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    if (!ref.watch(
      imagingViewerStateProvider.select((v) => v.showStarOverlay),
    )) {
      return const SizedBox.shrink();
    }
    final stars = ref.watch(currentFrameStarsProvider);
    final _PillText text = stars.when(
      loading: () => _PillText(
        title: l10n.text('nightCtrStarsFinding'),
        dot: _PillTone.active,
      ),
      error: (_, __) => _PillText(
        title: l10n.text('nightCtrStarsFailed'),
        dot: _PillTone.bad,
      ),
      data: (result) {
        if (result == null) {
          return _PillText(title: l10n.text('nightCtrStarsNoFile'));
        }
        if (result.stars.isEmpty) {
          return _PillText(title: l10n.text('nightCtrStarsNone'));
        }
        final hfr = result.medianHfr;
        return _PillText(
          title: result.stars.length == 1
              ? l10n.text('nightCtrStarsFoundOne')
              : l10n.text(
                  'nightCtrStarsFound',
                  params: <String, String>{'count': '${result.stars.length}'},
                ),
          dot: _PillTone.good,
          mono: hfr > 0 && hfr.isFinite
              ? l10n.text(
                  'nightCtrHfrValue',
                  params: <String, String>{'hfr': hfr.toStringAsFixed(2)},
                )
              : null,
        );
      },
    );
    return Align(
      alignment: Alignment.bottomLeft,
      child: _Pill(text: text, liveRegion: true),
    );
  }
}

// ---------------------------------------------------------------------------
// Buttons over the frame
// ---------------------------------------------------------------------------

class _BackToLatest extends ConsumerWidget {
  const _BackToLatest();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _StageButton(
      label: context.l10n.text('nightCtrBackToLatest'),
      icon: LucideIcons.arrowRight,
      onPressed: () =>
          ref.read(nightStageSelectionProvider.notifier).state = null,
    );
  }
}

/// Stretch, Stars, Annotate, Zoom 1:1.
class _ViewButtons extends ConsumerWidget {
  const _ViewButtons({required this.image, required this.viewport});

  final CapturedImageData image;
  final Size viewport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final viewer = ref.watch(imagingViewerStateProvider);
    final stretch = ref.watch(nightStageStretchProvider);
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
        _StageButton(
          label: l10n.text('nightCtrViewStretch'),
          tooltip: l10n.text('nightCtrViewStretchTip'),
          selected: stretch,
          onPressed: () {
            final notifier = ref.read(autoStretchSettingsProvider.notifier);
            final settings = ref.read(autoStretchSettingsProvider);
            notifier.update(settings.copyWith(enabled: !settings.enabled));
          },
        ),
        _StageButton(
          label: l10n.text('nightCtrViewStars'),
          tooltip: l10n.text('nightCtrViewStarsTip'),
          selected: viewer.showStarOverlay,
          onPressed: viewerNotifier.toggleStarOverlay,
        ),
        _StageButton(
          label: l10n.text('nightCtrViewAnnotate'),
          tooltip: l10n.text('nightCtrViewAnnotateTip'),
          selected: annotate,
          onPressed: () => ref
              .read(catalogOverlayEnabledProvider.notifier)
              .state = !annotate,
        ),
        _StageButton(
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

class _StageButton extends StatelessWidget {
  const _StageButton({
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.icon,
    this.selected,
  });

  final String label;
  final String? tooltip;
  final IconData? icon;
  final VoidCallback onPressed;

  /// A toggle's state; null for a plain button.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final on = selected == true;
    final button = Semantics(
      button: true,
      toggled: selected,
      label: label,
      hint: tooltip,
      excludeSemantics: true,
      child: Material(
        color: on
            ? colors.primary.withValues(alpha: SkotiqTokens.opacityStrong)
            : colors.surface.withValues(alpha: 0.86),
        // An on toggle keeps its outline under the pointer: the hover wash
        // alone read as off right after the click that turned it on.
        shape: RoundedRectangleBorder(
          borderRadius: SkotiqTokens.borderRadiusLg,
          side: on
              ? BorderSide(
                  color: colors.primary.withValues(
                    alpha: SkotiqTokens.opacitySelectedRing,
                  ),
                )
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: SkotiqTokens.borderRadiusLg,
          hoverColor:
              colors.textPrimary.withValues(alpha: SkotiqTokens.opacitySubtle),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 26),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: SkotiqTypography.captionSm.copyWith(
                      color: on ? colors.textPrimary : colors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (icon != null) ...<Widget>[
                    const SizedBox(width: SkotiqTokens.spaceXs),
                    Icon(icon, size: 12, color: colors.textSecondary),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final tip = tooltip;
    if (tip == null) return button;
    return Tooltip(message: tip, excludeFromSemantics: true, child: button);
  }
}

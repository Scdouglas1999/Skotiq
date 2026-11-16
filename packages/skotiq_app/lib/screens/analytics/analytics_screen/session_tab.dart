part of '../analytics_screen.dart';

class _SessionTab extends ConsumerStatefulWidget {
  const _SessionTab({required this.view, required this.onViewPicked});

  /// Charts of the session's frames, or its optical diagnostics.
  final SessionView view;
  final ValueChanged<SessionView> onViewPicked;

  @override
  ConsumerState<_SessionTab> createState() => _SessionTabState();
}

class _SessionTabState extends ConsumerState<_SessionTab> {
  /// Session chosen in the review bar. Null follows the live session, or the
  /// most recent one that actually holds light frames;
  /// [kQuickCaptureSessionSelection] pins the frames shot outside any session.
  ///
  /// The third state is the point: with only "auto" and "a session", the first
  /// completed run won the auto-pick forever and the quick captures could never
  /// be asked for again.
  int? get _selectedSessionId => ref.watch(analyticsSessionPickProvider);

  void _pick(int? id) =>
      ref.read(analyticsSessionPickProvider.notifier).state = id;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final sessionState = ref.watch(sessionStateProvider);
    final duration = ref.watch(sessionDurationProvider);
    final l10n = context.l10n;

    final allSessions =
        ref.watch(allSessionsProvider).valueOrNull ?? const <ImagingSession>[];
    // A session is picked even when none is live, so the night that just
    // finished is reachable from the tab named for it.
    final pickedSessionId =
        allSessions.any((session) => session.id == _selectedSessionId)
            ? _selectedSessionId
            : null;
    // An explicit "Quick captures" pick outranks the auto-pick; without it the
    // auto-pick reclaimed the tab on the very next build.
    final quickCapturesPinned =
        _selectedSessionId == kQuickCaptureSessionSelection;
    // Watched unconditionally: a watch inside the ?? chain would come and go
    // with the pick and silently drop the dependency.
    final autoSessionId = sessionState.dbSessionId ??
        ref.watch(scienceDefaultSessionProvider).valueOrNull;
    final reviewSessionId =
        quickCapturesPinned ? null : (pickedSessionId ?? autoSessionId);
    final reviewSession = allSessions
        .cast<ImagingSession?>()
        .firstWhere((s) => s?.id == reviewSessionId, orElse: () => null);
    final isLive = sessionState.isActive &&
        sessionState.dbSessionId != null &&
        sessionState.dbSessionId == reviewSessionId;

    // Get session images when one is being reviewed, otherwise the standalone
    // captures that are all this tab has to show.
    final bool isStandaloneMode = reviewSessionId == null;
    // Watched whether or not it is on screen: it is also what tells the picker
    // whether there is a quick-capture bucket worth offering.
    final standaloneAsync = ref.watch(standaloneImagesProvider);
    final imagesAsyncValue = reviewSessionId != null
        ? ref.watch(dbSessionImagesProvider(reviewSessionId))
        : standaloneAsync;
    final offerQuickCaptures = quickCapturesPinned ||
        (standaloneAsync.valueOrNull?.isNotEmpty ?? false);
    // What the picker shows as chosen: the sentinel when the operator pinned
    // the quick captures, otherwise whichever session is under review.
    final reviewSelectionId =
        quickCapturesPinned ? kQuickCaptureSessionSelection : reviewSessionId;
    // Non-null when the frame stream failed. Read once so the tab raises ONE
    // banner rather than one per surface that needed the frames.
    final Object? framesError = imagesAsyncValue.error;
    void retryImages() {
      if (reviewSessionId != null) {
        ref.invalidate(dbSessionImagesProvider(reviewSessionId));
      } else {
        ref.invalidate(standaloneImagesProvider);
      }
    }

    final String headerTitle;
    final String headerSubtitle;
    if (isLive) {
      headerTitle = l10n.text('analyticsCurrentSession');
      headerSubtitle = sessionState.startTime != null
          ? l10n.text(
              'analyticsStarted',
              params: {
                'time': ClockFormat.monthDayYearHm(
                    sessionState.startTime!.toLocal()),
              },
            )
          : l10n.text('analyticsSessionInProgress');
    } else if (reviewSession != null) {
      headerTitle = reviewSession.name ?? l10n.text('analyticsUnnamedSession');
      headerSubtitle =
          '${ClockFormat.weekdayMonthDayYear(reviewSession.startTime.toLocal())} · '
          '${ClockFormat.hm(reviewSession.startTime.toLocal())}'
          '  ·  ${sessionStatusLabel(reviewSession.status)}';
    } else if (isStandaloneMode) {
      headerTitle = l10n.text('analyticsQuickCapture');
      headerSubtitle = l10n.text('analyticsQuickCaptureSubtitle');
    } else {
      headerTitle = l10n.text('analyticsNoActiveSession');
      headerSubtitle = l10n.text('analyticsNoSessionInProgress');
    }

    // Shared with the chart grid below so the stat strip and the four charts
    // can never describe different frames.
    List<DbCapturedImage> acceptedLights(List<DbCapturedImage> images) =>
        sessionChartFrames(images);

    /// Metric computed from whichever frame set is on screen, so a finished
    /// session reports its real totals instead of an em-dash.
    ///
    /// Null while the frames are loading or after they failed: a [Readout]
    /// renders that as the em dash. The old strings ('Loading…',
    /// 'Unavailable', 'No data') were placeholders sitting in a value slot,
    /// which is exactly what the copy rules forbid — the charts below carry
    /// the loading and error state.
    String? frameMetric(String? Function(List<DbCapturedImage>) value) {
      return imagesAsyncValue.when(
        data: value,
        loading: () => null,
        error: (_, __) => null,
      );
    }

    // Shared with the History cards so one session can never be described two
    // ways.
    final elapsed = reviewSession == null
        ? null
        : sessionElapsed(
            reviewSession,
            isLive: isLive,
            lastFrameAt:
                ref.watch(lastFrameBySessionProvider)[reviewSession.id],
            now: ref.watch(clockProvider).instant,
          );

    // Every one of these is a measurement, so every one of them is a
    // Readout (05 §3): mono value, quiet uppercase label, em dash when the
    // number is not known.
    final summaryReadouts = <Readout>[
      Readout(
        size: ReadoutSize.md,
        label: elapsed == null || !elapsed.isUnfinished
            ? l10n.text('analyticsDuration')
            : '${l10n.text('analyticsDuration')} · ${elapsed.captionLabel}',
        value: isLive
            ? duration
            : quickCapturesPinned
                ? frameMetric(
                    (images) => captureSpanLabel(
                      acceptedLights(images).map((i) => i.capturedAt),
                    ),
                  )
                : elapsed?.valueLabel,
      ),
      Readout(
        size: ReadoutSize.md,
        label: l10n.text('analyticsExposures'),
        value: isLive
            ? '${sessionState.completedExposures}/${sessionState.totalExposures}'
            : frameMetric((images) {
                final lights = images.where((i) => i.isLight).length;
                final accepted = acceptedLights(images).length;
                return lights == accepted ? '$accepted' : '$accepted/$lights';
              }),
      ),
      Readout(
        size: ReadoutSize.md,
        label: l10n.text('analyticsIntegration'),
        value: isLive
            ? _formatAnalyticsIntegration(sessionState.totalIntegrationSecs)
            : frameMetric((images) {
                final seconds = acceptedLights(images).fold<double>(
                  0,
                  (sum, image) => image.exposureDuration.isFinite &&
                          image.exposureDuration > 0
                      ? sum + image.exposureDuration
                      : sum,
                );
                return _formatAnalyticsIntegration(seconds);
              }),
      ),
      Readout(
        size: ReadoutSize.md,
        // Median, not mean: a handful of clouded frames drags a mean HFR
        // upward and makes a good night look worse than it was.
        label: 'Median HFR',
        value: isLive
            ? sessionState.avgHfr?.toStringAsFixed(2)
            : frameMetric((images) {
                final hfrs = acceptedLights(images)
                    .map((image) => image.hfr)
                    .whereType<double>()
                    .where((value) => value.isFinite && value >= 0)
                    .toList()
                  ..sort();
                if (hfrs.isEmpty) return null;
                final mid = hfrs.length ~/ 2;
                final median = hfrs.length.isOdd
                    ? hfrs[mid]
                    : (hfrs[mid - 1] + hfrs[mid]) / 2;
                return median.toStringAsFixed(2);
              }),
      ),
    ];

    // The standalone bucket is a real thing — frames shot outside a sequence —
    // but it is not the no-session fallback. Show it only when it actually
    // holds frames.
    final standaloneImages =
        isStandaloneMode ? imagesAsyncValue.valueOrNull : null;
    final noStandaloneFrames = isStandaloneMode &&
        standaloneImages != null &&
        standaloneImages.isEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isPhone = constraints.maxWidth < BreakpointTokens.breakpointPhone;
        // 24 px page gutter (02 "generous page gutters"), 16 on a phone.
        final outerPadding = EdgeInsets.all(
          isPhone ? SkotiqTokens.spaceLg : SkotiqTokens.space2xl,
        );

        if (noStandaloneFrames) {
          return Padding(
            padding: outerPadding,
            child: Column(
              children: [
                // With sessions on record the picker stays: the tab has
                // something to offer, it just isn't the quick-capture bucket.
                if (allSessions.isNotEmpty) ...[
                  SkotiqPanel(
                    child: AnalyticsSessionPicker(
                      sessions: allSessions,
                      selectedId: reviewSelectionId,
                      offerQuickCaptures: offerQuickCaptures,
                      onSelected: _pick,
                    ),
                  ),
                  const SizedBox(height: SkotiqTokens.space2xl),
                ],
                Expanded(
                  // Never the History tab's copy: this tab's subject is the
                  // session in progress, so borrowing "No session history /
                  // Complete an imaging session to see history here" told the
                  // user to go do what they had just done.
                  child: AnalyticsEmptyState(
                    icon: LucideIcons.folderOpen,
                    title: allSessions.isEmpty
                        ? 'Nothing captured yet'
                        : 'No quick captures',
                    body: allSessions.isEmpty
                        ? 'Start a capture or a sequence and this tab fills in '
                            'as the frames arrive.'
                        : 'Choose a session above to review it.',
                  ),
                ),
              ],
            ),
          );
        }

        final showPicker = allSessions.isNotEmpty && !isLive;
        final reviewStatus = showPicker ? reviewSession?.status : null;

        final summaryPanel = SkotiqPanel(
          head: PanelHead(
            icon: LucideIcons.activity,
            label: l10n.text('analyticsSession'),
            trailing: [
              SegmentedControl(
                dense: true,
                segments: const ['Charts', 'Optics'],
                selectedIndex: widget.view.index,
                onSelected: (index) =>
                    widget.onViewPicked(SessionView.values[index]),
                semanticLabel: 'Session view',
              ),
              if (isLive)
                SkotiqChip(
                  label: l10n.text('analyticsLive'),
                  tone: ChipTone.success,
                  dot: true,
                ),
              if (reviewStatus != null)
                SkotiqChip(
                  label: sessionStatusLabel(reviewStatus),
                  tone: sessionStatusTone(reviewStatus),
                ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showPicker)
                AnalyticsSessionPicker(
                  sessions: allSessions,
                  selectedId: reviewSelectionId,
                  offerQuickCaptures: offerQuickCaptures,
                  onSelected: _pick,
                  onMostRecent:
                      _selectedSessionId == null ? null : () => _pick(null),
                )
              else ...[
                Text(
                  headerTitle,
                  style: SkotiqTypography.sectionTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  headerSubtitle,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: SkotiqTokens.spaceLg),
              Wrap(
                spacing: _summaryReadoutGap,
                runSpacing: SkotiqTokens.spaceLg,
                children: summaryReadouts,
              ),
            ],
          ),
        );

        if (widget.view == SessionView.optics) {
          return Padding(
            padding: outerPadding,
            child: Column(
              children: [
                summaryPanel,
                const SizedBox(height: SkotiqTokens.spaceLg),
                Expanded(
                  child: OpticsDiagnosticsView(
                    sessionId: reviewSelectionId,
                    onOpenLatest: allSessions.isEmpty
                        ? null
                        : () => _pick(
                              allSessions
                                  .reduce(
                                    (a, b) => a.startTime.isAfter(b.startTime)
                                        ? a
                                        : b,
                                  )
                                  .id,
                            ),
                  ),
                ),
              ],
            ),
          );
        }

        return SingleChildScrollView(
          padding: outerPadding,
          child: Column(
            children: [
              summaryPanel,
              const SizedBox(height: SkotiqTokens.space2xl),

              // ONE banner for ONE problem (05 §11). The charts and the
              // thumbnail strip are both drawn FROM the frames, so a failed
              // frame stream used to raise two identical banners for the same
              // failure; now it raises one and neither surface is drawn.
              if (framesError != null)
                _AnalyticsError(
                  title: 'Frames did not load',
                  error: framesError,
                  onRetry: retryImages,
                )
              else ...[
                imagesAsyncValue.when(
                  data: (frames) => SessionChartGrid(
                    frames: frames,
                    stacked: isPhone,
                    tourTargets: true,
                  ),
                  loading: () => const _AnalyticsLoading(
                    height: _chartGridSkeletonHeight,
                  ),
                  error: (_, __) => const SizedBox.shrink(),
                ),
                const SizedBox(height: SkotiqTokens.space2xl),
                SkotiqPanel(
                  head: PanelHead(
                    icon: LucideIcons.image,
                    label: l10n.text('analyticsCapturedImages'),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Quality badges are advisory. Right-click or long-press '
                        'a frame to reject it; to reject in bulk, use Science ▸ '
                        'Field quality ▸ Grade frames.',
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(height: SkotiqTokens.spaceMd),
                      imagesAsyncValue.when(
                        data: (images) => ImageThumbnailStrip(
                            key: TourTarget.analyticsThumbnails.key,
                            images: images),
                        loading: () => const _AnalyticsLoading(
                          height: kAnalyticsThumbnailRailHeight,
                        ),
                        error: (_, __) => const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The gap between two summary [Readout]s. Matches [ReadoutRow]'s default;
/// the strip uses a [Wrap] rather than a [ReadoutRow] so four readouts reflow
/// on a phone instead of overflowing.
const double _summaryReadoutGap = 28;

/// Height the chart-grid skeleton reserves so the page does not jump when the
/// four charts arrive.
const double _chartGridSkeletonHeight = 320;

/// THE loading state for Analytics: a shimmering `well` block of the height
/// the real content will take.
///
/// One pattern, not the four this screen used to carry (a bordered box with a
/// blue glyph here, a spinner there, a sentence in a card elsewhere). A
/// skeleton says "this is arriving" without claiming a number.
class _AnalyticsLoading extends StatelessWidget {
  const _AnalyticsLoading({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Never taller than the box it was handed. A skeleton that overflows
        // is a worse lie than a short one: it reports a layout error for
        // content that has not arrived yet.
        final resolved = constraints.hasBoundedHeight
            ? math.min(height, constraints.maxHeight)
            : height;
        return ShimmerLoading(
          child: Container(
            width: double.infinity,
            height: resolved,
            decoration: SkotiqDecorations.well(colors),
          ),
        );
      },
    );
  }
}

/// THE error state for Analytics: one [SkotiqBanner] in the `error` tone
/// with one action.
///
/// 05 §11: never floating, never stacked, at most one action. The bordered
/// "Failed to load…" box with its own icon column and its own radius was a
/// second banner style living inside one screen.
class _AnalyticsError extends StatelessWidget {
  const _AnalyticsError({
    required this.title,
    required this.error,
    this.onRetry,
  });

  /// What failed, in one short sentence.
  final String title;

  /// Why, shown as the person-readable sentence of the error.
  final Object error;

  /// Retry handler; the banner's single action.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return SkotiqBanner(
      title: title,
      message: userFacingError(error),
      tone: BannerTone.error,
      action: onRetry == null
          ? null
          : SkotiqButton(
              label: 'Retry',
              icon: LucideIcons.refreshCw,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: onRetry,
            ),
    );
  }
}

/// Null (not 'No data') when there is nothing to report: the caller is a
/// [Readout], whose one way of saying "unknown" is the em dash.
String? _formatAnalyticsIntegration(double seconds) =>
    !seconds.isFinite || seconds <= 0
        ? null
        : DurationFormat.seconds(seconds, style: DurationStyle.short);

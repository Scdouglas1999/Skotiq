// ignore_for_file: unused_element_parameter

part of '../analytics_screen.dart';

class _SessionTab extends ConsumerStatefulWidget {
  const _SessionTab({super.key});

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
  int? _selectedSessionId;

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
        ref.watch(latestScienceSessionProvider).valueOrNull;
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
                'time': DateFormat('MMM d, yyyy HH:mm')
                    .format(sessionState.startTime!),
              },
            )
          : l10n.text('analyticsSessionInProgress');
    } else if (reviewSession != null) {
      headerTitle = reviewSession.name ?? l10n.text('analyticsUnnamedSession');
      headerSubtitle =
          '${DateFormat('EEE MMM d, yyyy · HH:mm').format(reviewSession.startTime)}'
          '  ·  ${reviewSession.status}';
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
        value: isLive ? duration : elapsed?.valueLabel,
      ),
      Readout(
        size: ReadoutSize.md,
        label: l10n.text('analyticsExposures'),
        value: isLive
            ? '${sessionState.completedExposures}/${sessionState.totalExposures}'
            : frameMetric((images) {
                final lights = images
                    .where((i) => i.frameType.toLowerCase() == 'light')
                    .length;
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
                  _SessionReviewBar(
                    sessions: allSessions,
                    selectedId: reviewSelectionId,
                    offerQuickCaptures: offerQuickCaptures,
                    onSelected: (id) => setState(() => _selectedSessionId = id),
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

        Widget chartGrid(List<DbCapturedImage> allImages) {
          // One population for all four charts, and it is the same one the
          // stat strip above counts.
          final images = acceptedLights(allImages);
          final excluded = allImages.length - images.length;
          // Four ~250 px cards that each say "No … recorded" are one fact
          // stated four times. When no plotted frame carries any of the four
          // measurements, say it once; one frame with one value brings the
          // charts back.
          final anythingToPlot = images.any(
            (image) =>
                image.hfr != null ||
                image.guidingRmsTotal != null ||
                image.focuserPosition != null ||
                image.sensorTemp != null,
          );
          if (!anythingToPlot) {
            return _NothingToChart(
              accepted: images.length,
              excluded: excluded,
            );
          }
          final hfr =
              HfrChart(key: AnalyticsTutorialKeys.hfrChart, images: images);
          final guiding = GuidingRmsChart(
              key: AnalyticsTutorialKeys.guidingChart, images: images);
          final focuser = FocuserPositionChart(images: images);
          final temperature = TemperatureChart(images: images);
          // Say which frames are plotted rather than letting the reader assume
          // the charts cover everything the session captured.
          final population = Container(
            width: double.infinity,
            padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
            child: Text(
              excluded == 0
                  ? 'All four charts plot the same ${images.length} accepted light frames.'
                  : 'All four charts plot the same ${images.length} accepted light frames '
                      '· $excluded excluded (rejected or calibration)',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          );

          // Phone: a single column of full-width charts so each reads at the
          // viewport width. Tablet/desktop keep the 2-up grid.
          if (isPhone) {
            return Column(
              children: [
                population,
                hfr,
                const SizedBox(height: SkotiqTokens.spaceLg),
                guiding,
                const SizedBox(height: SkotiqTokens.spaceLg),
                focuser,
                const SizedBox(height: SkotiqTokens.spaceLg),
                temperature,
              ],
            );
          }
          return Column(
            children: [
              population,
              Row(
                children: [
                  Expanded(child: hfr),
                  const SizedBox(width: SkotiqTokens.spaceLg),
                  Expanded(child: guiding),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceLg),
              Row(
                children: [
                  Expanded(child: focuser),
                  const SizedBox(width: SkotiqTokens.spaceLg),
                  Expanded(child: temperature),
                ],
              ),
            ],
          );
        }

        // With sessions to pick from, the picker IS the session's identity:
        // it names the session and its date, so the panel does not repeat
        // them in a title and subtitle under a second bar that said the same.
        final showPicker = allSessions.isNotEmpty && !isLive;
        final reviewStatus = showPicker ? reviewSession?.status : null;

        return SingleChildScrollView(
          padding: outerPadding,
          child: Column(
            children: [
              // Session summary — one panel: the eyebrow head names it, the
              // session's own name and date sit under it, and the four numbers
              // are Readouts that wrap instead of overflowing a phone column.
              SkotiqPanel(
                head: PanelHead(
                  icon: LucideIcons.activity,
                  label: l10n.text('analyticsSession'),
                  trailing: [
                    if (isLive)
                      SkotiqChip(
                        label: l10n.text('analyticsLive'),
                        tone: ChipTone.success,
                        dot: true,
                      ),
                    if (reviewStatus != null)
                      SkotiqChip(
                        label: reviewStatus,
                        tone: _SessionHistoryCard._statusTone(reviewStatus),
                      ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showPicker)
                      _SessionReviewBar(
                        sessions: allSessions,
                        selectedId: reviewSelectionId,
                        offerQuickCaptures: offerQuickCaptures,
                        framed: false,
                        onSelected: (id) =>
                            setState(() => _selectedSessionId = id),
                        onClear: _selectedSessionId == null
                            ? null
                            : () => setState(() => _selectedSessionId = null),
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
              ),

              const SizedBox(height: SkotiqTokens.space2xl),

              // ONE banner for ONE problem (05 §11). The charts and the
              // thumbnail strip are both drawn FROM the frames, so a failed
              // frame stream used to raise two identical banners for the same
              // failure; now it raises one and neither surface is drawn.
              if (framesError != null)
                _AnalyticsError(
                  title: 'Frames did not load',
                  message: framesError.toString(),
                  onRetry: retryImages,
                )
              else ...[
                // Graph grid
                imagesAsyncValue.when(
                  data: chartGrid,
                  loading: () => const _AnalyticsLoading(
                    height: _chartGridSkeletonHeight,
                  ),
                  error: (_, __) => const SizedBox.shrink(),
                ),

                const SizedBox(height: SkotiqTokens.space2xl),

                // Captured images strip
                SkotiqPanel(
                  head: PanelHead(
                    icon: LucideIcons.image,
                    label: l10n.text('analyticsCapturedImages'),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // One line, not the four-sentence reassurance that used
                      // to sit here: the only fact a reader cannot get from
                      // the badges themselves is WHERE the bulk grader lives.
                      Text(
                        'Quality badges are advisory. To reject frames in '
                        'bulk, use Science ▸ Field quality ▸ Grade frames.',
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(height: SkotiqTokens.spaceMd),
                      imagesAsyncValue.when(
                        data: (images) => ImageThumbnailStrip(
                            key: AnalyticsTutorialKeys.thumbnails,
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

/// The chart grid's state when no plotted frame has anything to plot: one
/// line in place of four empty charts.
class _NothingToChart extends StatelessWidget {
  const _NothingToChart({required this.accepted, required this.excluded});

  /// Accepted light frames — the population the charts would plot.
  final int accepted;

  /// Frames left out of that population (rejected or calibration).
  final int excluded;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final what = accepted == 0
        ? 'No accepted light frames to chart'
        : 'None of the $accepted accepted light frames recorded HFR, '
            'guiding RMS, focuser position or sensor temperature';
    return SkotiqPanel(
      child: Row(
        children: [
          Icon(
            LucideIcons.lineChart,
            size: SkotiqTokens.iconSm,
            color: colors.textMuted,
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              excluded == 0
                  ? what
                  : '$what · $excluded excluded (rejected or calibration)',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
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

  /// How much vertical space to hold open.
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
    this.message,
    this.onRetry,
  });

  /// What failed, in one short sentence.
  final String title;

  /// The detail — usually the exception's message.
  final String? message;

  /// Retry handler; the banner's single action.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return SkotiqBanner(
      title: title,
      message: message,
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
String? _formatAnalyticsIntegration(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return null;
  final rounded = seconds.round();
  if (rounded < 60) return '${rounded}s';
  if (rounded < 3600) {
    final minutes = rounded ~/ 60;
    final remainder = rounded % 60;
    return remainder == 0 ? '${minutes}m' : '${minutes}m ${remainder}s';
  }
  final hours = rounded ~/ 3600;
  final minutes = (rounded % 3600) ~/ 60;
  return '${hours}h ${minutes}m';
}

/// Provider for watching session images (Drift rows) on the Analytics screen.
///
/// Renamed from `sessionImagesProvider` (which collided with the
/// in-memory `sessionImagesProvider` in skotiq_core) so importers don't
/// have to `hide` either declaration.
final dbSessionImagesProvider =
    StreamProvider.family<List<DbCapturedImage>, int>((ref, sessionId) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteSessionImages(
      backend,
      sessionId,
      interval: ref.watch(analyticsRemoteImagePollIntervalProvider),
    );
  }
  return ref.watch(imagesDaoProvider).watchImagesForSession(sessionId);
});

/// Provider for watching standalone (sessionless) images
final standaloneImagesProvider = StreamProvider<List<DbCapturedImage>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteStandaloneImages(
      backend,
      interval: ref.watch(analyticsRemoteImagePollIntervalProvider),
    );
  }
  return ref.watch(imagesDaoProvider).watchStandaloneImages();
});

/// Remote image catalogs are low-churn and do not need to hammer the host.
/// Exposed so tests can exercise retry/distinct behavior without waiting 10s.
final analyticsRemoteImagePollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 10),
);

/// The label of the History target filter's "no filter" entry.
const String kAllTargetsFilter = 'All Targets';

/// The label of the History target filter's "sessions with no target" entry.
/// Only offered when at least one session actually has a null `targetId`.
const String kUntargetedSessionsFilter = 'Untargeted sessions';

/// Options for the History tab's target filter — REAL targets.
///
/// The filter lists rows from `targets`, not session names; session names
/// remain filterable through the search field beside the dropdown.
///
/// The list is the names of the targets that the recorded sessions actually
/// reference (a target with no sessions would filter to nothing), plus
/// [kUntargetedSessionsFilter] when some sessions carry no target.
final sessionTargetNamesProvider = Provider<AsyncValue<List<String>>>((ref) {
  final sessionsAsync = ref.watch(allSessionsProvider);
  final targetsAsync = ref.watch(allDbTargetsProvider);
  if (sessionsAsync.hasError) {
    return AsyncValue.error(sessionsAsync.error!, sessionsAsync.stackTrace!);
  }
  if (targetsAsync.hasError) {
    return AsyncValue.error(targetsAsync.error!, targetsAsync.stackTrace!);
  }
  final sessions = sessionsAsync.valueOrNull;
  final targets = targetsAsync.valueOrNull;
  if (sessions == null || targets == null) return const AsyncValue.loading();

  final nameById = {for (final t in targets) t.id: t.name};
  final referenced = <String>{};
  var hasUntargeted = false;
  for (final session in sessions) {
    final id = session.targetId;
    final name = id == null ? null : nameById[id];
    if (name != null && name.isNotEmpty) {
      referenced.add(name);
    } else {
      hasUntargeted = true;
    }
  }
  final sorted = referenced.toList()..sort();
  return AsyncValue.data([
    kAllTargetsFilter,
    ...sorted,
    if (hasUntargeted && sorted.isNotEmpty) kUntargetedSessionsFilter,
  ]);
});

/// Maps a target-filter label to the predicate the History list applies.
/// Exposed (rather than inlined in the tab) so the mapping is unit-testable and
/// cannot drift from [sessionTargetNamesProvider]'s labels.
bool sessionMatchesTargetFilter(
  ImagingSession session,
  String filter,
  Map<int, String> targetNameById,
) {
  if (filter == kAllTargetsFilter) return true;
  final id = session.targetId;
  final name = id == null ? null : targetNameById[id];
  if (filter == kUntargetedSessionsFilter) {
    return name == null || name.isEmpty;
  }
  return name == filter;
}

/// Picks which past session the Session tab is reviewing.
class _SessionReviewBar extends StatelessWidget {
  final List<ImagingSession> sessions;
  final int? selectedId;

  /// Whether to list [kQuickCaptureSessionSelection] — the frames shot outside
  /// any session. Diagnostics has always offered it; leaving it off the other
  /// two pickers is what made the quick captures a one-way door.
  final bool offerQuickCaptures;
  final ValueChanged<int?> onSelected;
  final VoidCallback? onClear;

  /// False when the bar sits inside the session panel, which is already the
  /// frame around it.
  final bool framed;

  const _SessionReviewBar({
    required this.sessions,
    required this.selectedId,
    required this.onSelected,
    this.offerQuickCaptures = false,
    this.onClear,
    this.framed = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final format = DateFormat('MMM d, yyyy HH:mm');
    final hasSelection =
        (offerQuickCaptures && selectedId == kQuickCaptureSessionSelection) ||
            sessions.any((s) => s.id == selectedId);

    // A labelled control, so it is a FormRow (05 §8): the label sits to the
    // LEFT of the field, not above it and not as a sentence beside it. The
    // container is a panel, not the deprecated `surfaceAlt` box it was.
    final row = Row(
      children: [
        Expanded(
          child: FormRow(
            label: 'Reviewing',
            child: DropdownButtonHideUnderline(
              child: AccessibleDropdown<int>(
                value: hasSelection ? selectedId : null,
                isExpanded: true,
                isDense: true,
                dropdownColor: colors.surfaceElevated,
                borderRadius: SkotiqTokens.borderRadiusMd,
                hint: Text(
                  'Quick captures (no session selected)',
                  style:
                      SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
                ),
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
                onChanged: onSelected,
                items: [
                  // First, and named exactly as Diagnostics names it: an
                  // operator who learns the entry on one tab finds it on all.
                  if (offerQuickCaptures)
                    DropdownMenuItem<int>(
                      value: kQuickCaptureSessionSelection,
                      child: Text(
                        kQuickCaptureSessionLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.bodySm
                            .copyWith(color: colors.textPrimary),
                      ),
                    ),
                  for (final session in sessions.take(60))
                    DropdownMenuItem<int>(
                      value: session.id,
                      child: Text(
                        '${session.name ?? 'Session ${session.id}'}'
                        '  ·  ${format.format(session.startTime)}'
                        // "frames returned": `successful_exposures` counts
                        // what the camera handed back, not what the culling
                        // kept.
                        '  ·  ${session.successfulExposures} frames returned',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.bodySm
                            .copyWith(color: colors.textPrimary),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (onClear != null) ...[
          const SizedBox(width: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: 'Most recent',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: onClear,
          ),
        ],
      ],
    );
    if (!framed) return row;
    return SkotiqPanel(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceMd,
      ),
      child: row,
    );
  }
}

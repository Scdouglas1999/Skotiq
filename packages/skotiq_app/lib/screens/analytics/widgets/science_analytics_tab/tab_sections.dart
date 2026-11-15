// ignore_for_file: invalid_use_of_protected_member
// Navigation helpers, session bar, paired cards and science-data state sections.
part of '../science_analytics_tab.dart';

/// The page gutter under the view switch, which already holds the top of the
/// page.
EdgeInsets _bodyPadding(BuildContext context) {
  final side = Responsive.isPhone(context)
      ? SkotiqTokens.spaceLg
      : SkotiqTokens.space2xl;
  return EdgeInsets.fromLTRB(side, SkotiqTokens.spaceLg, side, side);
}

extension _ScienceAnalyticsTabSections on _ScienceAnalyticsTabState {
  void _jumpTo(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: 0.05,
    );
  }

  void _openExportHub(
    BuildContext context,
    List<MovingObjectCandidateRow> mpcCandidates,
  ) {
    showDialog(
      context: context,
      builder: (_) => ScienceExportHub(mpcCandidates: mpcCandidates),
    );
  }

  void _openCalibrationWizard(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const PhotometricCalibrationWizard(),
    );
  }

  /// Rung 2's 'Pick a target', and the photometry destination on the empty
  /// branch.
  ///
  /// The only control that sets a photometry target is the science HUD over
  /// the live frame, so this sends the operator there with the HUD already
  /// open — Analytics itself has nowhere to pick one.
  void _goPickPhotometryTarget(BuildContext context) {
    final mode = ref.read(scienceModeStateProvider);
    if (!mode.scienceHudVisible) {
      ref.read(scienceModeStateProvider.notifier).state =
          mode.copyWith(scienceHudVisible: true);
    }
    GoRouter.maybeOf(context)?.go(AppRoute.imaging.path);
  }

  /// Which session the panels below are reporting on, and a way to change it.
  Widget _sessionBar({
    required List<ImagingSession> sessions,
    required int? activeSessionId,
    required bool isLive,
    bool offerQuickCaptures = false,
  }) {
    if (sessions.isEmpty && !offerQuickCaptures) return const SizedBox.shrink();
    void pick(int? id) {
      // periodAnalysisProvider is one result with no session key, so a period
      // searched on another session would stay on screen and mark the guide's
      // "Find the period" step done for a session never searched.
      ref.read(periodAnalysisProvider.notifier).clear();
      ref.read(analyticsSessionPickProvider.notifier).state = id;
      // The frame picked in the old session means nothing here.
      setState(() => _selectedFrameImageId = null);
    }

    return SkotiqPanel(
      child: Row(
        children: [
          Expanded(
            child: AnalyticsSessionPicker(
              sessions: sessions,
              selectedId: activeSessionId,
              offerQuickCaptures: offerQuickCaptures,
              onSelected: pick,
              onMostRecent:
                  _selectedSessionId == null ? null : () => pick(null),
            ),
          ),
          if (isLive) ...[
            const SizedBox(width: SkotiqTokens.spaceSm),
            const SkotiqChip(label: 'Live', tone: ChipTone.success, dot: true),
          ],
        ],
      ),
    );
  }

  Widget _pairedCards(bool isNarrow, Widget first, Widget second) {
    if (isNarrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          first,
          const SizedBox(height: 12),
          second,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: first),
        const SizedBox(width: 12),
        Expanded(child: second),
      ],
    );
  }

  /// Before the sessions on record are known the tab has nothing to report
  /// on: a skeleton while they load, one error with Retry if they failed.
  Widget _buildSessionIndexState(
    AsyncValue<List<ImagingSession>> sessionsAsync,
  ) {
    final error = sessionsAsync.error;
    if (error != null) {
      return Center(
        child: EmptyState.error(
          title: 'Sessions did not load',
          body: userFacingError(error),
          onRetry: () => ref.invalidate(allSessionsProvider),
        ),
      );
    }
    return const _ScienceSkeleton();
  }

  Widget _buildScienceDataState({
    required int? activeSessionId,
    required bool isLoading,
    required List<Object> errors,
    required int storedFrameCount,
    List<ImagingSession> sessions = const [],
    bool offerQuickCaptures = false,
    bool isLive = false,
  }) {
    return SingleChildScrollView(
      controller: _scrollController,
      padding: _bodyPadding(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The picker belongs here too: this branch is exactly when the
          // operator most wants to point the tab at a different night, and
          // dropping it meant a science query that was slow or failing took
          // the only way out of that session with it.
          _sessionBar(
            sessions: sessions,
            activeSessionId: activeSessionId,
            offerQuickCaptures: offerQuickCaptures,
            isLive: isLive,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          ScienceStatusBanner(storedFrameCount: storedFrameCount),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _buildScienceDataNotice(
            activeSessionId: activeSessionId,
            isLoading: isLoading,
            errors: errors,
          ),
        ],
      ),
    );
  }

  /// Loading is a skeleton; a failure is one banner naming the first error,
  /// with Retry.
  Widget _buildScienceDataNotice({
    required int? activeSessionId,
    required bool isLoading,
    required List<Object> errors,
  }) {
    if (errors.isEmpty) {
      return isLoading ? const _ScienceSkeleton(height: 96) : const SizedBox();
    }
    final more = errors.length - 1;
    return SkotiqBanner(
      tone: BannerTone.error,
      title: 'Some science data did not load',
      message: '${userFacingError(errors.first)}'
          '${more > 0 ? ' And $more more.' : ''}',
      action: SkotiqButton(
        label: 'Retry',
        icon: LucideIcons.refreshCw,
        size: ButtonSize.small,
        variant: ButtonVariant.secondary,
        onPressed: () => _retryScienceData(activeSessionId),
      ),
    );
  }

  void _retryScienceData(int? sessionId) {
    ref.invalidate(allSessionsProvider);
    ref.invalidate(sciencePhotometrySelectionProvider);
    if (sessionId == null) {
      ref.invalidate(sessionlessPhotometryProvider);
      ref.invalidate(sessionlessTransparencySamplesProvider);
      ref.invalidate(sessionlessCalibrationsProvider);
      ref.invalidate(sessionlessPsfTilesProvider);
      ref.invalidate(sessionlessResidualVectorsProvider);
      ref.invalidate(sessionlessMovingObjectCandidatesProvider);
      ref.invalidate(sessionlessLineRatioProductsProvider);
      ref.invalidate(sessionlessFrameQualityMetricsProvider);
      ref.invalidate(sessionlessTileMetricsProvider);
      ref.invalidate(standaloneImagesProvider);
      return;
    }
    ref.invalidate(sessionPhotometryProvider(sessionId));
    ref.invalidate(sessionTransparencySamplesProvider(sessionId));
    ref.invalidate(sessionFrameCalibrationsProvider(sessionId));
    ref.invalidate(sessionPsfTilesProvider(sessionId));
    ref.invalidate(sessionResidualVectorsProvider(sessionId));
    ref.invalidate(sessionMovingObjectCandidatesProvider(sessionId));
    ref.invalidate(sessionLineRatioProductsProvider(sessionId));
    ref.invalidate(sessionFrameQualityMetricsProvider(sessionId));
    ref.invalidate(frameTileMetricsProvider);
    ref.invalidate(dbSessionImagesProvider(sessionId));
  }
}

/// Science's loading state: a shimmering well the height of what is coming.
class _ScienceSkeleton extends StatelessWidget {
  const _ScienceSkeleton({this.height});

  /// Null fills the tab with the page gutter around it.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final block = ShimmerLoading(
      child: Container(
        width: double.infinity,
        height: height ?? 240,
        decoration: SkotiqDecorations.well(colors),
      ),
    );
    if (height != null) return block;
    return Padding(
      padding: _bodyPadding(context),
      child: Align(alignment: Alignment.topCenter, child: block),
    );
  }
}

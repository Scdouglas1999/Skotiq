part of '../diagnostics_screen.dart';

class _DiagnosticsContent extends ConsumerWidget {
  final int sessionId;
  final bool isMobile;

  const _DiagnosticsContent({
    required this.sessionId,
    required this.isMobile,
  });

  /// True when this is the quick-capture bucket rather than a real session
  /// row — its science products carry a NULL session_id and are read through
  /// the `sessionless*` providers.
  bool get _isQuickCapture => sessionId == _kQuickCaptureSessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final psfAsync = _isQuickCapture
        ? ref.watch(sessionlessPsfTilesProvider)
        : ref.watch(psfTilesForSessionProvider(sessionId));
    final residualsAsync = _isQuickCapture
        ? ref.watch(sessionlessResidualVectorsProvider)
        : ref.watch(residualVectorsForSessionProvider(sessionId));
    // The per-session provider memoizes `analyze()`; the quick-capture bucket
    // has no session key to memoize on, so it runs the same service over the
    // sessionless rows with the same loading/error precedence.
    final diagnosticsAsync = _isQuickCapture
        ? _analyzeQuickCapture(ref, psfAsync, residualsAsync)
        : ref.watch(opticalTrainDiagnosticsProvider(sessionId));

    return diagnosticsAsync.when(
      data: (diagnostics) {
        final psfTiles = psfAsync.valueOrNull ?? const [];
        final residuals = residualsAsync.valueOrNull ?? const [];

        return LayoutBuilder(
          builder: (context, constraints) {
            final stackLayout = isMobile ||
                constraints.maxWidth < SkotiqTokens.breakpointTablet;
            if (stackLayout) {
              return _MobileLayout(
                diagnostics: diagnostics,
                psfTiles: psfTiles,
                residuals: residuals,
                colors: colors,
              );
            }
            return _DesktopLayout(
              diagnostics: diagnostics,
              psfTiles: psfTiles,
              residuals: residuals,
              colors: colors,
              maxWidth: constraints.maxWidth,
            );
          },
        );
      },
      // Shimmer grid placeholder keeps the diagnostics card layout in place
      // while the analysis stream loads, instead of collapsing to a spinner.
      loading: () => const _DiagnosticsLoadingSkeleton(),
      error: (error, stack) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.alertTriangle, size: 32, color: colors.error),
            const SizedBox(height: 12),
            Text(
              context.l10n.text('diagnosticsFailedTitle'),
              style:
                  SkotiqTypography.h4.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.text('diagnosticsFailedBody'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            SkotiqButton(
              label: context.l10n.text('diagnosticsRetry'),
              icon: LucideIcons.refreshCw,
              size: ButtonSize.small,
              onPressed: () {
                if (_isQuickCapture) {
                  ref.invalidate(sessionlessPsfTilesProvider);
                  ref.invalidate(sessionlessResidualVectorsProvider);
                  return;
                }
                ref.invalidate(opticalTrainDiagnosticsProvider(sessionId));
                ref.invalidate(psfTilesForSessionProvider(sessionId));
                ref.invalidate(residualVectorsForSessionProvider(sessionId));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Mirrors `opticalTrainDiagnosticsProvider`'s precedence — an error on
  /// either source wins, then loading, then the analysis — for the bucket of
  /// science products that belongs to no session.
  AsyncValue<OpticalTrainDiagnostics> _analyzeQuickCapture(
    WidgetRef ref,
    AsyncValue<List<PsfFieldTileRow>> psfAsync,
    AsyncValue<List<AstrometryResidualVectorRow>> residualsAsync,
  ) {
    if (psfAsync.hasError) {
      return AsyncValue.error(
        psfAsync.error!,
        psfAsync.stackTrace ?? StackTrace.current,
      );
    }
    if (residualsAsync.hasError) {
      return AsyncValue.error(
        residualsAsync.error!,
        residualsAsync.stackTrace ?? StackTrace.current,
      );
    }
    if (psfAsync.isLoading || residualsAsync.isLoading) {
      return const AsyncValue.loading();
    }
    return AsyncValue.data(
      ref.watch(opticalTrainDiagnosticsServiceProvider).analyze(
            psfTiles: psfAsync.value ?? const [],
            residualVectors: residualsAsync.value ?? const [],
          ),
    );
  }
}

class _DesktopLayout extends StatelessWidget {
  final OpticalTrainDiagnostics diagnostics;
  final List<PsfFieldTileRow> psfTiles;
  final List<AstrometryResidualVectorRow> residuals;
  final SkotiqColors colors;
  final double maxWidth;

  const _DesktopLayout({
    required this.diagnostics,
    required this.psfTiles,
    required this.residuals,
    required this.colors,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final panelWidth = clampPanelWidth(
      maxWidth,
      fraction: 0.32,
      min: 280,
      max: 320,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left column: health grade + issues
        SizedBox(
          width: panelWidth,
          child: SingleChildScrollView(
            child: Column(
              children: [
                _HealthGradeCard(diagnostics: diagnostics, colors: colors),
                const SizedBox(height: 12),
                _TiltAssessmentCard(diagnostics: diagnostics, colors: colors),
                const SizedBox(height: 12),
                _CollimationCard(diagnostics: diagnostics, colors: colors),
                const SizedBox(height: 12),
                _IssuesCard(diagnostics: diagnostics, colors: colors),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        // Right column: field map + residual overlay
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                _PsfFieldMapCard(
                  psfTiles: psfTiles,
                  colors: colors,
                ),
                const SizedBox(height: 12),
                _ResidualVectorCard(
                  residuals: residuals,
                  colors: colors,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileLayout extends StatelessWidget {
  final OpticalTrainDiagnostics diagnostics;
  final List<PsfFieldTileRow> psfTiles;
  final List<AstrometryResidualVectorRow> residuals;
  final SkotiqColors colors;

  const _MobileLayout({
    required this.diagnostics,
    required this.psfTiles,
    required this.residuals,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          _HealthGradeCard(diagnostics: diagnostics, colors: colors),
          const SizedBox(height: 12),
          _TiltAssessmentCard(diagnostics: diagnostics, colors: colors),
          const SizedBox(height: 12),
          _CollimationCard(diagnostics: diagnostics, colors: colors),
          const SizedBox(height: 12),
          _PsfFieldMapCard(psfTiles: psfTiles, colors: colors),
          const SizedBox(height: 12),
          _ResidualVectorCard(residuals: residuals, colors: colors),
          const SizedBox(height: 12),
          _IssuesCard(diagnostics: diagnostics, colors: colors),
        ],
      ),
    );
  }
}

// Health grade card

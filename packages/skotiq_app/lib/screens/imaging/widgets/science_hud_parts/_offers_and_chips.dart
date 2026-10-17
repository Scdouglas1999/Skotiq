// Authority notice, feature toggle, contextual offers and overlay chips.
part of '../science_hud.dart';

class _ScienceHudAuthorityNotice extends StatelessWidget {
  const _ScienceHudAuthorityNotice({
    required this.colors,
    required this.error,
    required this.additionalErrorCount,
    required this.onRetry,
  });

  final SkotiqColors colors;
  final Object error;
  final int additionalErrorCount;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: SkotiqDecorations.emphasisSurface(colors.error),
      child: Row(
        children: [
          Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Some science controls are unavailable: $error'
              '${additionalErrorCount > 0 ? ' (+$additionalErrorCount more)' : ''}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _FeatureToggle extends StatelessWidget {
  final SkotiqColors colors;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// When false the toggle is disabled and greyed — science config is scoped to
  /// an active capture session, so the switch cannot persist without one.
  final bool enabled;

  const _FeatureToggle({
    required this.colors,
    required this.title,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: SkotiqTypography.captionSm.copyWith(
                color: enabled ? colors.textSecondary : colors.textMuted,
              ),
            ),
          ),
          SkotiqSwitch(
            value: value,
            onChanged: enabled ? onChanged : null,
            enabled: enabled,
          ),
        ],
      ),
    );
  }
}

/// Contextual one-tap suggestions for the imaging HUD. Implements P3.1.
///
/// Two rules today:
///   * **Moving objects**: when the session has 3+ light frames in the same
///     filter we offer to enable moving-object mode, since the detector
///     needs multiple frames to work.
///   * **Narrowband ratios**: when the session contains at least one frame
///     in each of Ha / OIII / SII we offer to enable narrowband tools.
///
/// Both suggestions self-suppress as soon as the corresponding feature is
/// enabled, so they're informational nudges rather than recurring nags.
class _ContextualOffers extends ConsumerWidget {
  final SkotiqColors colors;
  final ScienceSessionConfig sessionConfig;
  final bool actionsEnabled;
  final VoidCallback onEnableMovingObjects;
  final VoidCallback onEnableNarrowband;

  const _ContextualOffers({
    required this.colors,
    required this.sessionConfig,
    required this.actionsEnabled,
    required this.onEnableMovingObjects,
    required this.onEnableNarrowband,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = ref.watch(sessionStateProvider).dbSessionId;
    if (sessionId == null) return const SizedBox.shrink();
    if (sessionConfig.movingObjectsEnabled && sessionConfig.narrowbandEnabled) {
      return const SizedBox.shrink();
    }

    final imageStream = ref.watch(_huddedImagesProvider(sessionId));
    final images = imageStream.valueOrNull ?? const <DbCapturedImage>[];
    if (images.isEmpty) return const SizedBox.shrink();

    final lights = images
        .where((image) => image.frameType.toLowerCase() == 'light')
        .toList(growable: false);

    final filterCounts = <String, int>{};
    for (final image in lights) {
      final f = (image.filter ?? '').toUpperCase();
      if (f.isEmpty) continue;
      filterCounts[f] = (filterCounts[f] ?? 0) + 1;
    }

    final hasNarrowband = _hasFilter(filterCounts, ['HA', 'H-ALPHA']) &&
        _hasFilter(filterCounts, ['OIII', 'O3']) &&
        _hasFilter(filterCounts, ['SII', 'S2']);

    final tiles = <Widget>[];

    if (!sessionConfig.movingObjectsEnabled && lights.length >= 3) {
      tiles.add(_OfferTile(
        colors: colors,
        icon: LucideIcons.rocket,
        title: 'Enable moving-object detection?',
        body:
            'You have ${lights.length} light frames — enough for the detector to spot drifting candidates.',
        onAccept: actionsEnabled ? onEnableMovingObjects : null,
      ));
    }

    if (!sessionConfig.narrowbandEnabled && hasNarrowband) {
      tiles.add(_OfferTile(
        colors: colors,
        icon: LucideIcons.slidersHorizontal,
        title: 'Enable narrowband ratios?',
        body:
            'Ha, OIII, and SII frames are all present — Skotiq can produce line ratios from this session.',
        onAccept: actionsEnabled ? onEnableNarrowband : null,
      ));
    }

    if (tiles.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(children: tiles),
    );
  }

  bool _hasFilter(Map<String, int> counts, List<String> aliases) {
    for (final alias in aliases) {
      if ((counts[alias] ?? 0) > 0) return true;
    }
    return false;
  }
}

/// Internal family provider so the contextual offers widget only fetches the
/// session's image list once per session id change. Drift de-dupes parallel
/// watchers automatically.
///
/// Routes through [imagingRecordsRepositoryProvider], which already branches on
/// `NetworkBackend` and polls the host's session image rows on a slave. Without
/// that branch the slave reads its empty local SQLite (the master is the node
/// actually capturing) and the contextual nudge tiles never appear.
final _huddedImagesProvider =
    StreamProvider.family<List<DbCapturedImage>, int>((ref, sessionId) {
  return ref
      .watch(imagingRecordsRepositoryProvider)
      .watchImagesForSession(sessionId);
});

class _OfferTile extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback? onAccept;

  const _OfferTile({
    required this.colors,
    required this.icon,
    required this.title,
    required this.body,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
        decoration: SkotiqDecorations.emphasisSurface(
          colors.info,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 14, color: colors.info),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: SkotiqTypography.labelStrongSm
                        .copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            SkotiqButton(
              onPressed: onAccept,
              label: 'Enable',
              variant: ButtonVariant.outline,
              size: ButtonSize.small,
            ),
          ],
        ),
      ),
    );
  }
}

/// Tiny progress indicator that surfaces how many more calibrated frames are
/// needed before transparency estimates stabilise. Implements P3.2.
class _TransparencyUnlockProgress extends ConsumerWidget {
  final SkotiqColors colors;

  const _TransparencyUnlockProgress({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = ref.watch(sessionStateProvider).dbSessionId;
    if (sessionId == null) return const SizedBox.shrink();

    final calibrationsAsync =
        ref.watch(sessionFrameCalibrationsProvider(sessionId));
    final transparencyAsync =
        ref.watch(sessionTransparencySamplesProvider(sessionId));
    final error = calibrationsAsync.error ?? transparencyAsync.error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
        child: _ScienceHudAuthorityNotice(
          colors: colors,
          error: error,
          additionalErrorCount:
              calibrationsAsync.hasError && transparencyAsync.hasError ? 1 : 0,
          onRetry: () {
            ref.invalidate(sessionFrameCalibrationsProvider(sessionId));
            ref.invalidate(sessionTransparencySamplesProvider(sessionId));
          },
        ),
      );
    }
    if (calibrationsAsync.isLoading || transparencyAsync.isLoading) {
      return Padding(
        padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
        child: LinearProgressIndicator(
          minHeight: 2,
          color: colors.primary,
          backgroundColor: colors.border,
        ),
      );
    }
    final calibrationRows = calibrationsAsync.valueOrNull ??
        const <FramePhotometricCalibrationRow>[];
    final transparency =
        transparencyAsync.valueOrNull ?? const <TransparencySampleRow>[];
    if (transparency.isNotEmpty) return const SizedBox.shrink();

    final calibrated = calibrationRows.where((row) => row.isCalibrated).length;
    const target = ScienceInsightsEngine.minCalibratedForTransparency;
    if (calibrated >= target) return const SizedBox.shrink();
    final ratio = (calibrated / target).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.only(
        left: SkotiqTokens.spaceXs,
        right: SkotiqTokens.spaceXs,
        bottom: SkotiqTokens.spaceSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.cloud, size: 11, color: colors.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Transparency unlocks at $calibrated / $target calibrated frames',
                  style: SkotiqTypography.captionSm
                      .copyWith(color: colors.textMuted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          SkotiqProgressBar(
            value: ratio,
            style: SkotiqProgressStyle.thin,
            foregroundColor: colors.info,
          ),
        ],
      ),
    );
  }
}

class _OverlayChip extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _OverlayChip({
    required this.colors,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceSm,
          vertical: SkotiqTokens.spaceXs,
        ),
        decoration: active
            ? SkotiqDecorations.selectedSurface(
                colors.primary,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
                fillAlpha: 0.2,
              )
            : BoxDecoration(
                color: colors.surfaceAlt,
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
              ),
        child: Text(
          label,
          style: SkotiqTypography.captionSm.copyWith(
            color: active ? colors.primary : colors.textSecondary,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

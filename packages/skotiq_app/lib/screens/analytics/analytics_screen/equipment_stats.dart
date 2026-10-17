// ignore_for_file: unused_element_parameter

part of '../analytics_screen.dart';

/// Metrics with no persisted backing source render this instead of a fake
/// number — the imaging pipeline does not currently track them.

/// A run's stats blob, or null when it is missing or malformed.
///
/// A single unparseable row must not take the whole tab down; it contributes
/// nothing to the totals instead.
ParsedRunStats? _parseRunStats(String json) {
  try {
    return ParsedRunStats.fromJson(json);
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

/// The tab's four panels, in reading order, each with the glyph its device
/// carries everywhere else in the app.

class _EquipmentStatsTab extends ConsumerWidget {
  const _EquipmentStatsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imagesAsync = ref.watch(allDbImagesProvider);
    // autofocusCount is aggregated per-session, not per-frame. Keep its
    // loading/error state distinct from a genuine count of zero.
    final sessionsAsync = ref.watch(allSessionsProvider);
    // Meridian flips are counted by the sequence executor and persisted in
    // each run's stats blob — the same number the Morning Report and the run
    // history already print. The Mount card said "Not tracked" beside it.
    final runsAsync = ref.watch(sequenceRunsProvider);
    // Null while the runs are loading or after they failed: a Readout says
    // that with an em dash. 'Loading…' and 'Unavailable' were words parked in
    // a value slot.
    final String? meridianFlips = runsAsync.when(
      loading: () => null,
      error: (_, __) => null,
      data: (runs) => '${runs.fold<int>(
        0,
        (sum, run) {
          final stats = _parseRunStats(run.statsJson);
          return stats == null ? sum : sum + stats.meridianFlips;
        },
      )}',
    );

    return imagesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(SkotiqTokens.space2xl),
        child: _AnalyticsLoading(height: _equipmentSkeletonHeight),
      ),
      error: (err, _) => Padding(
        padding: const EdgeInsets.all(SkotiqTokens.space2xl),
        child: Align(
          alignment: Alignment.topCenter,
          child: _AnalyticsError(
            title: 'Equipment stats did not load',
            message: err.toString(),
            onRetry: () => ref.invalidate(allDbImagesProvider),
          ),
        ),
      ),
      data: (images) {
        // Gated on runs and sessions as well as frames, and on their having
        // actually resolved: meridian flips and autofocus counts come from
        // those rows rather than from frames, and a load that failed or is
        // still in flight is not an empty history.
        if (images.isEmpty &&
            (runsAsync.valueOrNull?.isEmpty ?? false) &&
            (sessionsAsync.valueOrNull?.isEmpty ?? false)) {
          return const AnalyticsEmptyState(
            icon: LucideIcons.wrench,
            title: 'No equipment history yet',
            body: 'Capture some frames and this tab reports what your camera, '
                'mount and guider actually did.',
          );
        }
        final lights =
            images.where((i) => i.frameType.toLowerCase() == 'light').toList();
        // Accepted lights are the usable integration/quality population;
        // total camera exposures and temperature still cover every frame.
        final acceptedLights = lights
            .where((i) => i.frameType.toLowerCase() == 'light' && i.isAccepted)
            .toList();
        final totalExposures = images.length;
        final acceptedIntegration = acceptedLights.fold<double>(
          0,
          (sum, image) =>
              image.exposureDuration.isFinite && image.exposureDuration > 0
                  ? sum + image.exposureDuration
                  : sum,
        );
        final temps = images
            .map((i) => i.sensorTemp)
            .whereType<double>()
            .where((value) => value.isFinite);
        final hfrs = acceptedLights
            .map((i) => i.hfr)
            .whereType<double>()
            .where((value) => value.isFinite && value >= 0);
        final rmss = acceptedLights
            .map((i) => i.guidingRmsTotal)
            .whereType<double>()
            .where((value) => value.isFinite && value >= 0);
        final String? autofocusRuns = sessionsAsync.when(
          loading: () => null,
          error: (_, __) => null,
          data: (sessions) => '${sessions.fold<int>(
            0,
            (sum, session) => sum + session.autofocusCount,
          )}',
        );

        return SingleChildScrollView(
          padding: const EdgeInsets.all(SkotiqTokens.space2xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (sessionsAsync.hasError || runsAsync.hasError) ...[
                // ONE banner for ONE problem (05 §11). It used to be a card
                // with its own icon column, its own padding and a bare text
                // button — a second banner style inside the screen that
                // already has one.
                SkotiqBanner(
                  title: 'Session totals are unavailable',
                  message: 'Meridian flips and autofocus runs come from the '
                      'session and run records, which did not load.',
                  tone: BannerTone.warning,
                  action: SkotiqButton(
                    label: 'Retry',
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    onPressed: () {
                      if (sessionsAsync.hasError) {
                        ref.invalidate(allSessionsProvider);
                      }
                      if (runsAsync.hasError) {
                        ref.invalidate(sequenceRunsProvider);
                      }
                    },
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
              ],
              ResponsiveCardGrid(children: [
                _EquipmentStatPanel(
                  title: 'Camera',
                  icon: LucideIcons.camera,
                  readouts: [
                    Readout(
                      label: 'Total exposures',
                      value: '$totalExposures',
                      size: ReadoutSize.sm,
                    ),
                    Readout(
                      label: 'Accepted integration',
                      value: _formatIntegration(acceptedIntegration),
                      size: ReadoutSize.sm,
                    ),
                    Readout(
                      label: 'Avg temperature',
                      unit: '°C',
                      value: _formatAvg(temps, (v) => v.toStringAsFixed(1)),
                      size: ReadoutSize.sm,
                    ),
                  ],
                ),
                _EquipmentStatPanel(
                  title: 'Mount',
                  icon: LucideIcons.compass,
                  readouts: [
                    Readout(
                      label: 'Meridian flips',
                      value: meridianFlips,
                      size: ReadoutSize.sm,
                    ),
                  ],
                ),
                _EquipmentStatPanel(
                  title: 'Focuser',
                  icon: LucideIcons.focus,
                  readouts: [
                    Readout(
                      label: 'Autofocus runs',
                      value: autofocusRuns,
                      size: ReadoutSize.sm,
                    ),
                    Readout(
                      label: 'Avg HFR achieved',
                      unit: 'px',
                      value: _formatAvg(hfrs, (v) => v.toStringAsFixed(2)),
                      size: ReadoutSize.sm,
                    ),
                  ],
                ),
                _EquipmentStatPanel(
                  title: 'Guider',
                  icon: LucideIcons.crosshair,
                  readouts: [
                    Readout(
                      label: 'Avg RMS',
                      // ASCII double quote, not U+2033: the bundled fonts
                      // have no prime glyphs and render them as tofu.
                      unit: '"',
                      value: _formatAvg(rmss, (v) => v.toStringAsFixed(2)),
                      size: ReadoutSize.sm,
                    ),
                  ],
                ),
              ]),
            ],
          ),
        );
      },
    );
  }

  /// Format a summed exposure time (seconds) as `Hh Mm`, or a clear empty
  /// marker when no frames have been captured yet.
  /// The rule this grid follows, stated once: a COUNT or a SUM of nothing is
  /// zero and prints as a number ("0", "0s"); a MEAN of nothing has no value
  /// at all and prints "No data". Accepted Integration is a sum, and printing
  /// it as "No data" beside "Total Exposures 0" was the only reason the two
  /// tokens looked arbitrary.
  static String _formatIntegration(double seconds) {
    if (!seconds.isFinite || seconds <= 0) return '0s';
    final rounded = seconds.round();
    final h = rounded ~/ 3600;
    final m = (rounded % 3600) ~/ 60;
    final s = rounded % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return s > 0 ? '${m}m ${s}s' : '${m}m';
    return '${s}s';
  }

  /// Mean of the available samples via [format], or null when the backing
  /// column exists but no frame recorded a value — which a [Readout] renders
  /// as the em dash.
  static String? _formatAvg(
    Iterable<double> values,
    String Function(double) format,
  ) {
    final list = values.toList();
    if (list.isEmpty) return null;
    final mean = list.reduce((a, b) => a + b) / list.length;
    return format(mean);
  }
}

/// Height the equipment skeleton holds open while the frame catalogue loads.
const double _equipmentSkeletonHeight = 260;

/// Vertical gap between two readouts stacked in an equipment panel.
const double _equipmentReadoutGap = SkotiqTokens.spaceMd;

/// One device's numbers: a panel head naming the device, then its readouts.
///
/// Was a card with a 15/600 title and a key/value table whose right column was
/// a `labelSm`. Every one of those values is a measurement, so every one of
/// them is a [Readout] now — the label sits under the number instead of
/// competing with it across a gap.
class _EquipmentStatPanel extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Readout> readouts;

  const _EquipmentStatPanel({
    required this.title,
    required this.icon,
    required this.readouts,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
      head: PanelHead(icon: icon, label: title),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < readouts.length; i++) ...[
            if (i > 0) const SizedBox(height: _equipmentReadoutGap),
            readouts[i],
          ],
        ],
      ),
    );
  }
}

/// Skeleton placeholder used while session history loads. Rendering a list of
/// card-sized shimmer rows (rather than a centred spinner) preserves the
/// final layout so the page doesn't pop when the real data arrives.

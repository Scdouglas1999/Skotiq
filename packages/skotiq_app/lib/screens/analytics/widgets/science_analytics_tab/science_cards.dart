part of '../science_analytics_tab.dart';

class _AavsoExportButton extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final int sessionId;

  const _AavsoExportButton({
    required this.colors,
    required this.sessionId,
  });

  @override
  ConsumerState<_AavsoExportButton> createState() => _AavsoExportButtonState();
}

class _AavsoExportButtonState extends ConsumerState<_AavsoExportButton> {
  bool _exporting = false;

  Future<void> _doExport() async {
    final targetName = await _showTargetNameDialog();
    if (targetName == null || targetName.trim().isEmpty) {
      return;
    }

    setState(() => _exporting = true);
    try {
      final backend = ref.read(backendProvider);
      late final String filePath;
      if (backend is NetworkBackend) {
        final bytes = await backend.exportSessionAavso(
          widget.sessionId,
          targetStarName: targetName.trim(),
        );
        final docsDir = await resolveSkotiqDocumentsDirectory();
        final exportDir =
            Directory(path.join(docsDir.path, 'Skotiq', 'exports'));
        if (!await exportDir.exists()) {
          await exportDir.create(recursive: true);
        }
        filePath = path.join(
          exportDir.path,
          'AAVSO_${targetName.trim().replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}.txt',
        );
        await File(filePath).writeAsBytes(bytes, flush: true);
      } else {
        final scienceDao = ref.read(scienceDaoProvider);
        final settingsDao = ref.read(settingsDaoProvider);
        final imagesDao = ref.read(imagesDaoProvider);

        final service = AavsoExportService(
          scienceDao: scienceDao,
          settingsDao: settingsDao,
          imagesDao: imagesDao,
          softwareLabel: ref.read(appVersionLabelProvider),
        );

        filePath = await service.exportSession(
          sessionId: widget.sessionId,
          targetStarName: targetName.trim(),
        );
      }

      if (!mounted) return;

      // Share on mobile (the app-docs file is otherwise unreachable); path
      // snackbar on desktop.
      await revealExportedFile(
        context,
        filePath,
        subject: 'Skotiq AAVSO export',
        desktopMessage: 'AAVSO export saved to: $filePath',
      );
    } on AavsoExportError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: widget.colors.error,
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          backgroundColor: widget.colors.error,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  Future<String?> _showTargetNameDialog() async {
    var targetName = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Export to AAVSO'),
          content: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              ctx,
              designMaxWidth: 480,
              designMaxHeight: 320,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter the AAVSO star designation for this target '
                  '(e.g., "SS CYG", "R LEO"):',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  onChanged: (value) => targetName = value,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    hintText: 'Star name',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onFieldSubmitted: (value) => Navigator.of(ctx).pop(value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(targetName),
              child: const Text('Export'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SkotiqButton(
        onPressed: _doExport,
        icon: LucideIcons.fileOutput,
        label: _exporting ? 'Exporting...' : 'Export to AAVSO',
        variant: ButtonVariant.secondary,
        isLoading: _exporting,
      ),
    );
  }
}

class _LightCurveChartCard extends StatelessWidget {
  final SkotiqColors colors;
  final List<LightCurvePoint> lightCurve;
  final Widget? hubExportButton;

  const _LightCurveChartCard({
    required this.colors,
    required this.lightCurve,
    this.hubExportButton,
  });

  @override
  Widget build(BuildContext context) {
    if (lightCurve.isEmpty) {
      return SkotiqCard(
        child: AdaptiveChartContainer.fixed(
          height: 240,
          child: Center(
            child: Text(
              'Differential Photometry has no data yet',
              style:
                  SkotiqTypography.body.copyWith(color: colors.textMuted),
            ),
          ),
        ),
      );
    }

    final sorted = lightCurve.toList(growable: false)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final start = sorted.first.timestamp;
    // Negate values for inverted Y-axis (brighter = up = more negative mag).
    final spots = sorted
        .map(
          (point) => FlSpot(
            point.timestamp.difference(start).inSeconds.toDouble(),
            -point.differentialMagnitude,
          ),
        )
        .toList(growable: false);

    var minY = spots.first.y;
    var maxY = spots.first.y;
    for (final s in spots) {
      if (s.y < minY) minY = s.y;
      if (s.y > maxY) maxY = s.y;
    }
    // Extend range to include error bar extents so they aren't clipped.
    for (final point in sorted) {
      if (point.uncertainty <= 0) continue;
      final yLow = -(point.differentialMagnitude - point.uncertainty);
      final yHigh = -(point.differentialMagnitude + point.uncertainty);
      if (yLow < minY) minY = yLow;
      if (yLow > maxY) maxY = yLow;
      if (yHigh < minY) minY = yHigh;
      if (yHigh > maxY) maxY = yHigh;
    }
    // Shared nice axis so the boundary label coincides with a tick instead of
    // printing a second value beside it.
    final axis = NiceAxis.forRange(minY, maxY);
    final maxX = spots.last.x == 0 ? 1.0 : spots.last.x;
    final xInterval = maxX / 4;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Differential Photometry',
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              if (hubExportButton != null) hubExportButton!,
              const _ScienceInfoButton(title: 'Differential photometry'),
            ],
          ),
          const SizedBox(height: 12),
          AdaptiveChartContainer(
            preferredHeight: 190,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: maxX,
                minY: axis.min,
                maxY: axis.max,
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(color: colors.border),
                ),
                gridData: FlGridData(
                  drawVerticalLine: true,
                  horizontalInterval: axis.interval,
                  verticalInterval: xInterval,
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: colors.border.withValues(alpha: 0.35)),
                  getDrawingVerticalLine: (_) =>
                      FlLine(color: colors.border.withValues(alpha: 0.25)),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: xInterval,
                      getTitlesWidget: (value, meta) {
                        return Text(
                          elapsedAxisLabel(value),
                          style: SkotiqTypography.caption
                              .copyWith(color: colors.textSecondary),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    axisNameWidget: Text(
                      'dMag',
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textSecondary),
                    ),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      interval: axis.interval,
                      // Plotted negated so brighter is higher; label with the
                      // real magnitude. NiceAxis.label also folds -0.00 back
                      // to 0.00 — a negative zero is a rounding artefact, not
                      // a measurement.
                      getTitlesWidget: (value, meta) => Text(
                        axis.label(-value),
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textSecondary),
                      ),
                    ),
                  ),
                ),
                lineBarsData: [
                  // Main data line with dot markers.
                  LineChartBarData(
                    spots: spots,
                    color: colors.primary,
                    barWidth: 2,
                    isCurved: false,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                        radius: 2.2,
                        color: colors.primary,
                        strokeWidth: 0,
                      ),
                    ),
                    belowBarData: BarAreaData(show: false),
                  ),
                  // Error bars: each is a vertical line segment in chart
                  // coordinates (2 spots per bar), so alignment with data
                  // points is exact regardless of axis padding or layout.
                  for (final point in sorted)
                    if (point.uncertainty > 0)
                      LineChartBarData(
                        spots: [
                          FlSpot(
                            point.timestamp
                                .difference(start)
                                .inSeconds
                                .toDouble(),
                            -(point.differentialMagnitude - point.uncertainty),
                          ),
                          FlSpot(
                            point.timestamp
                                .difference(start)
                                .inSeconds
                                .toDouble(),
                            -(point.differentialMagnitude + point.uncertainty),
                          ),
                        ],
                        color: colors.primary.withValues(alpha: 0.4),
                        barWidth: 1.0,
                        isCurved: false,
                        dotData: FlDotData(
                          show: true,
                          getDotPainter: (spot, _, __, ___) =>
                              FlDotCirclePainter(
                            radius: 1.5,
                            color: colors.primary.withValues(alpha: 0.4),
                            strokeWidth: 0,
                          ),
                        ),
                        belowBarData: BarAreaData(show: false),
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PsfHeatmapCard extends StatelessWidget {
  final SkotiqColors colors;
  final List<PsfFieldTileRow> tiles;
  final Widget? hubExportButton;

  const _PsfHeatmapCard({
    required this.colors,
    required this.tiles,
    this.hubExportButton,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'PSF Field Map',
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              if (hubExportButton != null) hubExportButton!,
              const _ScienceInfoButton(title: 'PSF Field Map'),
            ],
          ),
          const SizedBox(height: 10),
          if (tiles.isEmpty)
            AdaptiveChartContainer.fixed(
              height: 170,
              child: Center(
                child: Text(
                  'No PSF tiles computed yet',
                  style: SkotiqTypography.body
                      .copyWith(color: colors.textMuted),
                ),
              ),
            )
          else
            _PsfHeatmapGrid(colors: colors, tiles: tiles),
        ],
      ),
    );
  }
}

class _PsfHeatmapGrid extends StatelessWidget {
  final SkotiqColors colors;
  final List<PsfFieldTileRow> tiles;

  const _PsfHeatmapGrid({required this.colors, required this.tiles});

  @override
  Widget build(BuildContext context) {
    var maxRow = 0;
    var maxCol = 0;
    for (final tile in tiles) {
      if (tile.tileRow > maxRow) {
        maxRow = tile.tileRow;
      }
      if (tile.tileCol > maxCol) {
        maxCol = tile.tileCol;
      }
    }
    final rowCount = maxRow + 1;
    final colCount = maxCol + 1;

    final valid = tiles
        .where((tile) => tile.starCount > 0 && tile.medianFwhm > 0)
        .map((tile) => tile.medianFwhm)
        .toList(growable: false)
      ..sort();
    final low = valid.isEmpty ? 0.0 : _percentile(valid, 0.05);
    final high = valid.isEmpty
        ? 1.0
        : _percentile(valid, 0.95).clamp(low + 1e-6, double.infinity);

    return AdaptiveChartContainer(
      preferredHeight: 170,
      child: Column(
        children: List.generate(rowCount, (row) {
          return Expanded(
            child: Row(
              children: List.generate(colCount, (col) {
                PsfFieldTileRow? tile;
                for (final candidate in tiles) {
                  if (candidate.tileRow == row && candidate.tileCol == col) {
                    tile = candidate;
                    break;
                  }
                }
                final fwhm = tile?.medianFwhm ?? 0.0;
                final normalized = tile == null || tile.starCount <= 0
                    ? 0.0
                    : ((fwhm - low) / (high - low)).clamp(0.0, 1.0);
                final color = tile == null || tile.starCount <= 0
                    ? const Color(0xFF4A5568)
                    : Color.lerp(
                        const Color(0xFF0B6E4F),
                        const Color(0xFFC0392B),
                        normalized,
                      )!;
                final labelColor = color.computeLuminance() > 0.45
                    ? const Color(0xFF000000)
                    : const Color(0xFFFFFFFF);

                return Expanded(
                  child: Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.85),
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline4),
                    ),
                    child: Center(
                      child: Text(
                        tile == null
                            ? kReadoutUnknown
                            : fwhm.toStringAsFixed(2),
                        style: SkotiqTypography.caption.copyWith(
                            color: labelColor, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                );
              }),
            ),
          );
        }),
      ),
    );
  }

  double _percentile(List<double> sortedValues, double p) {
    if (sortedValues.isEmpty) {
      return 0.0;
    }
    final q = p.clamp(0.0, 1.0);
    final pos = (sortedValues.length - 1) * q;
    final lo = pos.floor();
    final hi = pos.ceil();
    if (lo == hi) {
      return sortedValues[lo];
    }
    final t = pos - lo;
    return sortedValues[lo] * (1.0 - t) + sortedValues[hi] * t;
  }
}

class _ResidualCard extends StatelessWidget {
  final SkotiqColors colors;
  final List<AstrometryResidualVectorRow> residuals;
  final Widget? hubExportButton;

  const _ResidualCard({
    required this.colors,
    required this.residuals,
    this.hubExportButton,
  });

  @override
  Widget build(BuildContext context) {
    final rms = residuals.isEmpty
        ? 0.0
        : math.sqrt(
            residuals
                    .map((r) => r.magnitudeArcsec * r.magnitudeArcsec)
                    .fold<double>(0.0, (sum, value) => sum + value) /
                residuals.length,
          );

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Astrometric Residuals',
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              if (hubExportButton != null) hubExportButton!,
              const _ScienceInfoButton(title: 'Astrometric residuals'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            residuals.isEmpty
                ? 'No residual vectors available for this session'
                : 'RMS: ${rms.toStringAsFixed(3)}" across ${residuals.length} samples',
            style: SkotiqTypography.caption
                .copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 8),
          if (residuals.isNotEmpty)
            Text(
              'Latest recommendation: ${residuals.last.recommendationCode ?? 'none'}',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
        ],
      ),
    );
  }
}

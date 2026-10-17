part of '../science_analytics_tab.dart';

/// Export the Science tab's shortcut report without ever reading a remote
/// controller's empty local database. The local path preserves the existing
/// Markdown exporter; a remote client downloads the host-generated PDF and
/// stores a copy in its own exports directory.
///
/// [period] is the period search the operator ran on this tab. It is UI state,
/// never a stored product, so it has to travel with the export request: with it
/// omitted the report's "Period analysis" section says "Not run for this
/// session" while the panel two inches above the button is showing the result.
Future<File> exportScienceShortcutReport({
  required SkotiqBackend backend,
  required int sessionId,
  required ScienceReportExporter localExporter,
  PeriodAnalysisResult? period,
  Future<Directory> Function()? documentsDirectoryProvider,
  DateTime? generatedAt,
}) async {
  if (backend is! NetworkBackend) {
    return localExporter.exportToDisk(sessionId, period: period);
  }

  final bytes = await backend.generateObservationReport(sessionId);
  if (bytes.isEmpty) {
    throw StateError('The imaging host returned an empty science report.');
  }
  final documents = await (documentsDirectoryProvider ??
      resolveSkotiqDocumentsDirectory)();
  final exportDirectory = Directory(
    path.join(documents.path, 'Skotiq', 'exports'),
  );
  await exportDirectory.create(recursive: true);
  final timestamp = (generatedAt ?? DateTime.now())
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.')
      .first;
  final file = File(
    path.join(
      exportDirectory.path,
      'science_report_session_${sessionId}_$timestamp.pdf',
    ),
  );
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// Inline export button that routes to the consolidated [ScienceExportHub]
/// pre-selected to a specific dataset, so there is one canonical export
/// surface rather than a CSV writer per card.
class _CardHubExportButton extends StatelessWidget {
  final String tooltip;
  final ScienceExportDataset dataset;
  final List<MovingObjectCandidateRow> mpcCandidates;

  const _CardHubExportButton({
    required this.tooltip,
    required this.dataset,
    this.mpcCandidates = const [],
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
          button: true,
          enabled: true,
          child: InkWell(
            onTap: () {
              showDialog(
                context: context,
                builder: (_) => ScienceExportHub(
                  initialDataset: dataset,
                  mpcCandidates: mpcCandidates,
                ),
              );
            },
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                LucideIcons.download,
                size: 14,
                color: colors.textMuted,
              ),
            ),
          )),
    );
  }
}

/// Sticky jump-nav row pinning Photometry / Field Quality / Anomalies tabs at
/// the top of the science analytics scroll view, so users do not have to
/// scroll through several hundred pixels of dense panels to reach the section
/// they care about.
class _ScienceJumpNav extends ConsumerWidget {
  final SkotiqColors colors;
  final VoidCallback onPhotometry;
  final VoidCallback onFieldQuality;
  final VoidCallback onAnomalies;
  final int? sessionId;

  const _ScienceJumpNav({
    required this.colors,
    required this.onPhotometry,
    required this.onFieldQuality,
    required this.onAnomalies,
    required this.sessionId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          _JumpChip(
            colors: colors,
            icon: LucideIcons.lineChart,
            label: 'Photometry',
            onTap: onPhotometry,
          ),
          const SizedBox(width: 8),
          _JumpChip(
            colors: colors,
            icon: LucideIcons.grid,
            label: 'Field quality',
            onTap: onFieldQuality,
          ),
          const SizedBox(width: 8),
          _JumpChip(
            colors: colors,
            icon: LucideIcons.orbit,
            label: 'Anomalies',
            onTap: onAnomalies,
          ),
          const Spacer(),
          if (sessionId != null)
            _JumpChip(
              colors: colors,
              icon: LucideIcons.fileText,
              label: 'Export report',
              onTap: () => _exportReport(context, ref, sessionId!),
            ),
        ],
      ),
    );
  }

  Future<void> _exportReport(
      BuildContext context, WidgetRef ref, int sessionId) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Generating science report…'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
    try {
      final backend = ref.read(backendProvider);
      final exporter = ref.read(scienceReportExporterProvider);
      final file = await exportScienceShortcutReport(
        backend: backend,
        sessionId: sessionId,
        localExporter: exporter,
        period: ref.read(periodAnalysisProvider).result,
      );
      if (!context.mounted) return;
      messenger.clearSnackBars();
      // On mobile the app-docs file is unreachable and "Open folder"
      // (xdg-open/explorer) is a desktop-only shell action — share instead.
      if (Platform.isAndroid || Platform.isIOS) {
        await revealExportedFile(
          context,
          file.path,
          subject: 'Skotiq science report',
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Saved to ${file.path}'),
            action: SnackBarAction(
              label: 'Open folder',
              onPressed: () async {
                final dir = file.parent.path;
                await _openInShell(dir);
              },
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openInShell(String path) async {
    if (Platform.isWindows) {
      await Process.start('explorer', [path], runInShell: true);
    } else if (Platform.isMacOS) {
      await Process.start('open', [path], runInShell: true);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [path], runInShell: true);
    }
  }
}

class _JumpChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _JumpChip({
    required this.colors,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // A bare InkWell publishes a tap action and no role, and AT-SPI reads an
    // absent enabled flag as "disabled" — which is how these four working jump
    // chips came to announce themselves as `panel: Photometry [DISABLED]`.
    return Semantics(
      button: true,
      enabled: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: colors.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: SkotiqTypography.labelSm.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final IconData icon;
  final Widget? trailing;

  const _SectionHeading({
    required this.colors,
    required this.label,
    required this.icon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: colors.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w600),
          ),
          if (trailing != null) ...[
            const Spacer(),
            trailing!,
          ],
        ],
      ),
    );
  }
}

// The science analytics tab writes no CSV inline. Exports route exclusively
// through the consolidated [ScienceExportHub], which builds its rows from the
// DAO providers and therefore covers every session, not just the visible
// snapshot.

/// Which object's light curve to plot for a set of stored photometry rows.
///
/// The live selection names the object being tracked RIGHT NOW; stored rows are
/// keyed on whatever was being tracked when they were written. Filtering a past
/// night by the live selection made every night that did not happen to match it
/// render as "has no data yet" — with no AAVSO export and no period search —
/// while its measurements sat in the database.
///
/// So: keep the live selection whenever these rows actually contain it (the
/// session being captured, or the user having picked the same star again), and
/// otherwise fall back to the object these rows measured most, preferring rows
/// that carry a differential magnitude because those are the ones the charts
/// and the exports can use.
String _reviewedPhotometryObjectId({
  required List<PhotometryMeasurementRow> rows,
  required String liveSelection,
}) {
  if (rows.isEmpty) {
    return liveSelection;
  }
  final counts = <String, int>{};
  for (final row in rows) {
    if (row.role != 'target' || row.differentialMagnitude == null) {
      continue;
    }
    if (row.objectId == liveSelection) {
      return liveSelection;
    }
    counts[row.objectId] = (counts[row.objectId] ?? 0) + 1;
  }
  if (counts.isEmpty) {
    return liveSelection;
  }
  // Ties resolve to the object seen first, which for a timestamp-ordered query
  // is the one this night started on.
  var best = counts.entries.first;
  for (final entry in counts.entries) {
    if (entry.value > best.value) {
      best = entry;
    }
  }
  return best.key;
}

List<PsfFieldTileRow> _latestPsfSnapshot(List<PsfFieldTileRow> rows) {
  if (rows.isEmpty) {
    return const [];
  }
  int? latestId;
  DateTime latestTime = DateTime.fromMillisecondsSinceEpoch(0);
  for (final row in rows) {
    if (row.capturedImageId == null) {
      continue;
    }
    if (row.timestamp.isAfter(latestTime)) {
      latestTime = row.timestamp;
      latestId = row.capturedImageId;
    }
  }
  if (latestId == null) {
    return rows;
  }
  return rows
      .where((row) => row.capturedImageId == latestId)
      .toList(growable: false);
}

List<AstrometryResidualVectorRow> _latestResidualSnapshot(
  List<AstrometryResidualVectorRow> rows,
) {
  if (rows.isEmpty) {
    return const [];
  }
  int? latestId;
  DateTime latestTime = DateTime.fromMillisecondsSinceEpoch(0);
  for (final row in rows) {
    if (row.capturedImageId == null) {
      continue;
    }
    if (row.timestamp.isAfter(latestTime)) {
      latestTime = row.timestamp;
      latestId = row.capturedImageId;
    }
  }
  if (latestId == null) {
    return rows;
  }
  return rows
      .where((row) => row.capturedImageId == latestId)
      .toList(growable: false);
}

List<ScienceTileMetricRow> _latestTileMetricSnapshot(
  List<ScienceTileMetricRow> rows,
) {
  if (rows.isEmpty) {
    return const [];
  }
  int? latestId;
  DateTime latestTime = DateTime.fromMillisecondsSinceEpoch(0);
  for (final row in rows) {
    if (row.capturedImageId == null) {
      continue;
    }
    if (row.timestamp.isAfter(latestTime)) {
      latestTime = row.timestamp;
      latestId = row.capturedImageId;
    }
  }
  if (latestId == null) {
    return rows;
  }
  return rows
      .where((row) => row.capturedImageId == latestId)
      .toList(growable: false);
}

// Tiles for the frame chosen in the Timeline Scrubber. Falls back to the latest
// snapshot when nothing is selected or the selected frame has no tile rows.
List<ScienceTileMetricRow> _tileMetricSnapshotForImage(
  List<ScienceTileMetricRow> rows,
  int? imageId,
) {
  if (imageId != null) {
    final forImage = rows
        .where((row) => row.capturedImageId == imageId)
        .toList(growable: false);
    if (forImage.isNotEmpty) {
      return forImage;
    }
  }
  return _latestTileMetricSnapshot(rows);
}

// Frame-quality row for the scrubber selection, or the latest row when nothing
// is selected / the selection has no matching metrics.
ScienceFrameQualityMetricsRow? _frameQualityForImage(
  List<ScienceFrameQualityMetricsRow> rows,
  int? imageId,
) {
  if (rows.isEmpty) {
    return null;
  }
  if (imageId != null) {
    for (final row in rows) {
      if (row.capturedImageId == imageId) {
        return row;
      }
    }
  }
  return rows.last;
}

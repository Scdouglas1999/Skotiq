import 'dart:io';

import 'package:csv/csv.dart';
import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as path;

import '../../../services/observation_report_service.dart';
import '../../../utils/authority_bound_dialog.dart';
import '../../../utils/exported_file_reveal.dart';
import '../../../utils/snackbar_helper.dart';
import 'mpc_export_panel.dart';
import 'transient_report_panel.dart';

part 'science_export_hub/export_controls.dart';

part 'science_export_hub/datasets.dart';
part 'science_export_hub/hub_state_helpers.dart';

/// Identifier for a science dataset that the hub can export. Exposed so that
/// per-card export buttons in the science analytics tab can route into the
/// hub with the relevant card pre-highlighted.
enum ScienceExportDataset {
  photometry,
  frameQuality,
  transparency,
  psfTiles,
  residuals,
  calibration,
  movingObjects,
  mpcReport,
  transientReport,
}

/// Where the science-export save dialog OPENS — not where files are written
/// behind the operator's back.
///
/// The suggestion follows the active database directory, while the operator
/// still chooses the destination. A provider keeps path resolution testable.
final scienceExportDirectoryProvider = FutureProvider<Directory>((ref) async {
  final databaseFile = await resolveDefaultDatabaseFile();
  final exportDir = Directory(path.join(databaseFile.parent.path, 'exports'));
  if (!await exportDir.exists()) {
    await exportDir.create(recursive: true);
  }
  return exportDir;
});

/// Chooses the destination for a science export. Returns null when the operator
/// cancels the dialog.
typedef ScienceExportSavePicker = Future<String?> Function({
  required String fileName,
  required String initialDirectory,
  required List<String> allowedExtensions,
});

Future<String?> _defaultScienceExportSavePicker({
  required String fileName,
  required String initialDirectory,
  required List<String> allowedExtensions,
}) async {
  // [chooseExportTarget], as used by every other export in the app: a native
  // save dialog on desktop, and on a phone a sandbox path the caller finishes
  // with the share sheet (the platform save picker is unavailable there).
  final target = await chooseExportTarget(
    suggestedName: fileName,
    initialDirectory: initialDirectory,
    acceptedTypeGroups: [
      XTypeGroup(
        label: allowedExtensions.map((e) => e.toUpperCase()).join(' / '),
        extensions: allowedExtensions,
      ),
    ],
  );
  return target?.path;
}

/// Override point for the science-export save dialog (tests stub this).
final scienceExportSavePickerProvider = Provider<ScienceExportSavePicker>(
  (ref) => _defaultScienceExportSavePicker,
);

typedef ScienceExportFileWriter = Future<void> Function(
  File file,
  String contents,
);

final scienceExportFileWriterProvider = Provider<ScienceExportFileWriter>(
  (ref) => (file, contents) async {
    await file.writeAsString(contents);
  },
);

/// Timestamp as UTC ISO-8601, always ending in `Z`.
///
/// `toIso8601String()` on a LOCAL DateTime carries no offset and no `Z`, so
/// anything parsing it as ISO-8601 places the measurement hours from where it
/// was taken — by an amount that changes with the observer's timezone and with
/// DST inside one observing season.
String _utcStamp(DateTime dt) => dt.toUtc().toIso8601String();

/// Julian Date for [dt], the time system AAVSO/AID submissions and every period
/// analysis actually work in. Emitted alongside the ISO stamp so a downstream
/// script never has to redo the conversion (and never has to guess the zone).
///
/// Kept separate from `SkyCalculations.julianDate` on purpose. That one is
/// Meeus' calendar decomposition; this is the exact epoch conversion
/// (`ms since 1970 / 86 400 000 + 2440587.5`), which carries the submission's
/// millisecond timestamp with no calendar arithmetic in between. They agree to
/// ~1e-10 d but not bit-for-bit, and these values go out in published
/// photometry files.
double _julianDate(DateTime dt) =>
    dt.toUtc().millisecondsSinceEpoch / 86400000.0 + 2440587.5;

/// Dialog listing all exportable science data types with CSV export and filters.
class ScienceExportHub extends ConsumerStatefulWidget {
  /// When set, the dialog scrolls to and visually highlights the matching
  /// dataset row so that opening the hub from a card's export button feels
  /// like a continuation of the user's intent, not a context switch.
  final ScienceExportDataset? initialDataset;

  /// Optional moving-object candidates list used by the MPC report row.
  /// The science analytics tab passes the in-memory snapshot it is already
  /// rendering, so the hub does not need to re-query the database.
  final List<MovingObjectCandidateRow> mpcCandidates;

  /// Optional First Light transient detections used by the transient-report row
  /// (AAVSO / MPC / TNS discovery export). Defaults to the global detection
  /// snapshot watched inside the hub when not supplied.
  final List<TransientDetectionRow> transientDetections;

  const ScienceExportHub({
    super.key,
    this.initialDataset,
    this.mpcCandidates = const [],
    this.transientDetections = const [],
  });

  @override
  ConsumerState<ScienceExportHub> createState() => _ScienceExportHubState();
}

class _ScienceExportHubState extends ConsumerState<ScienceExportHub> {
  static const _allDataFilter = 'All Sessions & Standalone';
  static const _standaloneFilter = 'Standalone Captures';

  DateTime? _startDate;
  DateTime? _endDate;
  int? _selectedSessionId;
  bool _standaloneOnly = false;
  bool _isExporting = false;
  String? _lastExportResult;

  /// True once an export has included standalone rows that came from the host's
  /// capped preview window (remote mode only). Drives the truncation note on the
  /// export result so a row count is never presented as "everything".
  bool _standaloneWindowed = false;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _authorityGeneration = 0;

  // Keys per dataset row so we can scroll a deep-linked row into view and
  // pulse a highlight ring around it on first frame.
  final Map<ScienceExportDataset, GlobalKey> _rowKeys = {
    for (final d in ScienceExportDataset.values) d: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        _authorityGeneration++;
        setState(() {
          _isExporting = false;
          _lastExportResult = null;
          _selectedSessionId = null;
          _standaloneOnly = false;
        });
        closeAuthorityBoundDialog(context);
      },
    );
    final initial = widget.initialDataset;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _rowKeys[initial]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            alignment: 0.1,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  bool _isCurrentAuthority(SkotiqBackend backend, int generation) =>
      mounted &&
      generation == _authorityGeneration &&
      identical(ref.read(backendProvider), backend);

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final sessionsAsync = ref.watch(allSessionsProvider);
    final sessions = sessionsAsync.valueOrNull ?? const [];
    final sessionsReady = sessionsAsync.hasValue &&
        !sessionsAsync.isLoading &&
        !sessionsAsync.hasError;
    final dateFormat = DateFormat('yyyy-MM-dd');

    // First Light transient detections: prefer the caller's snapshot, else the
    // global newest-first feed.
    final AsyncValue<List<TransientDetectionRow>> transientDetectionsAsync =
        widget.transientDetections.isNotEmpty
            ? AsyncValue.data(widget.transientDetections)
            : ref.watch(allTransientDetectionsProvider);
    final transientDetections =
        transientDetectionsAsync.valueOrNull ?? const <TransientDetectionRow>[];
    final transientDetectionsReady = transientDetectionsAsync.hasValue &&
        !transientDetectionsAsync.isLoading &&
        !transientDetectionsAsync.hasError;

    // Moving-object candidates: same rule as the transient detections above.
    // Two of the three entry points construct the hub with no list at all
    // (the Science header's database icon among them), and the MPC row then
    // told the user "No moving object candidates available to report yet"
    // while the page behind the dialog listed two of them and its Open button
    // did nothing. The hub now looks them up itself.
    final mpcSessionId = _selectedSessionId ?? _newestSessionId(sessions);
    final AsyncValue<List<MovingObjectCandidateRow>> mpcCandidatesAsync = widget
            .mpcCandidates.isNotEmpty
        ? AsyncValue.data(widget.mpcCandidates)
        : mpcSessionId == null
            ? const AsyncValue.data(<MovingObjectCandidateRow>[])
            : ref.watch(sessionMovingObjectCandidatesProvider(mpcSessionId));
    final mpcCandidates =
        mpcCandidatesAsync.valueOrNull ?? const <MovingObjectCandidateRow>[];
    final mpcCandidatesReady = mpcCandidatesAsync.hasValue &&
        !mpcCandidatesAsync.isLoading &&
        !mpcCandidatesAsync.hasError;

    return Dialog(
      backgroundColor: colors.surface,
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 700,
          designMaxHeight: 750,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.well,
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.database, size: 20, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Science Data Export',
                      style: SkotiqTypography.sectionTitle.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  SkotiqIconButton(
                    icon: LucideIcons.x,
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Filters
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Filters',
                    style: SkotiqTypography.bodyStrong.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final sessionFilter = _buildSessionFilter(
                        colors,
                        sessionsAsync,
                        sessions,
                      );
                      final dates = _buildDateFilters(colors, dateFormat);
                      if (constraints.maxWidth < 560) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            sessionFilter,
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: dates,
                            ),
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: sessionFilter),
                          const SizedBox(width: 12),
                          dates,
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),

            // Data type list
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _ExportTypeCard(
                      key: _rowKeys[ScienceExportDataset.photometry],
                      colors: colors,
                      title: 'Photometry measurements',
                      description:
                          'Differential photometry: object ID, flux, magnitude, SNR, uncertainty, timestamp',
                      icon: LucideIcons.lineChart,
                      isExporting: _isExporting,
                      enabled: sessionsReady,
                      highlight: widget.initialDataset ==
                          ScienceExportDataset.photometry,
                      onExport: () =>
                          _exportData(ScienceExportDataset.photometry),
                    ),
                    const SizedBox(height: 8),
                    _ExportTypeCard(
                      key: _rowKeys[ScienceExportDataset.frameQuality],
                      colors: colors,
                      title: 'Frame Quality Metrics',
                      description:
                          'Per-frame statistics: SNR, background, noise, clipping, uniformity, gradients',
                      icon: LucideIcons.barChart2,
                      isExporting: _isExporting,
                      enabled: sessionsReady,
                      highlight: widget.initialDataset ==
                          ScienceExportDataset.frameQuality,
                      onExport: () =>
                          _exportData(ScienceExportDataset.frameQuality),
                    ),
                    const SizedBox(height: 8),
                    _ExportTypeCard(
                      key: _rowKeys[ScienceExportDataset.transparency],
                      colors: colors,
                      title: 'Transparency samples',
                      description:
                          'Sky transparency %, extinction coefficient, quality bucket per frame',
                      icon: LucideIcons.cloud,
                      isExporting: _isExporting,
                      enabled: sessionsReady,
                      highlight: widget.initialDataset ==
                          ScienceExportDataset.transparency,
                      onExport: () =>
                          _exportData(ScienceExportDataset.transparency),
                    ),
                    const SizedBox(height: 8),
                    _ExportTypeCard(
                      key: _rowKeys[ScienceExportDataset.psfTiles],
                      colors: colors,
                      title: 'PSF Field Tiles',
                      description:
                          'Per-tile FWHM, HFR, eccentricity, roundness, star count across field',
                      icon: LucideIcons.grid,
                      isExporting: _isExporting,
                      enabled: sessionsReady,
                      highlight: widget.initialDataset ==
                          ScienceExportDataset.psfTiles,
                      onExport: () =>
                          _exportData(ScienceExportDataset.psfTiles),
                    ),
                    const SizedBox(height: 8),
                    _ExportTypeCard(
                      key: _rowKeys[ScienceExportDataset.residuals],
                      colors: colors,
                      title: 'Astrometric residuals',
                      description:
                          'Plate solve residual vectors: position, magnitude (arcsec), recommendation',
                      icon: LucideIcons.crosshair,
                      isExporting: _isExporting,
                      enabled: sessionsReady,
                      highlight: widget.initialDataset ==
                          ScienceExportDataset.residuals,
                      onExport: () =>
                          _exportData(ScienceExportDataset.residuals),
                    ),
                    const SizedBox(height: 8),
                    _ExportTypeCard(
                      key: _rowKeys[ScienceExportDataset.calibration],
                      colors: colors,
                      title: 'Photometric calibration',
                      description:
                          'Zero-point, limiting magnitude, matched star count, RMS per frame',
                      icon: LucideIcons.gauge,
                      isExporting: _isExporting,
                      enabled: sessionsReady,
                      highlight: widget.initialDataset ==
                          ScienceExportDataset.calibration,
                      onExport: () =>
                          _exportData(ScienceExportDataset.calibration),
                    ),
                    const SizedBox(height: 8),
                    _ExportTypeCard(
                      key: _rowKeys[ScienceExportDataset.movingObjects],
                      colors: colors,
                      title: 'Moving Object Candidates',
                      description:
                          'Detected movers: RA/Dec, motion rate, confidence, known object matches',
                      icon: LucideIcons.orbit,
                      isExporting: _isExporting,
                      enabled: sessionsReady,
                      highlight: widget.initialDataset ==
                          ScienceExportDataset.movingObjects,
                      onExport: () =>
                          _exportData(ScienceExportDataset.movingObjects),
                    ),
                    const SizedBox(height: 8),
                    // MPC astrometry uses a separate selection UI (per-observation
                    // checkbox list + 80-column format), so the hub launches that
                    // panel as a sub-dialog rather than producing CSV inline.
                    _ExportTypeCard(
                      key: _rowKeys[ScienceExportDataset.mpcReport],
                      colors: colors,
                      title: 'MPC Astrometry Report',
                      description: mpcCandidates.isEmpty
                          ? mpcCandidatesAsync.isLoading
                              ? 'Loading moving-object candidates...'
                              : mpcCandidatesAsync.hasError
                                  ? 'Could not load moving-object candidates: '
                                      '${mpcCandidatesAsync.error}'
                                  : 'No moving object candidates available to report yet.'
                          : 'Submit selected moving-object detections in MPC 80-column format',
                      icon: LucideIcons.send,
                      isExporting: _isExporting,
                      highlight: widget.initialDataset ==
                          ScienceExportDataset.mpcReport,
                      enabled: mpcCandidatesReady && mpcCandidates.isNotEmpty,
                      actionLabel: 'Open',
                      actionIcon: LucideIcons.externalLink,
                      onExport: () => _openMpcPanel(mpcCandidates),
                    ),
                    const SizedBox(height: 8),
                    // First Light transient discovery report (AAVSO / MPC / TNS).
                    _ExportTypeCard(
                      key: _rowKeys[ScienceExportDataset.transientReport],
                      colors: colors,
                      title: 'Transient Discovery Report',
                      description: transientDetections.isEmpty
                          ? transientDetectionsAsync.isLoading
                              ? 'Loading First Light transient detections...'
                              : transientDetectionsAsync.hasError
                                  ? 'Could not load First Light detections: '
                                      '${transientDetectionsAsync.error}'
                                  : 'No First Light transient detections available yet.'
                          : 'Submit a confirmed difference-image detection to '
                              'AAVSO, the MPC, or the TNS',
                      icon: LucideIcons.sparkles,
                      isExporting: _isExporting,
                      highlight: widget.initialDataset ==
                          ScienceExportDataset.transientReport,
                      enabled: transientDetectionsAsync.hasError ||
                          (transientDetectionsReady &&
                              transientDetections.isNotEmpty),
                      actionLabel:
                          transientDetectionsAsync.hasError ? 'Retry' : 'Open',
                      actionIcon: transientDetectionsAsync.hasError
                          ? LucideIcons.refreshCw
                          : LucideIcons.externalLink,
                      onExport: transientDetectionsAsync.hasError
                          ? () => ref.invalidate(allTransientDetectionsProvider)
                          : () => _openTransientPanel(transientDetections),
                    ),
                    const SizedBox(height: 16),
                    Divider(color: colors.border),
                    const SizedBox(height: 12),
                    // Generate Report button
                    SizedBox(
                      width: double.infinity,
                      child: SkotiqButton(
                        label: _isExporting
                            ? 'Generating...'
                            : _standaloneOnly
                                ? 'Select a Session to Generate a PDF Report'
                                : 'Generate Observation Report (PDF)',
                        icon: LucideIcons.fileText,
                        onPressed: _isExporting ||
                                !sessionsReady ||
                                sessions.isEmpty ||
                                _standaloneOnly
                            ? null
                            : _generateReport,
                        variant: ButtonVariant.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Status bar
            if (_lastExportResult != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.well,
                  border: Border(top: BorderSide(color: colors.border)),
                ),
                child: Text(
                  _lastExportResult!,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                  // Room for the path AND a completeness caveat: a truncated
                  // "…rows were dropped" note would be worse than none.
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionFilter(
    SkotiqColors colors,
    AsyncValue<List<ImagingSession>> sessionsAsync,
    List<ImagingSession> sessions,
  ) {
    if (sessionsAsync.isLoading || !sessionsAsync.hasValue) {
      if (!sessionsAsync.hasError) {
        return Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Loading sessions...',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        );
      }
    }

    if (sessionsAsync.hasError) {
      return Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
          color: colors.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
          border: Border.all(color: colors.error.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Could not load sessions: ${sessionsAsync.error}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    SkotiqTypography.caption.copyWith(color: colors.error),
              ),
            ),
            TextButton(
              onPressed: () => ref.invalidate(allSessionsProvider),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final selectedSession = sessions
        .where((session) => session.id == _selectedSessionId)
        .firstOrNull;
    final value = _standaloneOnly
        ? _standaloneFilter
        : selectedSession == null
            ? _allDataFilter
            : _sessionLabel(sessions, selectedSession.id);
    return SkotiqDropdown(
      value: value,
      isExpanded: true,
      items: [
        _allDataFilter,
        _standaloneFilter,
        ...sessions.map((session) => _sessionLabel(sessions, session.id)),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          if (value == _allDataFilter) {
            _selectedSessionId = null;
            _standaloneOnly = false;
          } else if (value == _standaloneFilter) {
            _selectedSessionId = null;
            _standaloneOnly = true;
          } else {
            final match = sessions.firstWhere(
              (session) => _sessionLabel(sessions, session.id) == value,
            );
            _selectedSessionId = match.id;
            _standaloneOnly = false;
          }
        });
      },
    );
  }
}

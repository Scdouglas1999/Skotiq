// ignore_for_file: invalid_use_of_protected_member
// Date-filter, export and report helpers of _ScienceExportHubState.
part of '../science_export_hub.dart';

extension _ScienceExportHubStateHelpers on _ScienceExportHubState {
  Widget _buildDateFilters(
    SkotiqColors colors,
    DateFormat dateFormat,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DateButton(
          colors: colors,
          label: _startDate != null
              ? dateFormat.format(_startDate!)
              : 'Start Date',
          onTap: () => _pickDate(isStart: true),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(kReadoutUnknown,
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textMuted)),
        ),
        _DateButton(
          colors: colors,
          label: _endDate != null ? dateFormat.format(_endDate!) : 'End Date',
          onTap: () => _pickDate(isStart: false),
        ),
        if (_startDate != null || _endDate != null) ...[
          const SizedBox(width: 4),
          SkotiqIconButton(
            icon: LucideIcons.x,
            tooltip: 'Clear date filter',
            size: IconButtonSize.sm,
            onPressed: () => setState(() {
              _startDate = null;
              _endDate = null;
            }),
          ),
        ],
      ],
    );
  }

  String _sessionLabel(List<ImagingSession> sessions, int id) {
    final session = sessions.where((s) => s.id == id).firstOrNull;
    if (session == null) return 'Session $id';
    final name = session.name ?? 'Session $id';
    final date = DateFormat('MMM d').format(session.startTime);
    return '$name ($date)';
  }

  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? (_startDate ?? now) : (_endDate ?? now),
      firstDate: DateTime(2020),
      lastDate: now,
    );
    if (picked != null && mounted) {
      setState(() {
        if (isStart) {
          _startDate = picked;
        } else {
          // Set end date to end of day
          _endDate =
              DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
        }
      });
    }
  }

  /// Newest session by start time — the one the Science tab is analysing when
  /// the user has not picked another in the filter.
  int? _newestSessionId(List<ImagingSession> sessions) {
    if (sessions.isEmpty) return null;
    var newest = sessions.first;
    for (final session in sessions) {
      if (session.startTime.isAfter(newest.startTime)) newest = session;
    }
    return newest.id;
  }

  Future<void> _openMpcPanel(
    List<MovingObjectCandidateRow> candidates,
  ) async {
    if (candidates.isEmpty) {
      context.showInfoSnackBar(
        'No moving object candidates available to report yet.',
      );
      return;
    }
    final colors = SkotiqColors.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: colors.surface,
          child: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              dialogContext,
              designMaxWidth: 720,
              designMaxHeight: 720,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: MpcExportPanel(
                colors: colors,
                candidates: candidates,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openTransientPanel(
    List<TransientDetectionRow> detections,
  ) async {
    if (detections.isEmpty) {
      context.showInfoSnackBar(
        'No First Light transient detections available yet.',
      );
      return;
    }
    final colors = SkotiqColors.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: colors.surface,
          child: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              dialogContext,
              designMaxWidth: 720,
              designMaxHeight: 720,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: TransientReportPanel(
                colors: colors,
                detections: detections,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _exportData(ScienceExportDataset dataType) async {
    final backend = ref.read(backendProvider);
    final generation = ++_authorityGeneration;
    _standaloneWindowed = false;
    setState(() {
      _isExporting = true;
      _lastExportResult = null;
    });

    try {
      final sessions = await ref.read(allSessionsProvider.future);
      if (!_isCurrentAuthority(backend, generation)) return;
      final selectedSession = sessions
          .where((session) => session.id == _selectedSessionId)
          .firstOrNull;
      final includeStandalone = _standaloneOnly || selectedSession == null;

      // "All" includes standalone quick captures as well as saved sessions.
      // A specific session excludes standalone data, while the explicit
      // standalone filter excludes every saved session.
      final List<int> sessionIds;
      if (_standaloneOnly) {
        sessionIds = const [];
      } else if (selectedSession != null) {
        sessionIds = [selectedSession.id];
      } else {
        sessionIds = sessions.map((s) => s.id).toList();
      }

      final List<List<dynamic>> rows;
      final String filePrefix;

      switch (dataType) {
        case ScienceExportDataset.photometry:
          rows = await _rowsFor(
            _photometryDataset,
            sessionIds,
            includeStandalone: includeStandalone,
          );
          filePrefix = 'photometry';
        case ScienceExportDataset.frameQuality:
          rows = await _rowsFor(
            _frameQualityDataset,
            sessionIds,
            includeStandalone: includeStandalone,
          );
          filePrefix = 'frame_quality';
        case ScienceExportDataset.transparency:
          rows = await _rowsFor(
            _transparencyDataset,
            sessionIds,
            includeStandalone: includeStandalone,
          );
          filePrefix = 'transparency';
        case ScienceExportDataset.psfTiles:
          rows = await _rowsFor(
            _psfTileDataset,
            sessionIds,
            includeStandalone: includeStandalone,
          );
          filePrefix = 'psf_tiles';
        case ScienceExportDataset.residuals:
          rows = await _rowsFor(
            _residualDataset,
            sessionIds,
            includeStandalone: includeStandalone,
          );
          filePrefix = 'astrometric_residuals';
        case ScienceExportDataset.calibration:
          rows = await _rowsFor(
            _calibrationDataset,
            sessionIds,
            includeStandalone: includeStandalone,
          );
          filePrefix = 'photometric_calibration';
        case ScienceExportDataset.movingObjects:
          rows = await _rowsFor(
            _movingObjectDataset,
            sessionIds,
            includeStandalone: includeStandalone,
          );
          filePrefix = 'moving_objects';
        case ScienceExportDataset.mpcReport:
          // MPC report has its own dialog/flow; should not land here, but
          // surfacing an error keeps the contract honest if a future caller
          // routes a "Download CSV" intent to the wrong dataset.
          throw StateError(
              'MPC report uses the dedicated panel, not CSV export.');
        case ScienceExportDataset.transientReport:
          // Transient discovery reports use the dedicated panel (per-network
          // format), not inline CSV export.
          throw StateError(
              'Transient report uses the dedicated panel, not CSV export.');
      }

      if (!_isCurrentAuthority(backend, generation)) return;

      if (rows.length <= 1) {
        // Only header row, no data
        if (mounted) {
          setState(() {
            _isExporting = false;
            _lastExportResult = 'No data found for the selected filters.';
          });
        }
        return;
      }

      final csv = const ListToCsvConverter().convert(rows);
      final directory = await ref.read(scienceExportDirectoryProvider.future);
      if (!_isCurrentAuthority(backend, generation)) return;
      final timestamp = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')[0];
      // 'Z' so a file exported at 00:30 local is not filed under the wrong
      // night, and so the name agrees with the UTC stamps inside it.
      final fileName = '${filePrefix}_${timestamp}Z.csv';
      final filePath = await ref.read(scienceExportSavePickerProvider)(
        fileName: fileName,
        initialDirectory: directory.path,
        allowedExtensions: const ['csv'],
      );
      if (!_isCurrentAuthority(backend, generation)) return;
      if (filePath == null) {
        if (!mounted) return;
        setState(() {
          _isExporting = false;
          _lastExportResult = 'Export cancelled.';
        });
        return;
      }
      final file = File(filePath);
      await ref.read(scienceExportFileWriterProvider)(file, csv);

      if (!_isCurrentAuthority(backend, generation) || !mounted) return;
      setState(() {
        _isExporting = false;
        _lastExportResult = 'Exported ${rows.length - 1} rows to $filePath'
            // Never let a row count imply completeness it does not have.
            '${_standaloneWindowed ? '\nNote: standalone rows came from the '
                'imaging host\'s recent-data window, so older standalone '
                'measurements may not be included. Export on the host for the '
                'complete set.' : ''}';
      });
      // On mobile the export lives in the app sandbox; share it so it's
      // actually retrievable instead of naming an unreachable path.
      await revealExportedFile(
        context,
        filePath,
        subject: 'Skotiq science export',
      );
    } catch (e) {
      if (!_isCurrentAuthority(backend, generation) || !mounted) return;
      setState(() {
        _isExporting = false;
        _lastExportResult = 'Export failed: $e';
      });
      context.showErrorSnackBar('Export failed: $e');
    }
  }

  Future<void> _generateReport() async {
    final backend = ref.read(backendProvider);
    final generation = ++_authorityGeneration;
    setState(() {
      _isExporting = true;
      _lastExportResult = null;
    });

    try {
      final sessions = await ref.read(allSessionsProvider.future);
      if (!_isCurrentAuthority(backend, generation)) return;
      final selectedSession = sessions
          .where((session) => session.id == _selectedSessionId)
          .firstOrNull;
      final reportSessionId = selectedSession?.id ?? sessions.firstOrNull?.id;
      if (_standaloneOnly || reportSessionId == null) {
        setState(() {
          _isExporting = false;
          _lastExportResult = _standaloneOnly
              ? 'Observation reports require a saved imaging session.'
              : 'No saved sessions are available for a report.';
        });
        if (!mounted) return;
        context.showWarningSnackBar(_lastExportResult!);
        return;
      }
      if (_selectedSessionId != reportSessionId) {
        setState(() => _selectedSessionId = reportSessionId);
      }

      late final String filePath;
      if (backend is NetworkBackend) {
        final bytes = await backend.generateObservationReport(reportSessionId);
        if (!_isCurrentAuthority(backend, generation)) return;
        final directory = await ref.read(scienceExportDirectoryProvider.future);
        if (!_isCurrentAuthority(backend, generation)) return;
        final timestamp = DateTime.now()
            .toUtc()
            .toIso8601String()
            .replaceAll(':', '-')
            .split('.')
            .first;
        filePath =
            path.join(directory.path, 'observation_report_${timestamp}Z.pdf');
        await File(filePath).writeAsBytes(bytes, flush: true);
      } else {
        final reportService = ObservationReportService(
          sessionsDao: ref.read(sessionsDaoProvider),
          imagesDao: ref.read(imagesDaoProvider),
          scienceDao: ref.read(scienceDaoProvider),
        );
        filePath = await reportService.generateReport(
          sessionId: reportSessionId,
        );
      }

      if (!_isCurrentAuthority(backend, generation) || !mounted) return;
      setState(() {
        _isExporting = false;
        _lastExportResult = 'Report generated: $filePath';
      });
      await revealExportedFile(
        context,
        filePath,
        subject: 'Skotiq observation report',
      );
    } catch (e) {
      if (!_isCurrentAuthority(backend, generation) || !mounted) return;
      setState(() {
        _isExporting = false;
        _lastExportResult = 'Report generation failed: $e';
      });
      context.showErrorSnackBar('Report generation failed: $e');
    }
  }

  // CSV row builders

  bool _withinDateRange(DateTime timestamp) {
    if (_startDate != null && timestamp.isBefore(_startDate!)) return false;
    if (_endDate != null && timestamp.isAfter(_endDate!)) return false;
    return true;
  }

  /// Standalone (session-less) rows for an export.
  ///
  /// Reads the `sessionless*ExportProvider` family, which returns the COMPLETE
  /// dataset locally. The `sessionless*Provider` UI preview feeds carry row
  /// caps (200 photometry / 50 frame-quality / 500 PSF tiles …) that an export
  /// must not inherit. In remote mode the rows still arrive in the host's
  /// windowed science bundle, so that case is flagged for the UI to disclose.
  Future<List<T>> _standaloneRows<T>(
    ProviderListenable<Future<List<T>>> export,
  ) {
    if (ref.read(backendProvider) is NetworkBackend) {
      _standaloneWindowed = true;
    }
    return ref.read(export);
  }

  /// One pass over the [dataset]'s standalone + per-session rows, filtered by
  /// the active date range. This is the whole recipe every science CSV follows;
  /// the header list and the row projection are the only per-dataset code.
  Future<List<List<dynamic>>> _rowsFor<T>(
    _ExportDataset<T> dataset,
    List<int> sessionIds, {
    required bool includeStandalone,
  }) async {
    final rows = <List<dynamic>>[dataset.header];

    final sources = <List<T>>[];
    if (includeStandalone) {
      sources.add(await _standaloneRows(dataset.standaloneExport));
    }
    for (final sessionId in sessionIds) {
      sources.add(await ref.read(dataset.perSession(sessionId)));
    }
    for (final source in sources) {
      for (final row in source) {
        if (!_withinDateRange(dataset.timestampOf(row))) continue;
        rows.add(dataset.toCsvRow(row));
      }
    }
    return rows;
  }
}

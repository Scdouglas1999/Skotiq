// ignore_for_file: invalid_use_of_protected_member
// Level formatting, clipboard, export, download and clear actions of _LogViewerState.
part of '../log_viewer.dart';

extension _LogViewerActions on _LogViewerState {
  Color _levelColor(LogLevel level) {
    final colors = SkotiqColors.of(context);
    switch (level) {
      case LogLevel.debug:
        return colors.textMuted;
      case LogLevel.info:
        return colors.info;
      case LogLevel.warning:
        return colors.warning;
      case LogLevel.error:
        return colors.error;
      case LogLevel.critical:
        return colors.error;
    }
  }

  String _levelLabel(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return 'DBG';
      case LogLevel.info:
        return 'INF';
      case LogLevel.warning:
        return 'WRN';
      case LogLevel.error:
        return 'ERR';
      case LogLevel.critical:
        return 'CRT';
    }
  }

  Future<void> _copyAllToClipboard() async {
    final text = _filteredLogs.map((e) => e.toString()).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('${_filteredLogs.length} log entries copied to clipboard'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Total size of the retained on-disk log files, for the scope prompt, or
  /// null when the retained set could not be enumerated at all.
  ///
  /// Failure to stat ONE file is not worth failing an export over; it just does
  /// not count towards the estimate, the same way `exportLogs` skips what it
  /// cannot read. A failure to enumerate the set is different: every file is
  /// then uncounted, and reporting the resulting 0 as the size of the history
  /// tells the operator the full-history export is empty when nothing at all
  /// was measured. That case returns null and the prompt says so.
  Future<int?> _retainedLogBytes(LoggingService service) async {
    var total = 0;
    try {
      for (final path in await service.getLogFiles()) {
        try {
          total += await File(path).length();
        } catch (_) {
          continue;
        }
      }
    } catch (_) {
      return null;
    }
    return total;
  }

  /// Ask what the export should contain, naming the cost of each choice.
  Future<LogExportScope?> _askExportScope({
    required int visibleEntries,
    required int? historyBytes,
  }) {
    return showDialog<LogExportScope>(
      context: context,
      builder: (ctx) {
        final colors = SkotiqColors.of(ctx);
        Widget option({
          required String title,
          required String subtitle,
          required LogExportScope scope,
        }) {
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              title,
              style: SkotiqTypography.buttonSm.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textMuted,
              ),
            ),
            onTap: () => Navigator.pop(ctx, scope),
          );
        }

        return AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            side: BorderSide(color: colors.border),
          ),
          title: Text(
            'Export logs',
            style: SkotiqTypography.sectionTitle
                .copyWith(color: colors.textPrimary),
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                option(
                  title: 'Entries on screen',
                  subtitle: '$visibleEntries entries, exactly as filtered',
                  scope: LogExportScope.visible,
                ),
                option(
                  title: 'Full history',
                  subtitle: historyBytes == null
                      ? 'Every retained log file — size could not be read'
                      : 'Every retained log file — about '
                          '${_formatFileSize(historyBytes)}',
                  scope: LogExportScope.fullHistory,
                ),
              ],
            ),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        );
      },
    );
  }

  String _renderVisibleEntries(SkotiqBackend backend, List<LogEntry> logs) {
    final output = StringBuffer();
    output.writeln(backend is NetworkBackend
        ? '=== Skotiq Log Export (remote) ==='
        : '=== Skotiq Log Export (entries on screen) ===');
    output.writeln('Exported: ${DateTime.now().toIso8601String()}');
    if (backend is NetworkBackend) {
      output.writeln('Host: ${backend.serverHost}:${backend.serverPort}');
    }
    output.writeln('Entries: ${logs.length}');
    output.writeln('');
    for (final entry in logs) {
      output.writeln(entry.toString());
    }
    return output.toString();
  }

  Future<void> _exportLogs() async {
    if (_isActionBusy) return;
    // Log tail — on a remote session the local ring buffer is
    // empty; the entries on-screen were fetched from the host. Export those
    // in-memory entries instead of the (empty) local buffer.
    final backend = ref.read(backendProvider);
    final logs = List<LogEntry>.unmodifiable(_filteredLogs);
    final loggingService =
        backend is NetworkBackend ? null : ref.read(loggingServiceProvider);

    // A remote session has no local history to offer, so there is nothing to
    // choose between; locally the two scopes differ by three orders of
    // magnitude and the operator has to be told which one they are getting.
    var scope = LogExportScope.visible;
    if (loggingService != null) {
      final historyBytes = await _retainedLogBytes(loggingService);
      if (!mounted || !identical(ref.read(backendProvider), backend)) return;
      final chosen = await _askExportScope(
        visibleEntries: logs.length,
        historyBytes: historyBytes,
      );
      if (chosen == null ||
          !mounted ||
          !identical(ref.read(backendProvider), backend)) {
        return;
      }
      scope = chosen;
    }

    final timestamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final target = await ref.read(logExportTargetPickerProvider)(
      'skotiq_logs_$timestamp.txt',
    );
    if (target == null ||
        !mounted ||
        !identical(ref.read(backendProvider), backend)) {
      return;
    }

    final token = Object();
    _actionToken = token;
    setState(() => _isExporting = true);
    try {
      if (scope == LogExportScope.fullHistory) {
        await loggingService!.exportLogs(target.path);
      } else {
        await File(target.path)
            .writeAsString(_renderVisibleEntries(backend, logs));
      }

      if (!mounted || !_isCurrentAction(token, backend)) return;
      final writtenBytes = await File(target.path).length();
      if (!mounted || !_isCurrentAction(token, backend)) return;
      // On a phone/tablet the chosen path is the app's PRIVATE sandbox — a
      // path snackbar names a file the user can't reach in Files/Photos.
      // Share on mobile so it's retrievable; path (and size) on desktop.
      await revealExportedFile(
        context,
        target.path,
        subject: 'Skotiq logs',
        desktopMessage: 'Logs exported to: ${target.path} '
            '(${_formatFileSize(writtenBytes)})',
      );
    } catch (e) {
      if (mounted && _isCurrentAction(token, backend)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: SkotiqColors.of(context).error,
          ),
        );
      }
    } finally {
      if (mounted && identical(_actionToken, token)) {
        _actionToken = null;
        setState(() => _isExporting = false);
      }
    }
  }

  /// Pull one full log FILE off the remote host onto this device (share
  /// sheet on mobile, save picker on desktop). Complements Export, which
  /// only writes the on-screen recent entries — a support bundle wants the
  /// complete rolling file.
  Future<void> _downloadLogFile() async {
    if (_isActionBusy) return;
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) return;
    final token = Object();
    _actionToken = token;
    setState(() => _isDownloadingFile = true);
    try {
      final List<RemoteLogFileInfo> files;
      try {
        files = await backend.listServerLogFiles();
      } catch (e) {
        if (mounted && _isCurrentAction(token, backend)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not list the host’s log files: $e'),
              backgroundColor: SkotiqColors.of(context).error,
            ),
          );
        }
        return;
      }
      if (!mounted || !_isCurrentAction(token, backend)) return;
      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The host has no log files.')),
        );
        return;
      }
      final selected = await _pickLogFile(files);
      if (selected == null || !mounted || !_isCurrentAction(token, backend)) {
        return;
      }
      final outcome = await downloadFileToDevice(
        fileName: selected.name,
        tempKey: 'log',
        fetch: (localPath, onProgress) => backend.downloadServerLogFile(
          selected.name,
          localPath,
          onProgress: onProgress,
        ),
      );
      if (!mounted || !_isCurrentAction(token, backend)) return;
      switch (outcome.status) {
        case FileDownloadStatus.saved:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved to ${outcome.savedPath}')),
          );
        case FileDownloadStatus.shared:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Log file ready to share')),
          );
        case FileDownloadStatus.cancelled:
          break;
        case FileDownloadStatus.failed:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(outcome.error ?? 'Download failed'),
              backgroundColor: SkotiqColors.of(context).error,
            ),
          );
      }
    } finally {
      if (mounted && identical(_actionToken, token)) {
        _actionToken = null;
        setState(() => _isDownloadingFile = false);
      }
    }
  }

  Future<RemoteLogFileInfo?> _pickLogFile(List<RemoteLogFileInfo> files) {
    // Current file first, then the dated rollovers newest-first (the daily
    // appender's names sort chronologically).
    final ordered = [...files]..sort((a, b) {
        if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
        return b.name.compareTo(a.name);
      });
    return showDialog<RemoteLogFileInfo>(
      context: context,
      builder: (ctx) {
        final colors = SkotiqColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            side: BorderSide(color: colors.border),
          ),
          title: Text(
            'Download log file',
            style: SkotiqTypography.sectionTitle
                .copyWith(color: colors.textPrimary),
          ),
          content: SizedBox(
            width: 420,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: ordered.length,
              itemBuilder: (_, index) {
                final file = ordered[index];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    LucideIcons.fileText,
                    size: 18,
                    color:
                        file.isCurrent ? colors.primary : colors.textSecondary,
                  ),
                  title: Text(
                    file.name,
                    style: SkotiqTypography.readoutSm.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    '${_formatFileSize(file.sizeBytes)}'
                    '${file.isCurrent ? ' · current' : ''}',
                    style: SkotiqTypography.captionSm.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                  onTap: () => Navigator.pop(ctx, file),
                );
              },
            ),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        );
      },
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  Future<void> _confirmClearLogs() async {
    if (_isActionBusy) return;
    final backend = ref.read(backendProvider);
    final token = Object();
    _actionToken = token;
    setState(() => _isClearing = true);
    final message = backend is NetworkBackend
        ? 'This permanently deletes the remote host’s server log files. '
            'This action cannot be undone.'
        : 'This permanently deletes old local log files. This action cannot '
            'be undone.';
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final colors = SkotiqColors.of(ctx);
          return AlertDialog(
            backgroundColor: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(SkotiqTokens.radiusInline8),
              side: BorderSide(color: colors.border),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration:
                      SkotiqDecorations.chip(colors, tone: colors.error),
                  child: Icon(
                    LucideIcons.alertTriangle,
                    color: colors.error,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Clear logs?',
                  style: SkotiqTypography.sectionTitle
                      .copyWith(color: colors.textPrimary),
                ),
              ],
            ),
            content: Text(
              message,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
            actions: [
              SkotiqButton(
                label: 'Cancel',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () => Navigator.pop(ctx, false),
              ),
              SkotiqButton(
                label: 'Clear',
                variant: ButtonVariant.destructive,
                size: ButtonSize.small,
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          );
        },
      );
      if (confirmed != true || !mounted) return;
      if (!_isCurrentAction(token, backend)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Clear cancelled because the imaging host changed.'),
          ),
        );
        return;
      }
      await _clearLogs(backend, token);
    } finally {
      if (mounted && identical(_actionToken, token)) {
        _actionToken = null;
        setState(() => _isClearing = false);
      }
    }
  }

  Future<void> _clearLogs(SkotiqBackend backend, Object token) async {
    // Log tail — Clear on a remote session must target the
    // server's log files; otherwise the operator presses Clear and sees
    // no change because we're clearing the local (already-empty) buffer.
    try {
      if (backend is NetworkBackend) {
        await backend.clearServerLogs();
      } else {
        await ref.read(loggingServiceProvider).clearLogs();
      }
      if (!mounted || !_isCurrentAction(token, backend)) return;
      _refreshLogs();
      if (backend is NetworkBackend) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Server log files cleared'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Old log files cleared'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (!mounted || !_isCurrentAction(token, backend)) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Clear failed: $e'),
          backgroundColor: SkotiqColors.of(context).error,
        ),
      );
    }
  }
}

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/file_download_service.dart';
import '../../../utils/exported_file_reveal.dart';
import '../../accessible_dropdown.dart';

part 'log_viewer_parts/_export_seams.dart';
part 'log_viewer_parts/_actions.dart';
part 'log_viewer_parts/_controls.dart';

/// Log viewer settings page with live-tailing, filtering, and export.
class LogViewer extends ConsumerStatefulWidget {
  final bool isMobile;

  const LogViewer({super.key, this.isMobile = false});

  @override
  ConsumerState<LogViewer> createState() => _LogViewerState();
}

class _LogViewerState extends ConsumerState<LogViewer>
    with WidgetsBindingObserver {
  LogLevel _minLevel = LogLevel.debug;
  String? _sourceFilter;
  String _searchQuery = '';
  bool _autoScroll = true;
  // 1 Hz live-tail timer. Suspended when the app is backgrounded so a
  // hidden settings tab doesn't keep polling the log buffer.
  Timer? _refreshTimer;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  List<LogEntry> _filteredLogs = [];
  List<LogEntry> _allLogs = [];
  Set<String> _availableSources = {};
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _backendGeneration = 0;
  int _nextRefreshRequest = 0;
  int _lastAppliedRequest = 0;
  Object? _actionToken;
  bool _isExporting = false;
  bool _isClearing = false;
  bool _isDownloadingFile = false;

  bool get _isActionBusy => _actionToken != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        _backendGeneration++;
        _lastAppliedRequest = 0;
        _actionToken = null;
        setState(() {
          _allLogs = [];
          _filteredLogs = [];
          _availableSources = {};
          _sourceFilter = null;
          _isExporting = false;
          _isClearing = false;
          _isDownloadingFile = false;
        });
        _refreshLogs();
      },
    );
    _refreshLogs();
    _startRefreshTimer();
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    // Refresh every second for live tailing
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshLogs();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_refreshTimer == null || !_refreshTimer!.isActive) {
        _refreshLogs();
        _startRefreshTimer();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backendSubscription?.close();
    _refreshTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _refreshLogs() {
    // Log tail — when the active backend is a NetworkBackend we
    // pull from /api/logs/recent so a remote session shows the host's
    // logs, not the local (empty) ring buffer. The local LoggingService
    // path is preserved for FFI / disconnected backends.
    final backend = ref.read(backendProvider);
    final backendGeneration = _backendGeneration;
    final request = ++_nextRefreshRequest;
    if (backend is NetworkBackend) {
      // Fire-and-forget refresh; the user's filters apply once the
      // response lands. Errors silently fall back to whatever was last
      // rendered — surfaced via the SnackBars on Clear/Export so the
      // operator still gets feedback when the action they triggered
      // failed.
      backend.fetchRecentServerLogs(limit: 500).then((logs) {
        if (!mounted ||
            backendGeneration != _backendGeneration ||
            request < _lastAppliedRequest ||
            !identical(ref.read(backendProvider), backend)) {
          return;
        }
        _lastAppliedRequest = request;
        setState(() {
          _allLogs = logs;
          _availableSources =
              logs.where((e) => e.source != null).map((e) => e.source!).toSet();
          _applyFilters();
        });
        if (_autoScroll && _scrollController.hasClients) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController
                  .jumpTo(_scrollController.position.maxScrollExtent);
            }
          });
        }
      }).catchError((Object e) {
        // Keep the previous frame on-screen. The 1-Hz refresh timer will
        // retry on the next tick.
      });
      return;
    }

    final loggingService = ref.read(loggingServiceProvider);
    final logs = loggingService.getRecentLogs();

    if (!mounted ||
        backendGeneration != _backendGeneration ||
        request < _lastAppliedRequest ||
        !identical(ref.read(backendProvider), backend)) {
      return;
    }
    _lastAppliedRequest = request;

    setState(() {
      _allLogs = logs;
      _availableSources =
          logs.where((e) => e.source != null).map((e) => e.source!).toSet();
      _applyFilters();
    });

    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  void _applyFilters() {
    _filteredLogs = _allLogs.where((entry) {
      if (entry.level.index < _minLevel.index) return false;
      if (_sourceFilter != null && entry.source != _sourceFilter) return false;
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        final matchesMessage = entry.message.toLowerCase().contains(query);
        final matchesSource =
            entry.source?.toLowerCase().contains(query) ?? false;
        if (!matchesMessage && !matchesSource) return false;
      }
      return true;
    }).toList();
  }

  bool _isCurrentAction(Object token, SkotiqBackend backend) =>
      mounted &&
      identical(_actionToken, token) &&
      identical(ref.read(backendProvider), backend);

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isMobile = widget.isMobile;
    final padding =
        isMobile ? const EdgeInsets.all(16) : const EdgeInsets.all(32);

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMobile) ...[
            Text(
              'Logs',
              style: SkotiqTypography.pageTitle.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'View application logs with filtering and export',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 32),
          ],
          // Filter bar
          _buildFilterBar(colors, isMobile),
          const SizedBox(height: 12),
          // Action buttons
          _buildActionBar(colors, isMobile),
          const SizedBox(height: 12),
          // Log count indicator
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${_filteredLogs.length} of ${_allLogs.length} entries',
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textMuted,
              ),
            ),
          ),
          // Log entries list
          Expanded(
            child: SkotiqPanel(
              child: _filteredLogs.isEmpty
                  ? Center(
                      child: Text(
                        _allLogs.isEmpty
                            ? 'No log entries yet'
                            : 'No entries match current filters',
                        style: SkotiqTypography.bodySm.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      itemCount: _filteredLogs.length,
                      itemBuilder: (context, index) {
                        return _buildLogEntry(
                            _filteredLogs[index], colors, isMobile);
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(SkotiqColors colors, bool isMobile) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Level filter buttons
        _LevelFilterButton(
          label: 'All',
          isSelected: _minLevel == LogLevel.debug,
          onTap: () => setState(() {
            _minLevel = LogLevel.debug;
            _applyFilters();
          }),
        ),
        _LevelFilterButton(
          label: 'Warn+',
          isSelected: _minLevel == LogLevel.warning,
          color: colors.warning,
          onTap: () => setState(() {
            _minLevel = LogLevel.warning;
            _applyFilters();
          }),
        ),
        _LevelFilterButton(
          label: 'Error+',
          isSelected: _minLevel == LogLevel.error,
          color: colors.error,
          onTap: () => setState(() {
            _minLevel = LogLevel.error;
            _applyFilters();
          }),
        ),
        // Source dropdown
        if (_availableSources.isNotEmpty) _buildSourceDropdown(colors),
        // Search field
        SizedBox(
          width: isMobile ? 160 : 200,
          height: 32,
          child: TextField(
            controller: _searchController,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'Search logs...',
              hintStyle: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
              prefixIcon:
                  Icon(LucideIcons.search, size: 14, color: colors.textMuted),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 32, maxWidth: 32),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                borderSide: BorderSide(color: colors.primary),
              ),
              filled: true,
              fillColor: colors.well,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              isDense: true,
            ),
            onChanged: (value) => setState(() {
              _searchQuery = value;
              _applyFilters();
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildSourceDropdown(SkotiqColors colors) {
    final sortedSources = _availableSources.toList()..sort();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: AccessibleDropdown<String?>(
          value: _sourceFilter,
          isDense: true,
          hint: Text(
            'All sources',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
          icon:
              Icon(LucideIcons.chevronDown, size: 14, color: colors.textMuted),
          dropdownColor: colors.surface,
          style: SkotiqTypography.caption.copyWith(
            color: colors.textPrimary,
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text('All sources',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textPrimary,
                  )),
            ),
            ...sortedSources.map((s) => DropdownMenuItem<String?>(
                  value: s,
                  child: Text(s,
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.textPrimary,
                      )),
                )),
          ],
          onChanged: (value) => setState(() {
            _sourceFilter = value;
            _applyFilters();
          }),
        ),
      ),
    );
  }

  Widget _buildActionBar(SkotiqColors colors, bool isMobile) {
    final isRemote = ref.watch(backendProvider) is NetworkBackend;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Auto-scroll toggle
        _ActionToggle(
          icon: LucideIcons.arrowDownToLine,
          label: 'Auto-scroll',
          isActive: _autoScroll,
          onTap: () => setState(() => _autoScroll = !_autoScroll),
        ),
        SkotiqButton(
          label: 'Copy all',
          icon: LucideIcons.copy,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: _filteredLogs.isEmpty ? null : _copyAllToClipboard,
        ),
        SkotiqButton(
          label: _isExporting ? 'Exporting...' : 'Export',
          icon: LucideIcons.download,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          isLoading: _isExporting,
          onPressed: _isActionBusy ? null : _exportLogs,
        ),
        // Full-file download only exists for a remote host — locally the
        // files are already on this machine and Export covers the need.
        if (isRemote)
          SkotiqButton(
            label: _isDownloadingFile ? 'Downloading...' : 'Download file',
            icon: LucideIcons.fileDown,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            isLoading: _isDownloadingFile,
            onPressed: _isActionBusy ? null : _downloadLogFile,
          ),
        SkotiqButton(
          label: _isClearing ? 'Clearing...' : 'Clear',
          icon: LucideIcons.trash2,
          variant: ButtonVariant.destructive,
          size: ButtonSize.small,
          isLoading: _isClearing,
          onPressed: _isActionBusy ? null : _confirmClearLogs,
        ),
      ],
    );
  }

  Widget _buildLogEntry(LogEntry entry, SkotiqColors colors, bool isMobile) {
    final levelColor = _levelColor(entry.level);
    final levelLabel = _levelLabel(entry.level);
    final timeStr = _formatTimestamp(entry.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timestamp
          Text(
            timeStr,
            style: SkotiqTypography.readoutXs.copyWith(
              color: colors.textMuted,
            ),
          ),
          const SizedBox(width: 8),
          // Level badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: SkotiqDecorations.chip(colors, tone: levelColor),
            child: Text(
              levelLabel,
              style: SkotiqTypography.monoCaption.copyWith(
                fontWeight: FontWeight.w700,
                color: levelColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Source tag
          if (entry.source != null) ...[
            Text(
              '[${entry.source}]',
              style: SkotiqTypography.readoutXs.copyWith(
                color: colors.primary.withValues(alpha: 0.8),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
          ],
          // Message
          Expanded(
            child: Text(
              entry.message,
              style: SkotiqTypography.readoutXs.copyWith(
                color: entry.level.index >= LogLevel.error.index
                    ? levelColor
                    : colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}

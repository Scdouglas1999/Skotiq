// Mobile session picker. Lists past sequence runs newest-
// first; tap a row to drill into the replay scrubber.
//
// Pulls rows from `NetworkBackend.fetchSequenceRuns` (the existing
// endpoint). The local FFI backend cannot serve this list
// because the picker is part of the phone-only replay surface; the
// desktop runs its sequence history off the Drift DB directly.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'session_replay_screen.dart';

/// Phone surface for selecting a past run to replay. Renders a
/// paginated list of [RemoteSequenceRun] rows; tap a row to open
/// the [SessionReplayScreen].
class SessionPickerScreen extends ConsumerStatefulWidget {
  const SessionPickerScreen({super.key});

  @override
  ConsumerState<SessionPickerScreen> createState() =>
      _SessionPickerScreenState();
}

class _SessionPickerScreenState extends ConsumerState<SessionPickerScreen> {
  // Page size used by the endpoint. Matches the default the
  // server clamps to so the "Load more" cadence is predictable on a
  // phone screen (about 8 rows at 12 dp row height per visible page).
  static const int _pageSize = 50;

  final List<RemoteSequenceRun> _runs = [];
  int _total = 0;
  int _nextOffset = 0;
  int _generation = 0;
  bool _loading = false;
  bool _exhausted = false;
  Object? _error;
  SkotiqBackend? _loadedBackend;

  @override
  void initState() {
    super.initState();
    // We deliberately defer the first fetch to the next frame so the
    // backend provider has had a chance to swing into NetworkBackend
    // mode after the app finished its setup gate. Calling synchronously
    // from initState would hit the local-only FfiBackend on first cold
    // launch and surface a misleading "fetchSequenceRuns is not
    // implemented" exception.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadMore());
    });
  }

  Future<void> _loadMore() async {
    if (!mounted || _loading || _exhausted) return;
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) {
      // Replay is phone-only. Local FFI backend cannot list runs over
      // this endpoint. Surface a clear message rather than throwing.
      setState(() {
        _error = const _LocalBackendNotSupported();
        _loading = false;
      });
      return;
    }
    if (_loadedBackend != null && !identical(_loadedBackend, backend)) {
      await _refresh();
      return;
    }
    _loadedBackend = backend;
    final requestGeneration = _generation;
    final requestOffset = _nextOffset;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await backend.fetchSequenceRuns(
        limit: _pageSize,
        offset: requestOffset,
      );
      if (!mounted) return;
      if (requestGeneration != _generation ||
          !identical(ref.read(backendProvider), backend)) {
        if (requestGeneration == _generation) {
          unawaited(_refresh());
        }
        return;
      }
      if (page.items.length > _pageSize) {
        throw StateError(
          'The server returned ${page.items.length} runs for a '
          '$_pageSize-row request.',
        );
      }
      if (requestOffset > 0 && page.total != _total) {
        throw StateError(
          'Run history changed while loading more results. Refresh the '
          'history to load a consistent list.',
        );
      }
      final knownIds = _runs.map((run) => run.id).toSet();
      final newRuns = <RemoteSequenceRun>[];
      for (final run in page.items) {
        if (knownIds.add(run.id)) {
          newRuns.add(run);
        }
      }
      if (requestOffset + page.items.length > page.total) {
        throw StateError(
          'The server returned more run rows than its advertised total.',
        );
      }
      setState(() {
        _runs.addAll(newRuns);
        _nextOffset = requestOffset + page.items.length;
        _total = page.total;
        final unexpectedlyEmpty =
            page.items.isEmpty && requestOffset < page.total;
        _exhausted = !unexpectedlyEmpty && _nextOffset >= page.total;
        if (unexpectedlyEmpty) {
          _error = StateError(
            'The server reported more runs but returned an empty page. '
            'Retry or refresh the history to try again.',
          );
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (requestGeneration != _generation ||
          !identical(ref.read(backendProvider), backend)) {
        if (requestGeneration == _generation) {
          unawaited(_refresh());
        }
        return;
      }
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    _generation++;
    setState(() {
      _runs.clear();
      _total = 0;
      _nextOffset = 0;
      _loading = false;
      _exhausted = false;
      _error = null;
      _loadedBackend = null;
    });
    await _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous != null && !identical(previous, next)) {
        unawaited(_refresh());
      }
    });
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        title: const Text('Session History'),
        actions: [
          IconButton(
            tooltip: 'Refresh history',
            onPressed: _loading ? null : () => unawaited(_refresh()),
            icon: const Icon(LucideIcons.refreshCw),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: colors.border),
        ),
      ),
      body: _buildBody(colors),
    );
  }

  Widget _buildBody(SkotiqColors colors) {
    final err = _error;
    if (err != null && _runs.isEmpty) {
      if (err is _LocalBackendNotSupported) {
        return const EmptyState(
          icon: LucideIcons.wifiOff,
          title: 'Connect to a server',
          body:
              'Session replay requires the phone to be paired with a Skotiq server. '
              "Replay reads from the server's database, not local-only state.",
        );
      }
      return _ErrorRetry(error: err, onRetry: _loadMore);
    }
    if (_runs.isEmpty && _loading) {
      return const Center(
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
      );
    }
    if (_runs.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.history,
        title: 'No past runs yet',
        body: 'Once you finish a sequence run, it will appear here for replay.',
      );
    }

    final showLoadMore =
        _error != null || (!_exhausted && _nextOffset < _total);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _runs.length + (showLoadMore ? 1 : 0),
      separatorBuilder: (_, __) => Divider(height: 1, color: colors.border),
      itemBuilder: (context, index) {
        if (index >= _runs.length) {
          return _LoadMoreTile(
            loading: _loading,
            error: _error,
            onTap: _loadMore,
          );
        }
        final run = _runs[index];
        return _RunRow(run: run, onTap: () => _openReplay(run));
      },
    );
  }

  void _openReplay(RemoteSequenceRun run) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionReplayScreen(runId: run.id),
      ),
    );
  }
}

/// Marker sentinel error used to differentiate the "no NetworkBackend"
/// case from a genuine fetch failure. We keep it as a private type so
/// only the picker screen reads it; the rest of the system treats
/// "no NetworkBackend" as a user-friendly empty state, not an error.
class _LocalBackendNotSupported implements Exception {
  const _LocalBackendNotSupported();
}

class _RunRow extends StatelessWidget {
  final RemoteSequenceRun run;
  final VoidCallback onTap;

  const _RunRow({required this.run, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final duration = run.endedAt?.difference(run.startedAt);
    final stats = _parseStats(run.statsJson);
    final frameCount =
        stats['framesCaptured'] as int? ?? stats['frame_count'] as int? ?? 0;
    final targetBreakdown = stats['targetBreakdown'];
    String? targetName;
    if (targetBreakdown is Map && targetBreakdown.isNotEmpty) {
      targetName = targetBreakdown.keys.first.toString();
    }
    final statusColor = _statusColor(run.status, colors);
    return Material(
      color: colors.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(LucideIcons.history, size: 18, color: colors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      run.sequenceName ?? 'Untitled sequence',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: SkotiqTypography.fontSize15,
                        color: colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(targetName, run.startedAt, duration),
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: colors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _Chip(
                          icon: LucideIcons.image,
                          label: '$frameCount frames',
                          colors: colors,
                        ),
                        const SizedBox(width: 6),
                        _Chip(
                          icon: LucideIcons.circle,
                          label: run.status,
                          colors: colors,
                          accent: statusColor,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 18,
                color: colors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> _parseStats(String? statsJson) {
    if (statsJson == null || statsJson.isEmpty) return const {};
    try {
      final parsed = jsonDecode(statsJson);
      if (parsed is Map) return parsed.cast<String, dynamic>();
    } catch (_) {
      // Malformed stats blob is non-fatal — the picker just shows a 0
      // frame count and the operator can still tap through.
    }
    return const {};
  }

  String _subtitle(String? target, DateTime startedAt, Duration? duration) {
    final time = _formatStart(startedAt);
    final dur = duration != null
        ? DurationFormat.of(duration, style: DurationStyle.hoursMinutes)
        : 'in progress';
    if (target != null && target.isNotEmpty) {
      return '$target  •  $time  •  $dur';
    }
    return '$time  •  $dur';
  }

  String _formatStart(DateTime t) {
    final local = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Color _statusColor(String status, SkotiqColors colors) {
    switch (status.toLowerCase()) {
      case 'completed':
        return colors.success;
      case 'failed':
      case 'aborted':
        return colors.error;
      case 'running':
        return colors.primary;
      default:
        return colors.textSecondary;
    }
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final SkotiqColors colors;
  final Color? accent;

  const _Chip({
    required this.icon,
    required this.label,
    required this.colors,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent ?? colors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadMoreTile extends StatelessWidget {
  final bool loading;
  final Object? error;
  final VoidCallback onTap;

  const _LoadMoreTile({
    required this.loading,
    required this.error,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    return InkWell(
      onTap: loading ? null : onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Center(
          child: loading
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: SkotiqSpinner(size: 18, color: colors.primary),
                )
              : Text(
                  error != null ? 'Retry loading' : 'Load more',
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorRetry({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.cloudOff, size: 36, color: colors.error),
            const SizedBox(height: 12),
            Text(
              'Failed to load run history',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize16,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            SkotiqButton(label: 'Retry', onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}

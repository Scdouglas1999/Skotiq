import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../sequencer/run_status_presentation.dart';

/// Where the run list lives.
const String kSessionReplayRoutePath = '/session-replay';

/// The location of one run's replay.
String sessionReplayLocation(int runId) => '$kSessionReplayRoutePath/$runId';

/// Past sequence runs on the linked imaging host, newest first; a row opens
/// that run's replay.
///
/// Replay reads the host's run history, event log and frame records, so it
/// needs a linked host. On a window that is itself the imaging host (or a
/// phone that skipped connecting) the screen says so instead of listing.
class SessionPickerScreen extends ConsumerStatefulWidget {
  const SessionPickerScreen({super.key});

  @override
  ConsumerState<SessionPickerScreen> createState() =>
      _SessionPickerScreenState();
}

class _SessionPickerScreenState extends ConsumerState<SessionPickerScreen> {
  // The host clamps larger requests to this.
  static const int _pageSize = 50;

  final List<RemoteSequenceRun> _runs = [];
  int _total = 0;
  int _nextOffset = 0;
  int _generation = 0;
  bool _loading = false;
  bool _exhausted = false;
  Object? _error;
  bool _notLinked = false;
  SkotiqBackend? _loadedBackend;

  @override
  void initState() {
    super.initState();
    // After the first frame: the phone swaps in its linked backend while the
    // shell is mounting, and a fetch from initState would ask the one it is
    // replacing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadMore());
    });
  }

  Future<void> _loadMore() async {
    if (!mounted || _loading || _exhausted) return;
    final backend = ref.read(backendProvider);
    final linkedHost = backend.remoteHost;
    if (linkedHost == null) {
      setState(() {
        _notLinked = true;
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
      _notLinked = false;
      _loading = true;
      _error = null;
    });
    try {
      final page = await linkedHost.imagingRecords.fetchSequenceRuns(
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
          'The host returned ${page.items.length} runs for a '
          '$_pageSize-row request.',
        );
      }
      if (requestOffset > 0 && page.total != _total) {
        throw StateError(
          'Run history changed while loading more runs. Refresh to load the '
          'list again.',
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
          'The host returned more runs than it said it has.',
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
            'The host said it has more runs but sent none. Try again, or '
            'refresh the list.',
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
    final colors = SkotiqColors.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              icon: SkotiqIcons.history,
              title: 'Session replay',
              actions: [
                if (!_notLinked)
                  SkotiqIconButton(
                    icon: SkotiqIcons.refresh,
                    tooltip: 'Refresh the run list',
                    onPressed: _loading ? null : () => unawaited(_refresh()),
                  ),
              ],
            ),
            Expanded(child: _buildBody(colors)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(SkotiqColors colors) {
    if (_notLinked) return const SessionReplayNeedsRig();
    final err = _error;
    if (err != null && _runs.isEmpty) {
      return EmptyState(
        icon: SkotiqIcons.disconnected,
        title: 'Could not load past runs',
        body: userFacingError(err),
        action: SkotiqButton(
          label: 'Try again',
          icon: SkotiqIcons.refresh,
          onPressed: () => unawaited(_refresh()),
        ),
      );
    }
    if (_runs.isEmpty && (_loading || _loadedBackend == null)) {
      return const Center(
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
      );
    }
    if (_runs.isEmpty) {
      return const EmptyState(
        icon: SkotiqIcons.history,
        title: 'No past runs yet',
        body: 'When a sequence run ends on the rig, it appears here and you '
            'can replay it.',
      );
    }

    final showLoadMore =
        _error != null || (!_exhausted && _nextOffset < _total);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      itemCount: _runs.length + (showLoadMore ? 1 : 0),
      separatorBuilder: (_, __) => Divider(height: 1, color: colors.border),
      itemBuilder: (context, index) {
        if (index >= _runs.length) {
          return _LoadMoreRow(
            loading: _loading,
            error: _error,
            onTap: _loadMore,
          );
        }
        final run = _runs[index];
        return _RunRow(
          run: run,
          onTap: () => context.push(sessionReplayLocation(run.id)),
        );
      },
    );
  }
}

/// What replay shows when this app is not linked to an imaging host.
class SessionReplayNeedsRig extends StatelessWidget {
  const SessionReplayNeedsRig({super.key});

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: SkotiqIcons.disconnected,
      title: 'Replay needs a connected rig',
      body: 'Session replay reads past runs from the imaging host. Connect '
          'this app to your rig, then open Session replay again.',
    );
  }
}

class _RunRow extends StatelessWidget {
  final RemoteSequenceRun run;
  final VoidCallback onTap;

  const _RunRow({required this.run, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final stats = _stats(run.statsJson);
    final target = stats?.targetBreakdown.keys.firstOrNull;
    return Semantics(
      button: true,
      enabled: true,
      child: Material(
        color: colors.surface,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: SkotiqTokens.minTouchTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceLg,
                vertical: SkotiqTokens.spaceMd,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          run.sequenceName ?? 'Untitled sequence',
                          style: SkotiqTypography.bodyStrong.copyWith(
                            color: colors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: SkotiqTokens.spaceXs),
                        Text(
                          _subtitle(target),
                          style: SkotiqTypography.caption.copyWith(
                            color: colors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: SkotiqTokens.spaceXs),
                        Wrap(
                          spacing: SkotiqTokens.spaceXs,
                          runSpacing: SkotiqTokens.spaceXs,
                          children: [
                            SkotiqChip(
                              label: runStatusLabel(run.status),
                              tone: _statusTone(run.status),
                              dot: true,
                            ),
                            if (stats != null)
                              SkotiqChip(
                                icon: SkotiqIcons.image,
                                label: _frames(stats.framesCaptured),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Icon(
                    SkotiqIcons.chevronRight,
                    size: SkotiqTokens.iconSm,
                    color: colors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The run's stored statistics, or null when the host has none for it or
  /// sent a blob this build cannot read; the row then leaves the frame count
  /// out rather than claiming zero.
  static ParsedRunStats? _stats(String? statsJson) {
    if (statsJson == null || statsJson.isEmpty) return null;
    try {
      return ParsedRunStats.fromJson(statsJson);
    } on Object {
      return null;
    }
  }

  String _subtitle(String? target) {
    final started = ClockFormat.dateHm(run.startedAt.toLocal());
    final ended = run.endedAt;
    // A run with no end that is not running was cut off (the host quit or
    // crashed), so its length is not known.
    final length = ended == null
        ? (run.status == 'running' || run.status == 'paused'
            ? 'still running'
            : 'length unknown')
        : DurationFormat.of(
            ended.difference(run.startedAt),
            style: DurationStyle.short,
          );
    return [
      if (target != null && target.isNotEmpty) target,
      started,
      length,
    ].join('  ·  ');
  }

  static String _frames(int count) => count == 1 ? '1 frame' : '$count frames';

  /// The tones the Sequencer History gives the same statuses.
  static ChipTone _statusTone(String status) => switch (status) {
        'completed' => ChipTone.success,
        'failed' => ChipTone.error,
        'aborted' => ChipTone.warning,
        _ => ChipTone.neutral,
      };
}

class _LoadMoreRow extends StatelessWidget {
  final bool loading;
  final Object? error;
  final VoidCallback onTap;

  const _LoadMoreRow({
    required this.loading,
    required this.error,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final failure = error;
    return Padding(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        children: [
          if (failure != null && !loading) ...[
            Text(
              userFacingError(failure),
              textAlign: TextAlign.center,
              style: SkotiqTypography.caption.copyWith(color: colors.error),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
          ],
          if (loading)
            SkotiqSpinner(size: SkotiqTokens.iconMd, color: colors.primary)
          else
            SkotiqButton(
              label: failure != null ? 'Try again' : 'Load more',
              variant: ButtonVariant.secondary,
              onPressed: onTap,
            ),
        ],
      ),
    );
  }
}

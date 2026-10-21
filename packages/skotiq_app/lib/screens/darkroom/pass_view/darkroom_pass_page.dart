// The Darkroom's page for one pass: the pass view over the recorder's log,
// redrawn on every report and once a second for the clocks while the pass
// runs, and a record with its final numbers once it has ended.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../session_review/auto_integration_service.dart';
import 'pass_view.dart';

class DarkroomPassPage extends ConsumerStatefulWidget {
  const DarkroomPassPage({super.key, required this.runId});

  final String runId;

  @override
  ConsumerState<DarkroomPassPage> createState() => _DarkroomPassPageState();
}

class _DarkroomPassPageState extends ConsumerState<DarkroomPassPage> {
  Timer? _clock;
  bool _stopRequested = false;

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  /// Ticks the clocks once a second while the pass runs; stops with it.
  void _keepClock(bool running) {
    if (running && _clock == null) {
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!running && _clock != null) {
      _clock?.cancel();
      _clock = null;
    }
  }

  Future<void> _stop(PassSnapshot snapshot) async {
    if (_stopRequested) return;
    setState(() => _stopRequested = true);
    final active = snapshot.activeSpan;
    final sessionId = snapshot.timeline.sessionId;
    try {
      // The lanes run in the native integration, which stops at its next
      // sub; the drafts run in a Darkroom job, which stops at its next step.
      if (active == null || active.$1 != null) {
        await ref.read(passRunCancellerProvider).cancel(widget.runId);
      }
      if (sessionId != null) {
        await ref
            .read(autoIntegrationServiceProvider)
            .cancelDarkroomPassForSession(
              sessionId,
              reason: 'Stopped from the Darkroom pass view',
            );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _stopRequested = false);
      SkotiqToastHelper.show(
        context: context,
        message: 'The pass could not be stopped: $error',
        severity: SkotiqAlertSeverity.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final timeline = ref.watch(darkroomPassTimelineProvider(widget.runId));
    ref.listen(darkroomPassTimelineProvider(widget.runId), (previous, next) {
      final was = previous?.valueOrNull?.ended ?? false;
      final now = next.valueOrNull?.ended ?? false;
      if (!was && now && _stopRequested) {
        // A stop that landed after the last check would otherwise stop the
        // next run of this night.
        unawaited(
          ref
              .read(passRunCancellerProvider)
              .clear(widget.runId)
              .catchError((Object _) => ''),
        );
      }
    });
    return timeline.when(
      loading: () => const Center(
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
      ),
      error: (error, _) => Center(
        child: EmptyState(
          icon: SkotiqIcons.imageOff,
          title: 'This pass could not be read',
          body: '$error',
        ),
      ),
      data: (tl) {
        if (tl == null) {
          _keepClock(false);
          return Center(
            child: EmptyState(
              icon: SkotiqIcons.history,
              title: 'No record of this pass',
              body: 'Nothing on this host reported a pass named '
                  '${widget.runId}. Records are kept next to the Darkroom '
                  'drafts, in the image output folder.',
            ),
          );
        }
        _keepClock(!tl.ended);
        final snapshot = tl.snapshot(now: DateTime.now());
        return ColoredBox(
          color: colors.background,
          child: PassView(
            snapshot: snapshot,
            onStop: tl.ended || _stopRequested ? null : () => _stop(snapshot),
          ),
        );
      },
    );
  }
}

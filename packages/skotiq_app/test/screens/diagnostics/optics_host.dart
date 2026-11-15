import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/analytics/quick_capture_selection.dart';
import 'package:skotiq_app/screens/diagnostics/diagnostics_screen.dart';
import 'package:skotiq_core/providers.dart';

/// Hosts [OpticsDiagnosticsView] the way Analytics > Session does: on the
/// picked session, else the one in progress, with "Open the latest session"
/// picking the newest.
class OpticsHost extends ConsumerWidget {
  const OpticsHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(allSessionsProvider).valueOrNull ?? const [];
    return OpticsDiagnosticsView(
      sessionId: ref.watch(analyticsSessionPickProvider) ??
          ref.watch(sessionStateProvider).dbSessionId,
      onOpenLatest: sessions.isEmpty
          ? null
          : () => ref.read(analyticsSessionPickProvider.notifier).state =
              sessions
                  .reduce((a, b) => a.startTime.isAfter(b.startTime) ? a : b)
                  .id,
    );
  }
}

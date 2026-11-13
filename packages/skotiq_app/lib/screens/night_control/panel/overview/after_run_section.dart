// "After the run" on Tonight's Overview: what a run that ended leaves to do.
// Starting again is the header's Start; this is the rest: look at what was
// taken, and put away what the run left on.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/providers.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../../router/app_routes.dart';
import '../../data/session/session_format.dart';
import '../../night_control_contracts.dart';
import '../panel_widgets.dart';

/// What a run that ended left behind.
@immutable
class NightAfterRunVm {
  const NightAfterRunVm({
    required this.sessionId,
    required this.mountUnparked,
    required this.coolerOn,
  });

  /// The session the run recorded: the one still open, else the newest on
  /// record. Null when there is none.
  final int? sessionId;

  /// The mount is connected and not parked.
  final bool mountUnparked;

  /// The camera is connected with its cooler on.
  final bool coolerOn;

  @override
  bool operator ==(Object other) =>
      other is NightAfterRunVm &&
      other.sessionId == sessionId &&
      other.mountUnparked == mountUnparked &&
      other.coolerOn == coolerOn;

  @override
  int get hashCode => Object.hash(sessionId, mountUnparked, coolerOn);
}

final nightAfterRunProvider = Provider<NightAfterRunVm>((ref) {
  final open = ref.watch(sessionStateProvider.select((s) => s.dbSessionId));
  return NightAfterRunVm(
    sessionId:
        open ?? ref.watch(allSessionsProvider).valueOrNull?.firstOrNull?.id,
    mountUnparked: ref.watch(
      mountStateProvider.select(
        (m) => nightConnected(m.connectionState) && !m.isParked,
      ),
    ),
    coolerOn: ref.watch(
      cameraStateProvider.select(
        (c) => nightConnected(c.connectionState) && c.isCooling,
      ),
    ),
  );
});

class NightAfterRunSection extends ConsumerWidget {
  const NightAfterRunSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final after = ref.watch(nightAfterRunProvider);
    final sessionId = after.sessionId;
    void open(NightPanelTab tab) =>
        ref.read(nightPanelTabProvider.notifier).state = tab;
    return NightAfterRunView(
      onReview: sessionId == null
          ? null
          : () => context.push(AppRoutes.sessionReviewOfSession(sessionId)),
      onPark: after.mountUnparked ? () => open(NightPanelTab.mount) : null,
      onWarm: after.coolerOn ? () => open(NightPanelTab.camera) : null,
    );
  }
}

/// The section, apart from the providers so a test can pump it. A null
/// [onPark] or [onWarm] means there is nothing to put away, and its button
/// is left out; a null [onReview] means no session was recorded.
class NightAfterRunView extends StatelessWidget {
  const NightAfterRunView({
    super.key,
    required this.onReview,
    required this.onPark,
    required this.onWarm,
  });

  final VoidCallback? onReview;
  final VoidCallback? onPark;
  final VoidCallback? onWarm;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    return NightPanelSection(
      title: l10n.text('nightAfterRunTitle'),
      children: <Widget>[
        NightPanelButtonGrid(
          columns: 1,
          buttons: <NightPanelButtonSpec>[
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightAfterRun.review'),
              label: l10n.text('nightAfterRunReview'),
              onPressed: onReview,
              disabledReason: l10n.text('nightAfterRunNoSession'),
            ),
          ],
        ),
        if (onPark != null || onWarm != null)
          NightPanelButtonGrid(
            columns: 2,
            buttons: <NightPanelButtonSpec>[
              if (onPark != null)
                NightPanelButtonSpec(
                  key: const ValueKey<String>('nightAfterRun.park'),
                  label: l10n.text('nightAfterRunPark'),
                  tooltip: l10n.text('nightAfterRunParkHint'),
                  onPressed: onPark,
                ),
              if (onWarm != null)
                NightPanelButtonSpec(
                  key: const ValueKey<String>('nightAfterRun.warm'),
                  label: l10n.text('nightAfterRunWarm'),
                  tooltip: l10n.text('nightAfterRunWarmHint'),
                  onPressed: onWarm,
                ),
            ],
          ),
      ],
    );
  }
}

// Tonight's keyboard: the panel tabs, the run's pause and resume, and the
// three actions a night repeats most. Every key carries Alt, as the
// Sequencer's do, so typing in a field never triggers one. Stop has no key:
// it stays a deliberate hold.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/sequence_action_service.dart';
import '../../utils/snackbar_helper.dart';
import 'actions/night_action_controller.dart';
import 'data/plan/night_header_provider.dart';
import 'night_control_contracts.dart';

/// The keys, for the action bar's list of them.
const List<(String, String)> kNightShortcutKeys = <(String, String)>[
  ('Alt+S', 'nightKeySnapshot'),
  ('Alt+L', 'nightKeyLoop'),
  ('Alt+F', 'nightKeyAutofocus'),
  ('Alt+P', 'nightKeyPause'),
  ('Alt+1–6', 'nightKeyTabs'),
];

class NightControlShortcuts extends ConsumerWidget {
  const NightControlShortcuts({super.key, required this.child});

  final Widget child;

  static const List<LogicalKeyboardKey> _tabKeys = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void act(ManualActionId id) {
      nightOpenPanelTab(ref, id.panelTab);
      unawaited(ref.read(nightActionApiProvider).run(id));
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        for (var i = 0; i < NightPanelTab.values.length; i++)
          SingleActivator(_tabKeys[i], alt: true): () =>
              nightOpenPanelTab(ref, NightPanelTab.values[i]),
        const SingleActivator(LogicalKeyboardKey.keyS, alt: true): () =>
            act(ManualActionId.snapshot),
        const SingleActivator(LogicalKeyboardKey.keyL, alt: true): () =>
            act(ManualActionId.loop),
        const SingleActivator(LogicalKeyboardKey.keyF, alt: true): () =>
            act(ManualActionId.autofocus),
        const SingleActivator(LogicalKeyboardKey.keyP, alt: true): () =>
            unawaited(_pauseOrResume(context, ref)),
      },
      // A scope of its own, so focus that leaves a field lands back inside
      // these bindings instead of above them.
      child: FocusScope(autofocus: true, child: child),
    );
  }

  /// What the header's Pause or Resume would do now, under the same gating.
  static Future<void> _pauseOrResume(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final header = ref.read(nightHeaderProvider);
    if (header.pauseResume?.enabled != true) return;
    final service = ref.read(sequenceActionServiceProvider);
    final result = await (header.phase == NightRunPhase.running
        ? service.pause()
        : service.resume());
    if (!context.mounted) return;
    context.showCommandActionResult(result);
  }
}

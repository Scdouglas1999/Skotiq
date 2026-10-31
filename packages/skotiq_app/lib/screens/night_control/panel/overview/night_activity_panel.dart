import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../night_control_contracts.dart';
import '../focus/focus_panel_vm.dart';
import '../focus/focus_tab.dart';
import '../panel_widgets.dart';
import 'night_activity_provider.dart';

/// A projection of the current run operation. It does not poll hardware or
/// issue commands; the sequence and device tabs retain control ownership.
class NightActivityPanel extends ConsumerWidget {
  const NightActivityPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(nightActivityProvider);
    final l10n = SkotiqLocalizations.of(context);
    final title = vm.title.resolve(l10n);
    final contextNote = [
      if (vm.context != null) vm.context!.resolve(l10n),
      if (vm.target != null) vm.target!,
    ].join(' · ');
    final terminal = switch (vm.kind) {
      NightActivityKind.paused ||
      NightActivityKind.stopping ||
      NightActivityKind.finished ||
      NightActivityKind.failed =>
        true,
      _ => false,
    };
    final body = vm.kind == NightActivityKind.focus
        ? NightAutofocusSection(
            key: ValueKey(vm.kind),
            vm: ref.watch(nightFocusPanelProvider),
            title: title,
            contextNote: contextNote,
            showControls: false,
          )
        : NightPanelSection(
            key: ValueKey(vm.kind),
            title: title,
            children: [
              if (contextNote.isNotEmpty) NightPanelNote(contextNote),
              if (!terminal)
                Semantics(
                    label: title,
                    child: SkotiqProgressBar(
                      value: vm.progress ?? 0,
                      indeterminate: vm.progress == null,
                      style: SkotiqProgressStyle.thin,
                      showPercentage: vm.progress != null,
                    )),
              if (vm.metrics.isNotEmpty)
                MetricGrid(
                    columns: 2,
                    items: nightMetricItems(vm.metrics, l10n),
                    semanticLabel: title),
              if (vm.detail != null && vm.detail!.isNotEmpty)
                NightPanelNote(vm.detail!,
                    tone: vm.kind == NightActivityKind.failed
                        ? MetricTone.bad
                        : null),
            ],
          );
    return AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : SkotiqTokens.durationNormal,
      curve: SkotiqTokens.curveStandard,
      alignment: Alignment.topCenter,
      child: body,
    );
  }
}

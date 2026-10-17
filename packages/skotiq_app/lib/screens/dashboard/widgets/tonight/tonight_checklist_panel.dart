// "Ready for first light" — the fourth signature moment (02).
//
// This ONE list is where every setup problem in the app is represented (02
// rule 5). It replaces the tour prompts, the launch-time catalog dialog and the
// four separate nags the audit found; nothing else on Tonight may restate a
// step that appears here.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../imaging/imaging_screen.dart'
    show annotationCatalogInstalledProvider;

/// One step of the first-light checklist, before it is turned into a
/// [ChecklistStep] (which has no idea where its action goes).
class _Step {
  const _Step({
    required this.title,
    required this.detail,
    required this.done,
    this.route,
    this.actionLabel,
  });

  final String title;
  final String detail;
  final bool done;
  final String? route;
  final String? actionLabel;
}

/// The five steps between a fresh install and first light.
class TonightChecklistPanel extends ConsumerWidget {
  const TonightChecklistPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final report = ref.watch(readinessReportProvider);
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final site = ref.watch(appObserverLocationProvider);
    // A still-loading catalog check is NOT evidence the catalogs are there;
    // the step stays open until the manager says otherwise.
    final catalogs =
        ref.watch(annotationCatalogInstalledProvider).valueOrNull ?? false;

    ReadinessItem? item(ReadinessItemId id) => report.itemFor(id);
    bool ready(ReadinessItemId id) => item(id)?.level == ReadinessLevel.ready;

    final locationItem = item(ReadinessItemId.location);
    final outputItem = item(ReadinessItemId.outputPath);
    final devicesItem = item(ReadinessItemId.criticalDevices);
    final solverItem = item(ReadinessItemId.plateSolver);

    final locationDone = ready(ReadinessItemId.location);
    final outputDone = ready(ReadinessItemId.outputPath);
    final devicesDone = ready(ReadinessItemId.criticalDevices);
    final solverDone = ready(ReadinessItemId.plateSolver);

    final steps = <_Step>[
      _Step(
        title: l10n.text('tnStepSite'),
        detail: locationDone && site != null
            ? _siteDetail(site)
            : locationItem?.detail ?? l10n.text('tnStepSiteDetail'),
        done: locationDone,
        route: '/settings?section=location',
        actionLabel: l10n.text('tnStepSiteAction'),
      ),
      _Step(
        title: l10n.text('tnStepFolder'),
        detail: outputDone && settings != null
            ? settings.imageOutputPath
            : outputItem?.detail ?? l10n.text('tnStepFolderDetail'),
        done: outputDone,
        route: '/settings?section=files-storage',
        actionLabel: l10n.text('tnStepFolderAction'),
      ),
      _Step(
        title: l10n.text('tnStepDevices'),
        detail: devicesDone
            ? devicesItem?.detail ?? l10n.text('tnStepDevicesDetail')
            : l10n.text('tnStepDevicesDetail'),
        done: devicesDone,
        route: '/equipment',
        actionLabel: l10n.text('tnStepDevicesAction'),
      ),
      _Step(
        title: l10n.text('tnStepCatalogs'),
        detail: l10n.text('tnStepCatalogsDetail'),
        done: catalogs,
        route: '/settings?section=catalogs',
        actionLabel: l10n.text('tnStepCatalogsAction'),
      ),
      _Step(
        title: l10n.text('tnStepSolver'),
        detail: solverDone
            ? solverItem?.detail ?? l10n.text('tnStepSolverDetail')
            : l10n.text('tnStepSolverDetail'),
        done: solverDone,
        route: '/settings/plate-solving',
        actionLabel: l10n.text('tnStepSolverAction'),
      ),
    ];

    final doneCount = steps.where((step) => step.done).length;
    // Exactly one step is "next": the first one still open. Highlighting every
    // open step would make the list a wall of equal demands again.
    final nextIndex = steps.indexWhere((step) => !step.done);

    return SkotiqPanel(
      head: PanelHead(
        icon: LucideIcons.listChecks,
        label: l10n.text('tnChecklistTitle'),
        trailing: <Widget>[
          Text(
            l10n.text(
              'tnChecklistProgress',
              params: {'done': '$doneCount', 'total': '${steps.length}'},
            ),
            style: SkotiqTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
        ],
      ),
      child: Checklist(
        steps: <ChecklistStep>[
          for (var i = 0; i < steps.length; i++)
            ChecklistStep(
              title: steps[i].title,
              detail: steps[i].detail,
              state: steps[i].done
                  ? ChecklistStepState.done
                  : (i == nextIndex
                      ? ChecklistStepState.next
                      : ChecklistStepState.todo),
              action: steps[i].done || steps[i].route == null
                  ? null
                  : SkotiqButton(
                      label: steps[i].actionLabel ?? '',
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      onPressed: () => context.go(steps[i].route!),
                    ),
            ),
        ],
      ),
    );
  }

  /// `42.36° N, 71.06° W · 40 m`.
  static String _siteDetail(LocationSettings site) {
    final lat = site.latitude;
    final lon = site.longitude;
    return '${lat.abs().toStringAsFixed(2)}° ${lat >= 0 ? 'N' : 'S'}, '
        '${lon.abs().toStringAsFixed(2)}° ${lon >= 0 ? 'E' : 'W'} · '
        '${site.elevation.round()} m';
  }
}

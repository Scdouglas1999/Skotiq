// Tonight (`/dashboard`): the night-control screen.
//
// Composes the four slots of [NightControlLayout] and keeps the PHD2
// controller's event subscription alive while it is on screen, a provider
// whose work runs only while something watches it. The end-of-night request to
// cap the telescope, the run's two alerts (the recovery offer and a
// critical fault) and its warnings sit above the layout; each hides itself
// when there is nothing to say.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';

import 'critical_event_banner.dart';
import '../../widgets/run_status/recovery_banner.dart';
import 'center/night_center.dart';
import 'end_of_night_cap_banner.dart';
import 'header/night_header_bar.dart';
import 'left/night_left_column.dart';
import 'night_control_layout.dart';
import 'night_control_shortcuts.dart';
import 'panel/guide/night_guide_tab.dart';
import 'panel/mount/night_mount_tab.dart';
import 'panel/night_right_panel.dart';
import 'panel/solve/night_solve_tab.dart';
import '../../services/night_session/night_recent_solves.dart';
import 'center/frame_stage.dart' show nightIsBeforeRun;
import 'data/plan/night_run_phase_provider.dart';
import 'run_warnings_banner.dart';
import 'package:skotiq_app/widgets/mount_guard/mount_guard_banner.dart';

class NightControlScreen extends ConsumerWidget {
  const NightControlScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The PHD2 controller listens to the guider's events only while watched.
    ref.watch(phd2ControllerProvider);
    // Snapshot and Loop on the Camera tab use the manual exposure settings,
    // which follow the active profile only while this sync is watched.
    ref.watch(syncExposureFromProfileProvider);
    // A run's solves are gathered while Tonight is up, whichever tab shows.
    ref.watch(nightRecentSolvesProvider);

    // Before a run the phone leads with the plan and readiness; once frames
    // come in, with the frame.
    final planFirst = nightIsBeforeRun(ref.watch(nightRunPhaseProvider));

    return NightControlShortcuts(
      child: NightControlLayout(
        planFirst: planFirst,
        notices: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MountGuardBanner(),
            EndOfNightCapBanner(),
            RunDashboardRecoveryBanner(),
            RunDashboardCriticalBanner(),
            NightRunWarningsBanner(),
          ],
        ),
        header: const NightHeaderBar(),
        left: const NightLeftColumn(),
        center: const NightCenter(),
        panel: const NightRightPanel(
          mountTab: NightMountTab(),
          guideTab: NightGuideTab(),
          solveTab: NightSolveTab(),
        ),
      ),
    );
  }
}

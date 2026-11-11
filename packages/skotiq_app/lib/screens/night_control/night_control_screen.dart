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
import 'package:skotiq_core/skotiq_core.dart';

import '../sequencer/widgets/run_dashboard/critical_event_banner.dart';
import '../sequencer/widgets/run_dashboard/recovery_banner.dart';
import 'center/night_center.dart';
import 'end_of_night_cap_banner.dart';
import 'header/night_header_bar.dart';
import 'left/night_left_column.dart';
import 'night_control_layout.dart';
import 'panel/guide/night_guide_tab.dart';
import 'panel/mount/night_mount_tab.dart';
import 'panel/night_right_panel.dart';
import 'panel/solve/night_solve_tab.dart';
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

    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MountGuardBanner(),
        EndOfNightCapBanner(),
        RunDashboardRecoveryBanner(),
        RunDashboardCriticalBanner(),
        NightRunWarningsBanner(),
        Expanded(
          child: NightControlLayout(
            header: NightHeaderBar(),
            left: NightLeftColumn(),
            center: NightCenter(),
            panel: NightRightPanel(
              mountTab: NightMountTab(),
              guideTab: NightGuideTab(),
              solveTab: NightSolveTab(),
            ),
          ),
        ),
      ],
    );
  }
}

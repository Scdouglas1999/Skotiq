// Tonight (`/dashboard`): the night-control screen.
//
// Composes the four slots of [NightControlLayout] and keeps the side effects
// the old dashboard kept alive while it was on screen: the PHD2 controller's
// event subscription and the critical-events bridge, both providers whose
// work runs only while something watches them. The run's two alerts (the
// recovery offer and a critical fault) sit above the layout; each hides
// itself when there is nothing to say.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../sequencer/widgets/run_dashboard/critical_event_banner.dart';
import '../sequencer/widgets/run_dashboard/recovery_banner.dart';
import '../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'center/night_center.dart';
import 'header/night_header_bar.dart';
import 'left/night_left_column.dart';
import 'night_control_layout.dart';
import 'panel/guide/night_guide_tab.dart';
import 'panel/mount/night_mount_tab.dart';
import 'panel/night_right_panel.dart';
import 'panel/solve/night_solve_tab.dart';

/// The route Tonight is served on. The path predates the screen and stays
/// for deep links, notification routes and the tutorial.
const String kTonightRoutePath = '/dashboard';

/// Whether [location] shows Tonight. The shell hides its running-sequence
/// bar and its autofocus overlay there: the header carries the run controls
/// and the Focus tab and the frame carry the autofocus.
bool isTonightLocation(String location) =>
    location.split('?').first == kTonightRoutePath;

class NightControlScreen extends ConsumerWidget {
  const NightControlScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The PHD2 controller listens to the guider's events only while watched.
    ref.watch(phd2ControllerProvider);
    // Critical run events become toasts, sounds and phone pushes only while
    // this bridge is watched.
    ref.watch(runDashboardCriticalEventsBridgeProvider);
    // Snapshot and Loop on the Camera tab use the manual exposure settings,
    // which follow the active profile only while this sync is watched.
    ref.watch(syncExposureFromProfileProvider);

    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        RunDashboardRecoveryBanner(),
        RunDashboardCriticalBanner(),
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

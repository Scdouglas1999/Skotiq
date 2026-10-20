@Tags(['golden'])
library;

// Review captures of Tonight, the night-control screen, at the owner's
// 1536 x 864 window inside the real shell with the rail open, for
// comparison against docs/design/night-control-boards. Not a pixel-diff
// guard: the assertions only confirm a real, non-empty image was produced.
//
// Written to docs/design/goldens/ only under SKOTIQ_CAPTURE_ASSETS=1, a temp
// directory otherwise:
//   * night-control-ready.png   — TonightReady: plan loaded, before dark
//   * night-control-running.png — Tonight: the run on step 7, Overview tab
//   * night-control-focus.png   — TonightFocus: a manual autofocus, Focus tab
//   * night-control-camera.png  — the running night, Camera tab
//   * night-control-mount.png   — the running night, Mount tab
//   * night-control-guide.png   — the running night, Guide tab
//   * night-control-solve.png   — the running night, Solve tab

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';

import '../screens/night_control/night_screen_test_support.dart';
import 'surface_golden_harness.dart';

void main() {
  setUpAll(SurfaceGoldenHarness.ensureCaptureFonts);

  const captures = <(String, NightScreenState, NightPanelTab)>[
    ('ready', NightScreenState.ready, NightPanelTab.overview),
    ('running', NightScreenState.running, NightPanelTab.overview),
    ('focus', NightScreenState.focus, NightPanelTab.focus),
    ('camera', NightScreenState.running, NightPanelTab.camera),
    ('mount', NightScreenState.running, NightPanelTab.mount),
    ('guide', NightScreenState.running, NightPanelTab.guide),
    ('solve', NightScreenState.running, NightPanelTab.solve),
  ];

  for (final (name, state, tab) in captures) {
    testWidgets('night-control-$name.png', (tester) async {
      final boundary = GlobalKey();
      await pumpNightShell(
        tester,
        overrides: nightScreenOverrides(state, tab: tab),
        railCollapsed: false,
        boundaryKey: boundary,
      );
      expect(tester.takeException(), isNull);
      final file = await SurfaceGoldenHarness.captureBoundary(
        tester,
        boundary,
        fileName: 'night-control-$name.png',
        pixelRatio: 1.0,
      );
      expect(file.lengthSync(), greaterThan(10 * 1024));
      await unmountNightShell(tester);
    });
  }
}

// The home button's tooltip must describe where home actually is.
//
// The reset action centres on the observer's ZENITH, because RA 0h / Dec 0 can
// sit below the horizon and "reset view" would then point the map at the ground.
// A tooltip promising "center 0,0" contradicts it: pressing the reset hotkey
// moves the centre to the zenith — RA 10h34m45s / Dec +40 00' at LST 10:34 —
// not to 0,0.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/redesign/command_bar.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  testWidgets('the home button does not promise RA 0h / Dec 0', (tester) async {
    await pumpAppScreen(
      tester,
      PlanetariumCommandBar(
        compact: false,
        layersOpen: false,
        panelOpen: false,
        showFov: false,
        onToggleLayers: () {},
        onTogglePanel: () {},
        onOpenSearch: () {},
        onToggleFov: () {},
        onResetView: () {},
        onExportChart: () {},
      ),
      size: const Size(1400, 200),
      settle: false,
    );
    await tester.pump();

    final tooltips = tester
        .widgetList<SkotiqTooltip>(find.byType(SkotiqTooltip))
        .map((t) => t.message)
        .toList();

    expect(tooltips, contains('Reset view (zenith, FOV 60)'));
    expect(
      tooltips.where((m) => m.contains('0,0')),
      isEmpty,
      reason: 'reset centres on the zenith, from skyViewHomeCenterProvider',
    );
  });

  test('the reset home really is the zenith, not RA 0h / Dec 0', () {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40.0, longitude: -105.0);

    final home = container.read(skyViewHomeCenterProvider);
    expect(home, isNotNull, reason: 'a site is set, so the zenith is defined');
    expect(home!.$2, closeTo(40.0, 0.001));
  });
}

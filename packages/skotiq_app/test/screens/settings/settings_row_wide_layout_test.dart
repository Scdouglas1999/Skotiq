// Geometry tests for SettingRow / SettingsPage on wide desktop windows.
//
// Audit 2026-07-29: on a 5120x1440 window every settings control sat at the
// row's horizontal MIDPOINT with ~2100px of empty panel to its right, because
// `Expanded(title) + Flexible(trailing)` splits the free space 50/50 and the
// trailing control was left-aligned inside its half. At ~1600px it lands near
// the right edge by coincidence, which is why the defect only showed on wide
// monitors.
//
// These tests measure real render-object rects rather than comparing pixels, so
// they hold on any host and do not touch the golden baselines.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const _controlKey = ValueKey('probe-control');

/// A settings leaf built exactly the way every compliant leaf is built.
class _ProbeLeaf extends StatelessWidget {
  const _ProbeLeaf();

  @override
  Widget build(BuildContext context) {
    return const SettingsPage(
      title: 'Probe',
      description: 'Layout probe',
      children: [
        SettingsSection(
          title: 'Probe section',
          children: [
            SettingRow(
              icon: Icons.settings,
              title: 'Probe row',
              subtitle: 'A short label',
              trailing: SizedBox(
                key: _controlKey,
                width: 44,
                height: 24,
                child: ColoredBox(color: Color(0xFF00FF00)),
              ),
              isLast: true,
            ),
          ],
        ),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Row padding plus a little slack. Anything larger means the control is
  /// floating in dead space instead of hugging the panel edge.
  const edgeSlack = 32.0;

  testWidgets('trailing control hugs the panel edge, not the flex midpoint',
      (tester) async {
    await pumpAppScreen(
      tester,
      const _ProbeLeaf(),
      size: const Size(1600, 900),
    );

    final card = tester.getRect(find.byType(SkotiqPanel).first);
    final control = tester.getRect(find.byKey(_controlKey));

    expect(
      card.right - control.right,
      lessThan(edgeSlack),
      reason: 'control must sit at the panel edge, not mid-row',
    );
  });

  testWidgets('an ultrawide window does not strand controls mid-screen',
      (tester) async {
    await pumpAppScreen(
      tester,
      const _ProbeLeaf(),
      size: const Size(5120, 1440),
    );

    final card = tester.getRect(find.byType(SkotiqPanel).first);
    final control = tester.getRect(find.byKey(_controlKey));

    // Content width is capped, so the panel cannot span the whole window...
    expect(card.width, lessThanOrEqualTo(settingsContentMaxWidth));
    // ...and the control still hugs the panel's right edge inside it.
    expect(card.right - control.right, lessThan(edgeSlack));
    // A control that begins near the row's midpoint sits thousands of pixels
    // short of the right edge.
    expect(control.left, greaterThan(card.center.dx));
  });
}

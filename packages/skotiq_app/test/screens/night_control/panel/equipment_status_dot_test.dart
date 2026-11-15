// Each equipment line on Tonight's Overview leads with a dot in its status's
// color: a device whose heartbeat or readings went stale is attention
// (amber), a fault red, a working device green, an empty slot muted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/overview_sections.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'panel_test_support.dart';

void main() {
  testWidgets('each line\'s dot is its status\'s color', (tester) async {
    await pumpPanel(
      tester,
      overrides: const [],
      child: const NightEquipmentSection(
        rows: <EquipmentRowVm>[
          EquipmentRowVm(
            kind: EquipmentKind.camera,
            status: EquipmentStatus.ok,
            deviceName: 'ZWO ASI2600MM Pro',
          ),
          EquipmentRowVm(
            kind: EquipmentKind.mount,
            status: EquipmentStatus.attention,
            deviceName: 'NYX-101',
          ),
          EquipmentRowVm(
            kind: EquipmentKind.focuser,
            status: EquipmentStatus.fault,
            deviceName: 'ZWO EAF',
          ),
          EquipmentRowVm(
            kind: EquipmentKind.rotator,
            status: EquipmentStatus.absent,
          ),
        ],
      ),
    );

    final colors = SkotiqColors.of(
      tester.element(find.byType(NightEquipmentSection)),
    );
    final dots = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.shape == BoxShape.circle)
        .map((d) => d.color)
        .toList();
    expect(dots, <Color>[
      colors.success,
      colors.warning,
      colors.error,
      colors.textMuted,
    ]);
  });
}

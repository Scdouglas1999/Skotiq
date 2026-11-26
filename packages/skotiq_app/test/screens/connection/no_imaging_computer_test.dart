// The "No imaging computer linked" state links through the app's own connect
// flow. On the phone that is the connection screen; the desktop dialog pairs
// and then asks for a restart that a phone cannot do.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/connection/no_imaging_computer.dart';
import 'package:skotiq_app/screens/connection/rig_connect_entry.dart';

import '../../harness/pump_app_screen.dart';

void main() {
  testWidgets('Link to a computer opens the app connect entry', (tester) async {
    var opened = 0;
    await pumpAppScreen(
      tester,
      const NoImagingComputerState(),
      size: const Size(400, 800),
      extraOverrides: [
        openRigConnectProvider.overrideWith((ref) => (_) => opened++),
      ],
    );
    expect(find.text('No imaging computer linked'), findsOneWidget);
    await tester.tap(find.text('Link to a computer'));
    await tester.pump();
    expect(opened, 1);
  });
}

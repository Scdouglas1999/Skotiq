// The Equipment Settings body must not repeat its own host's title.
//
// Live finding: the gear at the top right of the Equipment screen opened a
// dialog whose title bar read "Equipment Settings" and whose first line of
// content read "Equipment Settings" again — inside a fixed 500 px dialog whose
// two-column content already had to scroll.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/tabs/settings_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the settings body renders no title of its own', (tester) async {
    final backend = mockBackend();
    when(backend.builtinGuiderGetConfig)
        .thenAnswer((_) async => BuiltinGuiderConfig.defaults);

    await pumpAppScreen(
      tester,
      // Stand in for the dialog / AppBar chrome the real hosts provide.
      const Column(
        children: [
          Text('Equipment settings'),
          Expanded(child: EquipmentSettingsTab()),
        ],
      ),
      backend: backend,
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    // Exactly one: the host's. The body contributes none.
    expect(find.text('Equipment settings'), findsOneWidget);
    // The sections themselves are untouched.
    expect(find.text('Camera Settings'), findsOneWidget);
  });
}

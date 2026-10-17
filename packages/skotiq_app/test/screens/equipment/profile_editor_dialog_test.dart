import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('new profile editor exposes its complete single-page form',
      (tester) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: ProfileEditorDialog(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('New profile'), findsOneWidget);
    expect(find.text('Profile identity'), findsOneWidget);
    expect(find.text('Optical train'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Camera defaults'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
  });
}

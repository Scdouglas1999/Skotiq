import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/main.dart';

void main() {
  testWidgets('relay dialog scrolls without overflowing compact landscape', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(932, 430);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const RelayConnectDialog(
                  initialRelayUrl: '',
                  initialApplianceId: '',
                  initialAllowInsecure: false,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Trust self-signed relay TLS'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });

  testWidgets('focused relay fields stay visible above a landscape keyboard', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(932, 430);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const RelayConnectDialog(
                  initialRelayUrl: '',
                  initialApplianceId: '',
                  initialAllowInsecure: false,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final relayUrl = find.widgetWithText(TextField, 'Relay URL');
    final applianceId = find.widgetWithText(TextField, 'Appliance id');
    await tester.tap(relayUrl);
    await tester.pump();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: relayUrl, matching: find.byType(EditableText)),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 230);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(relayUrl.hitTestable(), findsOneWidget);
    expect(applianceId.hitTestable(), findsOneWidget);
    final editable = tester.widget<EditableText>(
      find.descendant(of: relayUrl, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });
}

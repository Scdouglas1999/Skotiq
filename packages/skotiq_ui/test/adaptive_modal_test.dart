import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host({
  PhoneModalMode phoneMode = PhoneModalMode.bottomSheet,
  required void Function(BuildContext) onPressed,
}) {
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => onPressed(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpAt(WidgetTester tester, Size size, Widget child) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(child);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('phone shows a bottom sheet (390x844)', (tester) async {
    await _pumpAt(
      tester,
      const Size(390, 844),
      _host(
        onPressed: (context) => showAdaptiveModal<void>(
          context: context,
          builder: (_) => const SizedBox(
            height: 200,
            child: Center(child: Text('MODAL BODY')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('MODAL BODY'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone full-screen mode pushes a route (360x640)', (
    tester,
  ) async {
    await _pumpAt(
      tester,
      const Size(360, 640),
      _host(
        phoneMode: PhoneModalMode.fullScreen,
        onPressed: (context) => showAdaptiveModal<void>(
          context: context,
          phoneMode: PhoneModalMode.fullScreen,
          builder: (_) =>
              const Scaffold(body: Center(child: Text('FULLSCREEN BODY'))),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('FULLSCREEN BODY'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet/desktop shows a centered dialog (1200x800)', (
    tester,
  ) async {
    await _pumpAt(
      tester,
      const Size(1200, 800),
      _host(
        onPressed: (context) => showAdaptiveModal<void>(
          context: context,
          designWidth: 600,
          designHeight: 400,
          builder: (_) => const Center(child: Text('DIALOG BODY')),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('DIALOG BODY'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

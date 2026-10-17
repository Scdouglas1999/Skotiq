import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/search_header.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<TextEditingController> pumpHeader(WidgetTester tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => SearchHeader(
                colors: SkotiqColors.of(context),
                controller: controller,
                onSearch: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  testWidgets('coordinate search preserves a negative-zero declination',
      (tester) async {
    await pumpHeader(tester);

    await tester.enterText(
      find.byType(TextField).first,
      "RA 5h 35m, Dec -0d 30'",
    );
    await tester.pump();

    expect(find.text('Coordinates'), findsOneWidget);
    await tester.tap(find.text('Go to coordinates'));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SearchHeader)),
    );
    final request = container.read(flyToRequestProvider);
    expect(request, isNotNull);
    expect(request!.target.ra, closeTo(5 + 35 / 60, 1e-9));
    expect(request.target.dec, -0.5);
  });

  testWidgets('impossible coordinate components do not become a sky target',
      (tester) async {
    await pumpHeader(tester);

    await tester.enterText(
      find.byType(TextField).first,
      "RA 12h 99m, Dec +91d 00'",
    );
    await tester.pump();

    expect(find.text('Coordinates'), findsNothing);
    expect(find.text('Go to coordinates'), findsNothing);
  });
}

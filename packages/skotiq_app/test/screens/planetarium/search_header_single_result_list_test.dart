// The planetarium search must not draw two result lists at once.
//
// `SearchHeader` opens its own typeahead overlay while the plan panel it sits
// above renders the same results in its Search tab, so typing M31 gives a narrow
// floating panel ("74 results / Deep Sky Objects (25) / M31 / M41 / ...")
// painted on top of a wider list whose rows show through the right edge as
// clipped fragments and continue below it, with the front list's last visible
// row cut mid-row and the accessibility tree carrying both.
//
// The coordinate branch has no equivalent below it and must survive: it is the
// only way to fly to a typed RA/Dec.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/search_header.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _surface({required bool showResultSuggestions}) {
  final controller = TextEditingController();
  return ProviderScope(
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Builder(
        builder: (context) => Scaffold(
          body: SearchHeader(
            colors: SkotiqColors.of(context),
            controller: controller,
            showResultSuggestions: showResultSuggestions,
            onSearch: (_) {},
          ),
        ),
      ),
    ),
  );
}

/// Type into the header and wait out its 250 ms search debounce.
Future<void> _type(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).first, query);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  testWidgets('a header over a results panel opens no second list',
      (tester) async {
    await tester.pumpWidget(_surface(showResultSuggestions: false));
    await tester.pumpAndSettle();

    await _type(tester, 'M31');

    expect(
      find.text('No results found'),
      findsNothing,
      reason: 'the panel below is the one list; this overlay is the duplicate',
    );
  });

  testWidgets('a standalone header still suggests as you type', (tester) async {
    await tester.pumpWidget(_surface(showResultSuggestions: true));
    await tester.pumpAndSettle();

    await _type(tester, 'M31');

    // No catalogues are loaded in a widget test, so the overlay's own empty
    // state is the proof that it opened.
    expect(find.text('No results found'), findsOneWidget);
  });

  testWidgets('typed coordinates still offer a jump, panel or not',
      (tester) async {
    await tester.pumpWidget(_surface(showResultSuggestions: false));
    await tester.pumpAndSettle();

    await _type(tester, "RA 5h 35m, Dec -5 23");

    expect(find.text('Coordinates'), findsOneWidget);
  });
}

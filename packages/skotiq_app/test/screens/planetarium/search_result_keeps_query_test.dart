// Picking a search result must not silently re-run the search on the picked
// object's name.
//
// Type "6720" into the plan panel's search field: "175 results", "Deep Sky
// Objects (6)" = M57, NGC7107, IC728, NGC7112, IC5118, IC59. Clicking the M57
// row recentres the chart correctly; re-running the search turns the list
// underneath into M57, M7, M47, 57 Cygnus, 57 Gemini, ... — matches for "M57",
// not for "6720" — while the text field still reads "6720" and the result count
// and section headers vanish. Backing out of a wrong pick then lands the user in
// a list they never asked for.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/search_header.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

const _m57 = DeepSkyObject(
  id: 'NGC6720',
  name: 'M57',
  coordinates: CelestialCoordinate(ra: 18.8931, dec: 33.0292),
  type: DsoType.planetaryNebula,
  magnitude: 8.8,
);

const _vega = Star(
  id: 'HIP91262',
  name: 'Vega',
  coordinates: CelestialCoordinate(ra: 18.61565, dec: 38.78369),
  magnitude: 0.03,
);

/// Records every re-query so the test can prove the pick did not fire one.
class _SpySearchNotifier extends ObjectSearchNotifier {
  _SpySearchNotifier(super.ref, ObjectSearchState seed) {
    state = seed;
  }

  final queries = <String>[];

  @override
  Future<void> search(String query) async {
    queries.add(query);
  }
}

void main() {
  late TextEditingController controller;
  late _SpySearchNotifier spy;
  late List<String> onSearchCalls;

  Future<void> pumpHeader(WidgetTester tester) async {
    controller = TextEditingController(text: '6720');
    onSearchCalls = <String>[];
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SearchHeader(
          colors: SkotiqColors.of(context),
          controller: controller,
          onSearch: onSearchCalls.add,
        ),
      ),
      size: const Size(900, 700),
      extraOverrides: [
        objectSearchProvider.overrideWith((ref) {
          spy = _SpySearchNotifier(
            ref,
            const ObjectSearchState(
              query: '6720',
              results: [_m57, _vega],
            ),
          );
          return spy;
        }),
      ],
      settle: false,
    );
    await tester.pump();
    // Focus opens the results overlay.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('tapping a DSO result leaves the typed query and its list alone',
      (tester) async {
    await pumpHeader(tester);
    expect(find.text('M57'), findsWidgets);

    // Ignore the debounced re-query the typed text itself schedules; what is
    // under test is what the PICK does.
    spy.queries.clear();
    onSearchCalls.clear();

    await tester.tap(find.text('M57').first);
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      spy.queries,
      isEmpty,
      reason: 'the pick re-ran the search on "M57" and replaced the results',
    );
    expect(onSearchCalls, isEmpty);
    expect(controller.text, '6720');
  });

  testWidgets('tapping a star result leaves the typed query alone',
      (tester) async {
    await pumpHeader(tester);
    expect(find.text('Vega'), findsWidgets);

    spy.queries.clear();
    onSearchCalls.clear();

    await tester.tap(find.text('Vega').first);
    await tester.pump(const Duration(milliseconds: 300));

    expect(spy.queries, isEmpty);
    expect(onSearchCalls, isEmpty);
    expect(controller.text, '6720');
  });

  testWidgets('submitting the field still runs a search', (tester) async {
    await pumpHeader(tester);
    onSearchCalls.clear();

    // The one path that SHOULD re-query: the user pressing enter.
    await tester.enterText(find.byType(TextField), 'M13');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 300));

    expect(onSearchCalls, contains('M13'));
  });
}

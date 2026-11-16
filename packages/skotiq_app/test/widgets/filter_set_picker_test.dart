import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/widgets/filter_set_picker.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'filter_set_picker_test_support.dart';

const _ownerWheel = ['L', 'R', 'G', 'B', 'Ha', 'SII', 'OIII', 'DARK'];
const _m1 = TargetSuggestion(
  targetId: 1,
  targetName: 'M1',
  catalogId: 'M1',
  raHours: 5.58,
  decDegrees: 22.01,
  objectType: 'Supernova Remnant',
  totalScore: 80,
  visibility: TargetVisibilityInfo(
    currentAltitude: 60,
    currentAzimuth: 90,
    airmass: 1.2,
    moonDistance: 90,
  ),
);

/// A picker with the set it shows held by the test, as each screen holds it.
class _Host extends StatefulWidget {
  const _Host({required this.choice, required this.onPicked});

  final SmartNightFilterChoice choice;
  final ValueChanged<FilterSet> onPicked;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late FilterSet _set = widget.choice.recommended;

  @override
  Widget build(BuildContext context) => FilterSetPicker(
        choice: widget.choice,
        value: _set,
        onChanged: (set) {
          setState(() => _set = set);
          widget.onPicked(set);
        },
      );
}

void main() {
  Future<(ProviderContainer, List<FilterSet>)> pump(
    WidgetTester tester, {
    FilterSetPreferences prefs = const FilterSetPreferences(),
  }) async {
    final picked = <FilterSet>[];
    final container = ProviderContainer(
      overrides: [
        filterSetPreferencesProvider.overrideWith(
          () => MemoryFilterSetPreferences(prefs),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: _Host(
                choice: chooseSmartNightFilters(
                  target: _m1,
                  availableFilters: _ownerWheel,
                ),
                onPicked: picked.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container, picked);
  }

  SkotiqDropdown dropdown(WidgetTester tester) => tester.widget<SkotiqDropdown>(
        find.byKey(const ValueKey('filter-set-picker')),
      );

  testWidgets('lists what the wheel can image and marks the recommendation', (
    tester,
  ) async {
    await pump(tester);
    final picker = dropdown(tester);
    expect(picker.value, 'narrowbandSho');
    expect(picker.itemLabels, [
      'LRGB',
      'RGB',
      'L',
      'LRGB + Ha',
      'SHO',
      'HOO',
      'Ha',
      'OIII',
      'SII',
      'Custom…',
    ]);
    expect(
      picker.itemDetails![picker.itemLabels!.indexOf('SHO')],
      'Recommended',
    );
    expect(
      find.text('Recommended: narrowband SHO, M1 is a supernova remnant.'),
      findsOneWidget,
    );
  });

  testWidgets('switching says it is the user\'s choice', (tester) async {
    final (_, picked) = await pump(tester);
    dropdown(tester).onChanged!('autoLrgb');
    await tester.pumpAndSettle();
    expect(picked.single.filters, ['L', 'R', 'G', 'B']);
    expect(
      find.text(
        'Your choice. Recommended: narrowband SHO, M1 is a supernova remnant.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'Custom… builds a set from ticked filters, saves it for the '
      'profile, picks it, and offers it again', (tester) async {
    final (container, picked) = await pump(tester);
    dropdown(tester).onChanged!('filter-set-builder');
    await tester.pumpAndSettle();
    expect(find.text('Custom filter set'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('filter-set-name')),
      'HaRGB',
    );
    for (final filter in ['B', 'Ha', 'R', 'G']) {
      await tester.tap(find.text(filter).last);
    }
    await tester.pumpAndSettle();
    // Equal shares once all four are ticked; Ha takes more.
    expect(find.text('25'), findsNWidgets(4));
    await tester.enterText(
      find.byKey(const ValueKey('filter-set-share-Ha')),
      '40',
    );
    await tester.pumpAndSettle();
    expect(find.text('DARK'), findsOneWidget);
    await tester.tap(find.text('Save set'));
    await tester.pumpAndSettle();

    expect(picked.single.label, 'HaRGB');
    // Wheel order, whatever order they were ticked in.
    expect(picked.single.filters, ['R', 'G', 'B', 'Ha']);
    final saved = container.read(filterSetPreferencesProvider).requireValue;
    expect(saved.custom.single.filters, ['R', 'G', 'B', 'Ha']);
    expect(saved.custom.single.shares, {
      'R': 25.0,
      'G': 25.0,
      'B': 25.0,
      'Ha': 40.0,
    });
    expect(picked.single.shares['Ha'], 40.0);
    final picker = dropdown(tester);
    expect(picker.value, 'custom:HaRGB');
    expect(picker.itemLabels, contains('HaRGB'));
    expect(
        picker.itemDetails![picker.itemLabels!.indexOf('HaRGB')], 'R G B Ha');
  });

  testWidgets('a saved set can be deleted from the builder', (tester) async {
    final (container, _) = await pump(
      tester,
      prefs: const FilterSetPreferences().save(
        const CustomFilterSet(name: 'HaRGB', filters: ['Ha', 'R', 'G', 'B']),
      ),
    );
    expect(dropdown(tester).itemLabels, contains('HaRGB'));
    dropdown(tester).onChanged!('filter-set-builder');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byIcon(LucideIcons.trash2));
    await tester.tap(find.byIcon(LucideIcons.trash2));
    await tester.pumpAndSettle();
    expect(
      container.read(filterSetPreferencesProvider).requireValue.custom,
      isEmpty,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(dropdown(tester).itemLabels, isNot(contains('HaRGB')));
  });
}

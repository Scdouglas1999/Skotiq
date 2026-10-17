import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/standby/tonight_targets_card.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _ConfiguredSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        latitude: 40,
        longitude: -75,
      );
}

ProviderContainer _container({required void Function() onSuggestionsRead}) {
  return ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      appSettingsProvider.overrideWith(_ConfiguredSettingsNotifier.new),
      tonightSuggestionsProvider.overrideWith((ref) {
        onSuggestionsRead();
        return Future<List<TargetSuggestion>>.error(
          StateError('catalog unavailable'),
        );
      }),
      planetarium.twilightTimesProvider.overrideWithValue(
        planetarium.TwilightTimes(
          astronomicalDusk: DateTime(2026, 7, 13, 21),
          astronomicalDawn: DateTime(2026, 7, 14, 5),
        ),
      ),
      planetarium.moonInfoProvider.overrideWithValue(
        const planetarium.MoonTimes(
          illumination: 20,
          phaseName: 'Waning Crescent',
        ),
      ),
      planetarium.observationTimeProvider.overrideWith(
        (ref) => planetarium.ObservationTimeNotifier()
          ..setTime(DateTime(2026, 7, 13, 20)),
      ),
    ],
  );
}

Widget _app(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('Tonight card shows plan failures and retries them',
      (tester) async {
    var reads = 0;
    final container = _container(onSuggestionsRead: () => reads++);

    await tester.pumpWidget(
      _app(container, const TonightCard(colors: SkotiqColors.dark)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Plan unavailable'), findsOneWidget);
    expect(find.text('Couldn’t generate tonight’s plan.'), findsOneWidget);
    expect(find.text('Planning...'), findsNothing);
    expect(reads, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(reads, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    // Drift finishes cancelling the disposed container's query streams in a
    // zero-duration Timer, and a bare pump() would not advance the fake clock
    // far enough to run it.
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('standby targets card does not blame location for fetch errors', (
    tester,
  ) async {
    var reads = 0;
    final container = _container(onSuggestionsRead: () => reads++);

    await tester.pumpWidget(
      _app(
        container,
        const TonightTargetsCard(colors: SkotiqColors.dark),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Couldn’t generate target recommendations'),
        findsOneWidget);
    expect(find.textContaining('Set your observing location'), findsNothing);
    expect(reads, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(reads, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    // Drift finishes cancelling the disposed container's query streams in a
    // zero-duration Timer, and a bare pump() would not advance the fake clock
    // far enough to run it.
    await tester.pump(const Duration(milliseconds: 1));
  });
}

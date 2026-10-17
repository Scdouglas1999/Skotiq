// The Tonight screen must name the cause it actually knows.
//
// With no observing location the suggestion pipeline returns an empty list
// before it looks at the sky, so the one-tap pick is null. The screen used to
// hedge — "The sky may be below your horizon or your location is not set.
// Check Settings, then refresh." — and offer only a Refresh button, which can
// never succeed while the site is unset. Every other surface (planner,
// weather, dashboard) names the missing location and offers a way to set it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/tonight/one_tap_tonight_controller.dart';
import 'package:skotiq_app/screens/tonight/tonight_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _UnsetLocationSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

class _ConfiguredLocationSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40, longitude: -75);
}

Future<void> _pumpNoPick(
  WidgetTester tester,
  AppSettingsNotifier Function() settings,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appSettingsProvider.overrideWith(settings)],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: TonightBodyView(
            colors: SkotiqColors.dark,
            state: const OneTapTonightState(),
            activeRun: null,
            targetAsync: const AsyncData<TargetSuggestion?>(null),
            onGo: () async {},
            onReset: () {},
            onRefreshPick: () {},
            morningSessionAsync: const AsyncData<int?>(null),
            onRefreshMorningReport: () {},
          ),
        ),
      ),
    ),
  );
  // Two pumps: the settings AsyncNotifier resolves on the microtask queue.
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('no pick with an unset location names the location',
      (tester) async {
    await _pumpNoPick(tester, _UnsetLocationSettings.new);

    expect(find.text('Location not configured'), findsOneWidget);
    expect(
        find.widgetWithText(SkotiqButton, 'Open settings'), findsOneWidget);
    // The hedge and the dead-end Refresh are both gone for this cause.
    expect(find.textContaining('may be below your horizon'), findsNothing);
    expect(find.widgetWithText(SkotiqButton, 'Refresh'), findsNothing);
  });

  testWidgets('no pick with a configured location keeps the sky explanation',
      (tester) async {
    await _pumpNoPick(tester, _ConfiguredLocationSettings.new);

    expect(find.text('Nothing imageable right now'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Refresh'), findsOneWidget);
    expect(find.text('Location not configured'), findsNothing);
  });
}

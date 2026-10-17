import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/tonight/one_tap_tonight_controller.dart';
import 'package:skotiq_app/screens/tonight/tonight_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The confirm card reads the observing site to tell "nothing is up" apart
/// from "no site configured", so the body needs a scope with settings in it.
class _ConfiguredSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40, longitude: -75);
}

Future<void> _pumpBody(
  WidgetTester tester,
  AsyncValue<int?> morningSessionAsync, {
  VoidCallback? onRetry,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appSettingsProvider.overrideWith(_ConfiguredSettings.new)],
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
            morningSessionAsync: morningSessionAsync,
            onRefreshMorningReport: onRetry ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('history loading is not mistaken for no morning report',
      (tester) async {
    await _pumpBody(tester, const AsyncLoading());

    expect(find.text('Loading morning report…'), findsOneWidget);
  });

  testWidgets('history failure is visible and retryable', (tester) async {
    var retries = 0;
    await _pumpBody(
      tester,
      AsyncError(StateError('session database unavailable'), StackTrace.empty),
      onRetry: () => retries++,
    );

    expect(find.text('Morning report unavailable'), findsOneWidget);
    expect(find.textContaining('session database unavailable'), findsOneWidget);
    await tester.tap(find.text('Retry report'));
    expect(retries, 1);
  });
}

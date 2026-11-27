// The phone's connection and first-run app lays out as the phone it runs on:
// the same layout facts as the shell, so a toast there sits where the shell
// would put it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/snackbar_helper.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_core/utils.dart' show DeviceTraits;
import 'package:skotiq_mobile/widgets/phone_standalone_app.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _Settings extends AppSettingsNotifier {
  _Settings([this.state0 = const AppSettingsState()]);

  final AppSettingsState state0;

  @override
  Future<AppSettingsState> build() async => state0;
}

void main() {
  setUp(() => DeviceTraits.debugOverride = DeviceTraits.phone);
  tearDown(() => DeviceTraits.debugOverride = null);

  Future<ShellLayout> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late ShellLayout layout;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWith(_Settings.new)],
        child: PhoneStandaloneApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                layout = ShellLayout.of(context);
                return TextButton(
                  onPressed: () => context.showWarningSnackBar('Saved'),
                  child: const Text('toast'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return layout;
  }

  testWidgets('a phone upright is a touch device on the bottom bar', (
    tester,
  ) async {
    final layout = await pumpAt(tester, const Size(390, 844));
    expect(layout.touchDevice, isTrue);
    expect(layout.drawsWindowFrame, isFalse);
    expect(layout.navigation, ShellNavKind.bottomBar);
  });

  testWidgets('a phone on its side is on the rail, and a toast sits where '
      'the shell puts it', (tester) async {
    final layout = await pumpAt(tester, const Size(844, 390));
    expect(layout.touchDevice, isTrue);
    expect(layout.navigation, ShellNavKind.phoneRail);

    await tester.tap(find.text('toast'));
    await tester.pumpAndSettle();
    final margin = tester
        .widget<SnackBar>(find.byType(SnackBar))
        .margin!
        .resolve(TextDirection.ltr);
    expect(margin.bottom, 10 + ShellChromeMetrics.statusBarHeight);
  });

  testWidgets('speaks the chosen language at the chosen font size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Locale locale;
    late TextScaler scaler;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _Settings(
              const AppSettingsState(language: 'es', fontSize: 'Large'),
            ),
          ),
        ],
        child: PhoneStandaloneApp(
          home: Builder(
            builder: (context) {
              locale = Localizations.localeOf(context);
              scaler = MediaQuery.textScalerOf(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(locale, const Locale('es'));
    expect(scaler, const TextScaler.linear(1.15));
  });
}

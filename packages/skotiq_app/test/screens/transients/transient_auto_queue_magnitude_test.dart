// The magnitude that decides whether an alert is auto-queued shipped with a
// default of 10.0 — brighter than almost every transient an amateur rig can
// reach — and no control anywhere in the app. It was settable over the headless
// API (`transient_handlers.dart`) and by `setAutoQueueMagnitude`, which had zero
// UI callers, so switching "Auto-queue bright transients" on gave the operator a
// feature that could never fire and no way to loosen it.
//
// Reproduced live 2026-08-09 on the release desktop build: Plan Tonight >
// Recommendation > Transient Alerts > gear, toggled auto-queue to [ON], and the
// dialog offered nothing but the hard-coded "brighter than mag 10" caption.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/suggestions/widgets/transient_alerts_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Dao extends Mock implements SettingsDao {}

class _Logger extends Mock implements LoggingService {}

class _Science extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => const ScienceSettings();
}

late TransientAlertSettingsNotifier _settings;

Future<void> _openSettingsDialog(
  WidgetTester tester, {
  required bool autoQueueBright,
  double autoQueueMagnitude = 10.0,
  double magnitudeThreshold = 15.0,
}) async {
  final dao = _Dao();
  when(() => dao.getSetting(any())).thenAnswer((_) async => null);
  // The notifier reloads from the DAO on construction and overwrites any state
  // seeded directly, so the fixture has to speak through storage.
  when(() => dao.getAllSettings()).thenAnswer((_) async => {
        'transient_alert_enabled_sources': '["manual"]',
        'transient_alert_magnitude_threshold': '$magnitudeThreshold',
        'transient_alert_auto_queue_bright': '$autoQueueBright',
        'transient_alert_auto_queue_magnitude': '$autoQueueMagnitude',
      });
  when(() => dao.setSetting(any(), any())).thenAnswer((_) async {});
  when(() => dao.setSettings(any())).thenAnswer((_) async {});
  final logger = _Logger();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        secretsStoreProvider
            .overrideWithValue(SecretsStore(InMemorySecureKeyValueStore())),
        isRemoteModeProvider.overrideWithValue(false),
        scienceSettingsProvider.overrideWith(_Science.new),
        transientAlertSettingsProvider.overrideWith((ref) {
          _settings = TransientAlertSettingsNotifier(
            settingsDao: dao,
            logger: logger,
          );
          return _settings;
        }),
        transientAlertStatesProvider.overrideWith(
          (ref) => TransientAlertStatesNotifier(
            settingsDao: dao,
            logger: logger,
          ),
        ),
        activeTransientAlertsProvider.overrideWith(
          (ref) => Stream.value(const <TransientAlert>[]),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: TransientAlertsPanel()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  await tester.tap(find.byTooltip('Alert settings'));
  await tester.pumpAndSettle();
}

Slider? _sliderWithValue(WidgetTester tester, double value) {
  final matches = tester
      .widgetList<Slider>(find.byType(Slider))
      .where((slider) => slider.value == value);
  return matches.isEmpty ? null : matches.first;
}

void main() {
  testWidgets('auto-queue magnitude has no control while auto-queue is off',
      (tester) async {
    await _openSettingsDialog(tester, autoQueueBright: false);

    // Only the display magnitude threshold is adjustable.
    expect(find.byType(Slider), findsOneWidget);
    expect(_sliderWithValue(tester, 15.0), isNotNull);
    expect(_sliderWithValue(tester, 10.0), isNull);
  });

  // With the switch OFF the row must not assert a number it gives no control
  // for. The adversarial half is what makes it a false claim rather than a
  // stale caption: drag the display Magnitude Threshold to 8.0 and a fixed
  // caption still says the app auto-queues at mag 10, two magnitudes FAINTER
  // than the objects it will show.
  testWidgets('with auto-queue off the row states no threshold at all',
      (tester) async {
    await _openSettingsDialog(
      tester,
      autoQueueBright: false,
      magnitudeThreshold: 8.0,
    );

    expect(
      find.textContaining('mag 10'),
      findsNothing,
      reason: 'a number with no control, contradicting the visible 8.0 filter',
    );
    expect(
      find.textContaining('Turn this on to set the cutoff.'),
      findsOneWidget,
    );
  });

  testWidgets('with auto-queue on the row states the threshold it acts on',
      (tester) async {
    await _openSettingsDialog(
      tester,
      autoQueueBright: true,
      autoQueueMagnitude: 12.5,
    );

    expect(find.textContaining('brighter than mag 12.5'), findsOneWidget);
    expect(find.text('<= 12.5'), findsOneWidget);
  });

  testWidgets('enabling auto-queue exposes its magnitude and applies edits',
      (tester) async {
    await _openSettingsDialog(tester, autoQueueBright: true);

    final slider = _sliderWithValue(tester, 10.0);
    expect(
      slider,
      isNotNull,
      reason: 'auto-queue is on, so its threshold must be adjustable',
    );
    expect(slider!.min, 5.0);
    expect(slider.max, 20.0);
    expect(find.text('<= 10.0'), findsOneWidget);

    slider.onChanged!(16.0);
    await tester.pumpAndSettle();

    expect(_settings.state.autoQueueMagnitude, 16.0);
    expect(find.text('<= 16.0'), findsOneWidget);
  });

  testWidgets('a threshold fainter than the feed filter is called out',
      (tester) async {
    await _openSettingsDialog(
      tester,
      autoQueueBright: true,
      autoQueueMagnitude: 18.0,
      magnitudeThreshold: 15.0,
    );

    expect(
      find.textContaining('filtered out before auto-queue sees them'),
      findsOneWidget,
    );
  });
}

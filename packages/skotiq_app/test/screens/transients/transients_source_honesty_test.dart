// Observing Alerts must not claim to be monitoring upstreams it never queries,
// and a refresh must leave evidence that it ran. Both were live defects: the
// settings sheet rendered AAVSO, MPEC and CBAT as enabled sources although the
// service has no working fetch path for any of them, and the screen was
// byte-identical before and after a refresh, so "no transients tonight" and
// "this feature is broken" looked the same.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/transients/transients_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

class _MockLogger extends Mock implements LoggingService {}

class _FixedScienceSettings extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => const ScienceSettings();
}

/// A rig whose TNS bot identity IS configured, so the only remaining gate on
/// the strip's per-source count is the API key in the secrets store.
class _KeyedScienceSettings extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async =>
      const ScienceSettings(tnsBotId: 42, tnsBotName: 'skotiq-bot');
}

Future<void> _pumpAlerts(
  WidgetTester tester, {
  required List<TransientSource> enabledSources,
  List<TransientAlert>? alerts,
  bool tnsConfigured = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1100, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final dao = _MockSettingsDao();
  when(dao.getAllSettings).thenAnswer(
    (_) async => <String, String>{
      'transient_alert_enabled_sources':
          '[${enabledSources.map((s) => '"${s.name}"').join(',')}]',
    },
  );
  when(() => dao.getSetting(any())).thenAnswer((_) async => null);
  when(() => dao.setSetting(any(), any())).thenAnswer((_) async {});

  final secrets = SecretsStore(InMemorySecureKeyValueStore());
  if (tnsConfigured) {
    await secrets.write(SecretField.tnsApiKey, 'test-key');
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsDaoProvider.overrideWithValue(dao),
        loggingServiceProvider.overrideWithValue(_MockLogger()),
        secretsStoreProvider.overrideWithValue(secrets),
        scienceSettingsProvider.overrideWith(
          tnsConfigured ? _KeyedScienceSettings.new : _FixedScienceSettings.new,
        ),
        activeTransientAlertsProvider.overrideWith(
          (ref) => alerts == null
              // Never completes: the "fetch is still in flight" state.
              ? const Stream<List<TransientAlert>>.empty()
              : Stream.value(alerts),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: TransientsView()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(() {
    registerFallbackValue('');
  });

  testWidgets(
    'AAVSO, MPEC and CBAT are never rendered as monitored sources',
    (tester) async {
      // Even a profile that has all three stored as enabled — the shipped
      // default until this fix — must not be told they are being watched.
      // AAVSO joins MPEC and CBAT here because VSX's api.list is a positional
      // catalog search: with no cone it returns an empty set every time, and
      // there is no query at that endpoint that selects recent alerts.
      await _pumpAlerts(
        tester,
        enabledSources: const [
          TransientSource.aavso,
          TransientSource.mpec,
          TransientSource.cbat,
          TransientSource.manual,
        ],
        alerts: const <TransientAlert>[],
      );

      await tester.tap(find.byTooltip('Alert settings'));
      await tester.pumpAndSettle();

      for (final label in const ['AAVSO', 'MPEC', 'CBAT']) {
        final chip = tester.widget<SkotiqChip>(
          find.widgetWithText(SkotiqChip, '$label — not available'),
        );
        expect(chip.selected, isFalse, reason: '$label must not read as ON');
        expect(chip.onTap, isNull, reason: '$label must not be togglable');
      }

      // The source that is real stays real.
      final tns = tester.widget<SkotiqChip>(
        find.widgetWithText(SkotiqChip, 'TNS'),
      );
      expect(tns.onTap, isNotNull);
    },
  );

  testWidgets(
    'a rig with only unavailable sources enabled is told none is being checked',
    (tester) async {
      // The state the shipped default produces. "AAVSO: 0 alerts, checked
      // 23:14" reports a dead feed as a quiet sky.
      await _pumpAlerts(
        tester,
        enabledSources: const [TransientSource.aavso],
        alerts: const <TransientAlert>[],
      );

      expect(find.textContaining('No alert source is enabled'), findsOneWidget);
      expect(find.textContaining('AAVSO: 0 alerts'), findsNothing);
    },
  );

  testWidgets('a completed check reports per-source counts and a timestamp',
      (tester) async {
    await _pumpAlerts(
      tester,
      enabledSources: const [TransientSource.tns],
      alerts: const <TransientAlert>[],
      tnsConfigured: true,
    );

    expect(find.textContaining('TNS: 0 alerts'), findsOneWidget);
    expect(find.textContaining('checked '), findsOneWidget);
    expect(find.textContaining('never checked'), findsNothing);
  });

  testWidgets('an enabled but unkeyed TNS says so instead of reporting zero',
      (tester) async {
    await _pumpAlerts(
      tester,
      enabledSources: const [TransientSource.tns],
      alerts: const <TransientAlert>[],
    );

    expect(find.textContaining('TNS: skipped — no API key'), findsOneWidget);
    expect(find.textContaining('TNS: 0 alerts'), findsNothing);
  });

  testWidgets('a fetch that has not returned yet says so', (tester) async {
    await _pumpAlerts(
      tester,
      enabledSources: const [TransientSource.tns],
      tnsConfigured: true,
    );

    expect(find.textContaining('never checked'), findsOneWidget);
  });
}

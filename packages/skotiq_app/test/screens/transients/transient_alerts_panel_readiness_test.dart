import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/suggestions/widgets/transient_alerts_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:mocktail/mocktail.dart';

class _Dao extends Mock implements SettingsDao {}

class _Logger extends Mock implements LoggingService {}

class _Science extends ScienceSettingsNotifier {
  _Science(this.configured);
  final bool configured;

  @override
  Future<ScienceSettings> build() async => ScienceSettings(
        tnsBotId: configured ? 42 : 0,
        tnsBotName: configured ? 'bot' : '',
      );
}

TransientAlert _alert() => TransientAlert(
      id: 'sn-2026abc',
      name: 'SN 2026abc',
      type: TransientType.supernova,
      raHours: 12,
      decDegrees: 20,
      magnitude: 14.2,
      discoveryTime: DateTime.utc(2026, 8, 1),
      lastUpdated: DateTime.utc(2026, 8, 2),
      source: TransientSource.tns,
    );

Future<void> _pump(
  WidgetTester tester, {
  required bool configured,
  bool remote = false,
  bool initiallyExpanded = false,
  Set<TransientSource> enabledSources = const {TransientSource.tns},
  Stream<List<TransientAlert>>? alerts,
  TransientFeedCheck? feedCheck,
}) async {
  final secrets = SecretsStore(InMemorySecureKeyValueStore());
  if (configured) await secrets.write(SecretField.tnsApiKey, 'key');
  final dao = _Dao();
  when(() => dao.getSetting(any())).thenAnswer((_) async => null);
  when(() => dao.getAllSettings()).thenAnswer(
    (_) async => enabledSources.contains(TransientSource.tns)
        ? const {}
        : {
            'transient_alert_enabled_sources': jsonEncode(
                enabledSources.map((source) => source.name).toList()),
          },
  );
  when(() => dao.setSetting(any(), any())).thenAnswer((_) async {});
  final logger = _Logger();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        secretsStoreProvider.overrideWithValue(secrets),
        isRemoteModeProvider.overrideWithValue(remote),
        scienceSettingsProvider.overrideWith(() => _Science(configured)),
        transientAlertSettingsProvider
            .overrideWith((ref) => TransientAlertSettingsNotifier(
                  settingsDao: dao,
                  logger: logger,
                )..state = TransientAlertSettings(
                    enabledSources: enabledSources,
                  )),
        transientAlertStatesProvider.overrideWith(
          (ref) => TransientAlertStatesNotifier(
            settingsDao: dao,
            logger: logger,
          ),
        ),
        if (feedCheck != null)
          transientFeedCheckProvider.overrideWith((ref) => feedCheck),
        activeTransientAlertsProvider.overrideWith(
          (ref) =>
              alerts ??
              Stream<List<TransientAlert>>.error(
                StateError('TNS request failed'),
              ),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: TransientAlertsPanel(initiallyExpanded: initiallyExpanded),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('missing credentials dominate a fetch error in compact state',
      (tester) async {
    await _pump(tester, configured: false);
    expect(find.text('Setup needed for live TNS alerts'), findsOneWidget);
    expect(find.textContaining('TNS request failed'), findsNothing);
    expect(find.byIcon(LucideIcons.alertTriangle), findsNothing);
  });

  testWidgets('configured fetch errors are sanitized and visibly red',
      (tester) async {
    await _pump(tester, configured: true);
    expect(find.textContaining('Fetch failed:'), findsOneWidget);
    expect(find.textContaining('Bad state:'), findsNothing);
    expect(find.textContaining('TNS request failed'), findsOneWidget);
  });

  testWidgets('configured success shows a truthful compact summary and details',
      (tester) async {
    await _pump(
      tester,
      configured: true,
      alerts: Stream.value([_alert()]),
    );
    expect(find.text('1 alert · SN 2026abc, mag 14.2'), findsOneWidget);
    expect(find.text('SN 2026abc'), findsNothing);

    await tester.tap(find.byTooltip('Expand alerts'));
    await tester.pump();
    expect(find.text('SN 2026abc'), findsOneWidget);
    expect(find.textContaining('No transient alerts'), findsNothing);
  });

  testWidgets('manual-only mode does not claim TNS setup', (tester) async {
    await _pump(
      tester,
      configured: false,
      enabledSources: {TransientSource.manual},
      alerts: Stream.value(const <TransientAlert>[]),
      feedCheck: TransientFeedCheck(
        checkedAt: DateTime.now(),
        queriedSources: const {},
      ),
    );
    expect(find.text('No alert source is being checked'), findsOneWidget);
    expect(find.textContaining('Setup needed'), findsNothing);

    await tester.tap(find.byTooltip('Expand alerts'));
    await tester.pump();
    expect(find.text('No alert source is being checked'), findsOneWidget);
    expect(find.textContaining('not configured'), findsNothing);
  });

  testWidgets('remote empty state does not require local credentials',
      (tester) async {
    await _pump(
      tester,
      configured: false,
      remote: true,
      alerts: Stream.value(const <TransientAlert>[]),
      feedCheck: TransientFeedCheck(
        checkedAt: DateTime.now(),
        queriedSources: const {TransientSource.tns},
      ),
    );
    expect(find.textContaining('No active alerts'), findsOneWidget);
    expect(find.textContaining('Setup needed'), findsNothing);
  });

  // "No active alerts" is indistinguishable from "we never asked" on the app's
  // only channel for time-critical events. Enabling AAVSO alone (no build
  // fetches it) produces exactly that confident empty state, with no
  // last-checked time and no way to check.
  group('the empty feed says whether anything was actually checked', () {
    testWidgets('before the first check it says so, and offers a check',
        (tester) async {
      await _pump(
        tester,
        configured: true,
        alerts: Stream.value(const <TransientAlert>[]),
      );

      expect(find.text('Not checked yet'), findsOneWidget);
      expect(find.text('No active alerts'), findsNothing);
      expect(
        find.byKey(const ValueKey('transient_check_now')),
        findsOneWidget,
      );
    });

    testWidgets('a source nothing polls is named, not silently empty',
        (tester) async {
      await _pump(
        tester,
        configured: false,
        enabledSources: {TransientSource.aavso},
        initiallyExpanded: true,
        alerts: Stream.value(const <TransientAlert>[]),
        feedCheck: TransientFeedCheck(
          checkedAt: DateTime.now(),
          queriedSources: const {},
          skippedSources: const {
            TransientSource.aavso: 'this build has no AAVSO feed',
          },
        ),
      );

      expect(find.text('No alert source is being checked'), findsOneWidget);
      expect(find.textContaining('AAVSO'), findsOneWidget);
    });

    testWidgets('a real check reports when it happened', (tester) async {
      await _pump(
        tester,
        configured: true,
        alerts: Stream.value(const <TransientAlert>[]),
        feedCheck: TransientFeedCheck(
          checkedAt: DateTime.now(),
          queriedSources: const {TransientSource.tns},
        ),
      );

      expect(find.text('No active alerts · checked just now'), findsOneWidget);
    });
  });

  // The eight "Types to Monitor" chips are a subscription list drawn with tick
  // marks, so assistive tech must not read them as plain buttons with no state
  // while the checkboxes in the same dialog report on/off correctly.
  testWidgets('monitored-type chips expose their on/off state', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      configured: true,
      alerts: Stream.value(const <TransientAlert>[]),
    );

    await tester.tap(find.byTooltip('Alert settings'));
    await tester.pumpAndSettle();

    final chip = find.descendant(
      of: find.byType(FilterChip),
      matching: find.text('Nova'),
    );
    expect(chip, findsOneWidget);
    final node = tester.getSemantics(chip);
    expect(node.hasFlag(SemanticsFlag.hasCheckedState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isChecked), isTrue);

    handle.dispose();
  });

  testWidgets('remote fetch failure remains a visible operational error',
      (tester) async {
    await _pump(
      tester,
      configured: false,
      remote: true,
      alerts: Stream<List<TransientAlert>>.error(
        StateError('remote transient service unavailable'),
      ),
    );
    expect(find.textContaining('Fetch failed:'), findsOneWidget);
    expect(find.textContaining('Bad state:'), findsNothing);
    expect(find.textContaining('remote transient service unavailable'),
        findsOneWidget);
  });
}

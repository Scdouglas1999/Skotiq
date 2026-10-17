// Widget tests for `TriggerConfigurationDialog` and `ExposureTriggerConfig`.
//
// These pin the three jank fixes documented in the trigger-config dialog:
//
//   Controller stability: the threshold/debounce text fields must not rebuild a fresh
//         `TextEditingController` on every frame. We test this indirectly by
//         confirming that the field's controller survives setState() cycles
//         and that pumping more characters than the initial value appends
//         (rather than replacing) — i.e. fast typing isn't dropped.
//
//   Drift RA/Dec round-trip: drift triggers store independent RA and Dec pixel thresholds and
//         round-trip both through `toNativeJson` / `fromNativeJson`. The
//         executor (`TriggerCondition::DriftAbove { ra_px, dec_px }` in
//         `native/skotiq_native/sequencer/src/lib.rs`) compares each
//         axis with its own threshold, so the Dart model must surface both.
//
//   Type-switch reset: changing condition type in the edit dialog must reset the
//         threshold to the new type's default, because the underlying
//         physical unit changes (arcsec / pixels / pixels-per-axis).
//
// The dialog is built on `SkotiqDialog`, which only needs a Material
// ancestor — no Riverpod harness required for these tests.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/trigger_configuration_dialog.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ExposureTriggerConfig round-trip.
  group('ExposureTriggerConfig — drift RA/Dec round-trip', () {
    test('drift triggers serialise RA and Dec independently', () {
      final cfg = ExposureTriggerConfig(
        condition: TriggerConditionType.drift,
        threshold: 0, // unused for drift
        driftRaPx: 2.5,
        driftDecPx: 4.0,
        action: TriggerActionType.pauseAndRecalibrate,
      );
      final json = cfg.toNativeJson();
      final drift = (json['condition'] as Map)['DriftAbove'] as Map;
      expect(drift['ra_px'], 2.5);
      expect(drift['dec_px'], 4.0);
    });

    test('asymmetric RA/Dec values round-trip without conflation', () {
      final original = ExposureTriggerConfig(
        condition: TriggerConditionType.drift,
        threshold: 0,
        driftRaPx: 2.5,
        driftDecPx: 4.0,
        action: TriggerActionType.autofocus,
      );
      final restored =
          ExposureTriggerConfig.fromNativeJson(original.toNativeJson());
      expect(restored.condition, TriggerConditionType.drift);
      expect(restored.driftRaPx, 2.5);
      expect(restored.driftDecPx, 4.0);
      expect(restored.action, TriggerActionType.autofocus);
    });

    test('fromNativeJson tolerates legacy payloads with only ra_px', () {
      // Older saved sequences may only contain ra_px; we must not blow up
      // and we must fall back to the documented default for the missing
      // axis. Errors-are-a-feature applies for *unknown* shapes, but a
      // missing axis is a documented backward-compat path.
      final restored = ExposureTriggerConfig.fromNativeJson({
        'condition': {
          'DriftAbove': {'ra_px': 5.0},
        },
        'action': 'PauseAndRecalibrate',
        'debounce_secs': 10.0,
      });
      expect(restored.driftRaPx, 5.0);
      // Dec falls back to the per-axis default (3.0 px).
      expect(restored.driftDecPx, 3.0);
    });

    test('guiding RMS and HFR still serialise as scalar thresholds', () {
      final guiding = ExposureTriggerConfig(
        condition: TriggerConditionType.guidingRms,
        threshold: 1.8,
        action: TriggerActionType.abort,
      );
      expect(
          (guiding.toNativeJson()['condition'] as Map)['GuidingRmsAbove'], 1.8);

      final hfr = ExposureTriggerConfig(
        condition: TriggerConditionType.hfr,
        threshold: 3.6,
        action: TriggerActionType.autofocus,
      );
      expect((hfr.toNativeJson()['condition'] as Map)['HfrAbove'], 3.6);
    });
  });

  // Switching condition type resets threshold to the new default.
  group('TriggerConfigurationDialog — type-switch resets threshold', () {
    Future<void> openEditForFirstTrigger(WidgetTester tester) async {
      // Open the edit dialog by tapping the edit icon on the first row.
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'switching from Guiding RMS to Drift resets threshold and shows hint',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [inMemoryDatabaseOverride()],
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (ctx) => ElevatedButton(
                    onPressed: () => showDialog(
                      context: ctx,
                      builder: (_) => TriggerConfigurationDialog(
                        initialTriggers: [
                          ExposureTriggerConfig(
                            condition: TriggerConditionType.guidingRms,
                            threshold: 1.5,
                            action: TriggerActionType.pauseAndRecalibrate,
                          ),
                        ],
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await openEditForFirstTrigger(tester);

        // Switch the condition dropdown from "Guiding RMS" to "Drift".
        final dropdown =
            find.byKey(const ValueKey('trigger_condition_dropdown'));
        expect(dropdown, findsOneWidget);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Drift').last);
        await tester.pumpAndSettle();

        // The single threshold field is replaced with two drift fields.
        expect(
          find.byKey(const ValueKey('trigger_drift_ra_field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('trigger_drift_dec_field')),
          findsOneWidget,
        );
        // The reset hint must be visible.
        expect(
          find.byKey(const ValueKey('trigger_threshold_reset_hint')),
          findsOneWidget,
        );

        // The RA / Dec defaults must be the documented drift defaults
        // (3.0 px each), NOT the previous 1.5 carried over from RMS.
        final raField = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(const ValueKey('trigger_drift_ra_field')),
            matching: find.byType(TextField),
          ),
        );
        expect(raField.controller!.text, '3.0');

        final decField = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(const ValueKey('trigger_drift_dec_field')),
            matching: find.byType(TextField),
          ),
        );
        expect(decField.controller!.text, '3.0');
      },
    );
  });

  // TextEditingController stability — typing must not drop chars.
  group('TriggerConfigurationDialog — controller stability', () {
    testWidgets(
      'the threshold field controller is reused across rebuilds; fast typing '
      'is not eaten',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [inMemoryDatabaseOverride()],
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (ctx) => ElevatedButton(
                    onPressed: () => showDialog(
                      context: ctx,
                      builder: (_) => TriggerConfigurationDialog(
                        initialTriggers: [
                          ExposureTriggerConfig(
                            condition: TriggerConditionType.guidingRms,
                            threshold: 2.0,
                            action: TriggerActionType.pauseAndRecalibrate,
                          ),
                        ],
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Edit'));
        await tester.pumpAndSettle();

        final fieldFinder = find.descendant(
          of: find.byKey(const ValueKey('trigger_threshold_field')),
          matching: find.byType(TextField),
        );
        expect(fieldFinder, findsOneWidget);

        // Capture the controller identity, then simulate a sequence of
        // edits and verify it's the same controller object after each
        // pump. If the widget were to rebuild a fresh controller on every
        // frame (the controller-stability bug), this assertion would fire.
        final initialController =
            tester.widget<TextField>(fieldFinder).controller;
        expect(initialController, isNotNull);

        // Simulate fast typing: enter a multi-character value. A fresh
        // controller per build makes the framework treat each keystroke as a
        // brand-new editing session and silently lose characters; a stable
        // controller's text reflects exactly what was typed.
        await tester.enterText(fieldFinder, '12.34');
        await tester.pump();
        expect(
          tester.widget<TextField>(fieldFinder).controller,
          same(initialController),
          reason: 'controller must persist across rebuilds — a fresh '
              'controller per build drops characters during fast typing.',
        );
        // While the field is still focused, the text must equal exactly
        // what we typed — no truncation, no last-character-wins.
        expect(initialController!.text, '12.34');

        // Pump another frame to give any rebuild a chance to swap
        // controllers; identity must still hold.
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.widget<TextField>(fieldFinder).controller,
          same(initialController),
          reason: 'Controller identity must survive normal frame pumps.',
        );
        expect(initialController.text, '12.34');
      },
    );
  });

  // Owner decision 2026-10-06: an image-quality judgment never stops a run by
  // itself. A trigger the operator adds tells them and keeps imaging until they
  // pick a stopping action.
  group('TriggerConfigurationDialog — new triggers notify', () {
    testWidgets('Add trigger gives a trigger that notifies and keeps imaging',
        (tester) async {
      List<ExposureTriggerConfig>? saved;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [inMemoryDatabaseOverride()],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () async {
                    saved = await showDialog<List<ExposureTriggerConfig>>(
                      context: ctx,
                      builder: (_) => const TriggerConfigurationDialog(),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add trigger'));
      await tester.pumpAndSettle();
      expect(find.text('→ Notify me and keep imaging'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saved, hasLength(1));
      expect(saved!.single.action, TriggerActionType.notify);
      expect(saved!.single.toNativeJson()['action'], 'Notify');
    });

    test('a stored action is kept, and Notify round-trips', () {
      ExposureTriggerConfig read(String action) =>
          ExposureTriggerConfig.fromNativeJson({
            'condition': {'HfrAbove': 4.0},
            'action': action,
            'debounce_secs': 10.0,
          });
      expect(read('Notify').action, TriggerActionType.notify);
      expect(
        read('PauseAndRecalibrate').action,
        TriggerActionType.pauseAndRecalibrate,
      );
      expect(read('Abort').action, TriggerActionType.abort);
      expect(read('Autofocus').action, TriggerActionType.autofocus);
    });
  });
}

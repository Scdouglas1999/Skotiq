// Widget tests for the Session Review integration-settings panel.
//
// The panel is a pure controlled widget (no providers): it renders the
// smart-default preset chips + a live readout, exposes an Advanced expander,
// and reports every edit through `onChanged` without mutating its own state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/widgets/integration_settings_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _harness({required Widget child}) {
  return MaterialApp(
    theme: ThemeData(extensions: const [SkotiqColors.dark]),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders preset chips and the live sub-count readout',
      (tester) async {
    await tester.pumpWidget(_harness(
      child: IntegrationSettingsPanel(
        settings: IntegrationSettings.defaults,
        subCount: 30,
        onChanged: (_) {},
      ),
    ));
    await tester.pump();

    // All five presets are offered.
    for (final preset in IntegrationPreset.values) {
      expect(find.text(preset.label), findsOneWidget);
    }
    // 30 subs resolves the auto rule to linear-fit and shows it in the readout.
    expect(find.textContaining('30 accepted subs'), findsOneWidget);
    expect(find.textContaining('Linear fit'), findsOneWidget);
  });

  testWidgets('tapping a preset reports the materialised settings',
      (tester) async {
    IntegrationSettings? reported;
    await tester.pumpWidget(_harness(
      child: IntegrationSettingsPanel(
        settings: IntegrationSettings.defaults,
        subCount: 5,
        onChanged: (s) => reported = s,
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Maximum Quality'));
    await tester.pump();

    expect(reported, isNotNull);
    expect(reported!.sourcePreset, IntegrationPreset.maximumQuality);
    expect(reported!.resampler, Resampler.lanczos3);
  });

  testWidgets('few subs (<8) resolves auto rejection to percentile clip',
      (tester) async {
    await tester.pumpWidget(_harness(
      child: IntegrationSettingsPanel(
        settings: IntegrationSettings.defaults,
        subCount: 5,
        onChanged: (_) {},
      ),
    ));
    await tester.pump();

    expect(find.textContaining('Percentile clip'), findsOneWidget);
  });

  testWidgets('advanced expander reveals the per-knob controls',
      (tester) async {
    await tester.pumpWidget(_harness(
      child: IntegrationSettingsPanel(
        settings: IntegrationSettings.defaults,
        subCount: 12,
        onChanged: (_) {},
      ),
    ));
    await tester.pump();

    // Advanced groups are hidden until the expander is tapped.
    expect(find.text('ALIGNMENT'), findsNothing);

    await tester.tap(find.text('Advanced settings'));
    await tester.pumpAndSettle();

    expect(find.text('ALIGNMENT'), findsOneWidget);
    expect(find.text('PIXEL REJECTION'), findsOneWidget);
    expect(find.text('Transform model'), findsOneWidget);
  });

  testWidgets(
      'drizzle toggle drives settings.drizzle and reveals its sub-knobs',
      (tester) async {
    IntegrationSettings? reported;
    await tester.pumpWidget(_harness(
      child: IntegrationSettingsPanel(
        settings: IntegrationSettings.defaults,
        subCount: 12,
        onChanged: (s) => reported = s,
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Advanced settings'));
    await tester.pumpAndSettle();

    // The Drizzle group + toggle are present; sub-knobs hidden while off. The
    // group sits at the bottom of a long panel, so bring it into view first.
    await tester.ensureVisible(find.text('Drizzle integrate'));
    await tester.pumpAndSettle();
    expect(find.text('DRIZZLE'), findsOneWidget);
    expect(find.text('Drizzle integrate'), findsOneWidget);
    expect(find.text('Scale'), findsNothing);

    // Flipping the toggle reports drizzle == true (defaults start off). The
    // switch lives in the outermost `_RowShell` Row alongside the label, so
    // scope to that Row (closest-first ⇒ `.last` is the row carrying both).
    expect(IntegrationSettings.defaults.drizzle, isFalse);
    final toggleSwitch = find.descendant(
      of: find
          .ancestor(
            of: find.text('Drizzle integrate'),
            matching: find.byType(Row),
          )
          .last,
      matching: find.byType(SkotiqSwitch),
    );
    await tester.ensureVisible(toggleSwitch);
    await tester.pumpAndSettle();
    await tester.tap(toggleSwitch);
    await tester.pump();

    expect(reported, isNotNull);
    expect(reported!.drizzle, isTrue);
  });

  testWidgets('with drizzle on, the scale/pixfrac/kernel/bayer knobs render',
      (tester) async {
    await tester.pumpWidget(_harness(
      child: IntegrationSettingsPanel(
        settings: IntegrationSettings.defaults.copyWith(drizzle: true),
        subCount: 12,
        onChanged: (_) {},
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Advanced settings'));
    await tester.pumpAndSettle();

    expect(find.text('Scale'), findsOneWidget);
    expect(find.text('Pixfrac'), findsOneWidget);
    expect(find.text('Kernel'), findsOneWidget);
    expect(find.text('Bayer drizzle'), findsOneWidget);
  });

  // profiles must not be placebos
  //
  // "Maximum Quality" shipped as a byte-identical copy of Balanced: it restated
  // five constructor defaults and differed only in `sourcePreset`, a label the
  // native pipeline never reads. A user picking it for their best data got the
  // same stack and was told nothing.

  test('no two integration profiles produce the same stack', () {
    // `sourcePreset` is a UI label, not a stacking knob — compare everything
    // else via the bridge payload, which is exactly what the native side gets.
    final byPayload = <String, IntegrationPreset>{};
    for (final preset in IntegrationPreset.values) {
      final payload =
          IntegrationSettings.preset(preset).toBridgeSettings().toString();
      final clash = byPayload[payload];
      expect(
        clash,
        isNull,
        reason: '${preset.label} stacks identically to ${clash?.label} — '
            'a profile that changes nothing must not be offered.',
      );
      byPayload[payload] = preset;
    }
  });

  test('Maximum Quality actually costs something over Balanced', () {
    const balanced = IntegrationSettings.defaults;
    final maxQ = IntegrationSettings.preset(IntegrationPreset.maximumQuality);

    // Tighter inlier gate + more reference stars = a more accurate transform
    // for more matching work.
    expect(maxQ.ransacThresholdPx, lessThan(balanced.ransacThresholdPx));
    expect(maxQ.maxRefStars, greaterThan(balanced.maxRefStars));
    // Per-cell background match rather than one global scale.
    expect(maxQ.normalization, NormalizationMode.local);
    expect(balanced.normalization, NormalizationMode.global);
  });

  testWidgets('the readout names the knobs the active profile changes',
      (tester) async {
    await tester.pumpWidget(_harness(
      child: IntegrationSettingsPanel(
        settings: IntegrationSettings.preset(IntegrationPreset.maximumQuality),
        subCount: 12,
        onChanged: (_) {},
      ),
    ));
    await tester.pump();
    expect(find.textContaining('RANSAC 1.0 px'), findsOneWidget);
    expect(find.textContaining('Max ref stars 120'), findsOneWidget);
    expect(find.textContaining('Normalization Local grid'), findsOneWidget);

    // Balanced IS the baseline, so it says so rather than inventing a
    // difference.
    await tester.pumpWidget(_harness(
      child: IntegrationSettingsPanel(
        settings: IntegrationSettings.preset(IntegrationPreset.balanced),
        subCount: 12,
        onChanged: (_) {},
      ),
    ));
    await tester.pump();
    expect(find.text('Same knobs as Balanced.'), findsOneWidget);
  });
}

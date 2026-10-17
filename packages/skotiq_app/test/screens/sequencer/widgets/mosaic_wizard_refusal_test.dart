// The Mosaic Wizard must refuse visibly and tell one story.
//
// With no panel size, "Create mosaic project" is disabled — but if the only
// explanation is a hover tooltip it does nothing at all on click: no snackbar,
// no inline error, no dialog, so the primary action of the whole feature is
// indistinguishable from a broken button. And one screen below, "Advanced
// (numerical)" must not pre-fill a concrete 60.0 x 40.0 panel field under a
// banner saying the panel field is unknown.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mosaic_wizard_dialog.dart';
import 'package:skotiq_app/widgets/gated_action.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_backend.dart';
import '../../../harness/pump_app_screen.dart';

Future<void> _pumpWizard(
  WidgetTester tester, {
  OpticalConfig? optics,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1600, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final backend = mockBackend();
  when(() => backend.hasCheckpoint()).thenAnswer((_) async => false);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider
            .overrideWith((ref) => TestBackendNotifier(ref, backend)),
        smartNightExposureContextProvider.overrideWith((ref) async => null),
        opticalConfigProvider.overrideWithValue(optics),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: MosaicWizardDialog(initialRa: 12.5, initialDec: 30),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _rig = OpticalConfig(
  telescopeName: 'Test scope',
  focalLength: 500,
  aperture: 100,
  cameraName: 'Test cam',
  sensorWidth: 4144,
  sensorHeight: 2822,
  pixelSize: 4.63,
);

void main() {
  testWidgets('the footer says why the primary action cannot run',
      (tester) async {
    await _pumpWizard(tester);

    final reason = find.byKey(const ValueKey('mosaic_action_blocked_reason'));
    expect(reason, findsOneWidget);
    expect(
      tester
          .widget<Text>(
              find.descendant(of: reason, matching: find.byType(Text)))
          .data,
      allOf(contains('Panel size unknown'), contains('Advanced')),
    );
    expect(
      tester
          .widget<SkotiqButton>(
            find.byKey(const ValueKey('mosaic_create_project_btn')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('no reason is shown once the rig supplies a panel size',
      (tester) async {
    await _pumpWizard(tester, optics: _rig);

    expect(
      find.byKey(const ValueKey('mosaic_action_blocked_reason')),
      findsNothing,
    );
    expect(
      tester
          .widget<SkotiqButton>(
            find.byKey(const ValueKey('mosaic_create_project_btn')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('Advanced does not pre-fill a panel size the wizard disclaims',
      (tester) async {
    await _pumpWizard(tester);

    await tester.ensureVisible(find.text('Advanced (numerical)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced (numerical)'));
    await tester.pumpAndSettle();

    final width = find.ancestor(
      of: find.text('Panel width (arcmin)'),
      matching: find.byType(TextField),
    );
    final height = find.ancestor(
      of: find.text('Panel height (arcmin)'),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(width).controller!.text, isEmpty);
    expect(tester.widget<TextField>(height).controller!.text, isEmpty);
  });

  testWidgets('BOTH typed dimensions unblock the primary action',
      (tester) async {
    // BOTH dimensions, deliberately. One typed number leaves the height at the
    // 60x40 field initialiser, so the wizard would plan (and offer to persist) a
    // grid from a dimension nobody supplied. A half-known panel size is still
    // unknown.
    await _pumpWizard(tester);

    await tester.ensureVisible(find.text('Advanced (numerical)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced (numerical)'));
    await tester.pumpAndSettle();

    final width = find.ancestor(
      of: find.text('Panel width (arcmin)'),
      matching: find.byType(TextField),
    );
    final height = find.ancestor(
      of: find.text('Panel height (arcmin)'),
      matching: find.byType(TextField),
    );

    await tester.enterText(width, '50');
    await tester.pumpAndSettle();

    // The height the user has not given must still read as unknown — the live
    // repro saw `40.0` appear here on its own and the plan quote 0.83 x 0.67.
    expect(tester.widget<TextField>(height).controller!.text, isEmpty);
    expect(
      find.byKey(const ValueKey('mosaic_action_blocked_reason')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SkotiqButton>(
            find.byKey(const ValueKey('mosaic_create_project_btn')),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(height, '35');
    await tester.pumpAndSettle();

    // The typed height survives: no auto-fill overwrites it.
    expect(tester.widget<TextField>(height).controller!.text, '35');
    expect(
      find.byKey(const ValueKey('mosaic_unknown_panel_size_banner')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('mosaic_action_blocked_reason')),
      findsNothing,
    );
    expect(
      tester
          .widget<SkotiqButton>(
            find.byKey(const ValueKey('mosaic_create_project_btn')),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.textContaining('0.83'), findsWidgets);
  });

  testWidgets('a gated footer action announces its reason to AT',
      (tester) async {
    // Undeclared, both footer actions read as plain `button: …` with no
    // `[DISABLED]`, on a wizard whose banner says the panel size is unknown. The
    // announced name carries the reason, so a tree dump distinguishes "gate
    // applied" from "gate absent".
    final handle = tester.ensureSemantics();
    await _pumpWizard(tester);

    final node = tester.getSemantics(
      find.ancestor(
        of: find.byKey(const ValueKey('mosaic_create_project_btn')),
        matching: find.byType(GatedAction),
      ),
    );
    expect(node.label, contains('Create mosaic project'));
    expect(node.label, contains('unavailable:'));
    expect(node.label, contains('Panel size unknown'));
    expect(node.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isEnabled), isFalse);
    handle.dispose();
  });
}

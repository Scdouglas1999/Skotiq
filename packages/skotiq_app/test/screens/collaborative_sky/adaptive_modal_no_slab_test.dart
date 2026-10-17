// Regression guard for: "Collaborative Sky dialogs render inside an empty
// full-height slab".
//
// showAdaptiveModal's desktop branch already wraps its builder in a Material
// Dialog painted colors.surface. Sheet bodies then returned a SECOND
// SkotiqDialog. The inner Dialog's Align expands to fill the viewport, so
// the outer dialog's painted surface stretched from y~20 to y~700 of a 720px
// window with the real card floating in the middle third — ~150px of empty
// surface above the title and below the buttons, reading as a rendering fault.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/coimaging_create_sheet.dart';
import 'package:skotiq_app/screens/constellation/constellation_sign_in_sheet.dart';
import 'package:skotiq_app/screens/constellation/constellation_ui_providers.dart'
    as ui;
import 'package:skotiq_app/screens/mosaic/mosaic_contribute_sheet.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _viewport = Size(1280, 720);

Future<void> _open(
  WidgetTester tester,
  void Function(BuildContext) open, {
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The painted modal card must wrap its content, not stretch to the viewport.
void _expectNoSlab(WidgetTester tester, String title) {
  expect(find.byType(Dialog), findsOneWidget,
      reason: 'a modal body must not nest a second Dialog inside the frame '
          'showAdaptiveModal already supplies');

  // The Dialog's own Material is the painted card; the Dialog element itself
  // also covers its insetPadding.
  final card = tester.getRect(
    find
        .descendant(of: find.byType(Dialog), matching: find.byType(Material))
        .first,
  );
  final titleRect = tester.getRect(find.text(title));
  final footerRect = tester.getRect(
    find.widgetWithText(SkotiqButton, 'Cancel'),
  );

  expect(card.height, lessThan(_viewport.height * 0.9),
      reason: 'a modal card that fills the window is the slab');
  // 40, not 32: 05 §13 sets the dialog's own padding at 24 all round, and a
  // 15px title's line box adds the rest. The guard is here to catch a SLAB -
  // the full-height card with the content floating in it, which measured in
  // the hundreds - not to hold the padding to a number the spec has moved.
  expect(titleRect.top - card.top, lessThan(40),
      reason: 'empty painted surface above the dialog title is the slab');
  expect(card.bottom - footerRect.bottom, lessThan(32),
      reason: 'empty painted surface below the dialog buttons is the slab');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Connect to a hub wraps its content', (tester) async {
    await _open(tester, showConstellationSignInSheet);
    _expectNoSlab(tester, 'Connect to a hub');
  });

  testWidgets('Start co-imaging session wraps its content', (tester) async {
    await _open(tester, showCoImagingCreateSheet);
    _expectNoSlab(tester, 'Start co-imaging session');
  });

  testWidgets('the contribute consent sheet wraps its content', (tester) async {
    await _open(
      tester,
      showMosaicContributeSheet,
      overrides: [
        ui.constellationHubInfoProvider.overrideWith(
          (ref) => Completer<HubInfo>().future,
        ),
        mosaicUploadConsentProvider.overrideWith((ref) async => null),
      ],
    );
    _expectNoSlab(tester, 'Share this panel master');
  });
}

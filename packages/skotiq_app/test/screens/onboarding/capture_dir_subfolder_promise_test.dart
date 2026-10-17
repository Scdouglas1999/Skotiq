// Regression test: the onboarding capture-folder step must describe the file
// layout the app actually produces.
//
// Observed on a fresh install: the step read "Sessions will be organized into
// target/date subfolders under this directory." Every one of the 11 frames a
// verifier then captured landed FLAT in the chosen directory as
// Unknown_NoFilter_2026-08-01_NNNN.fits, and captured_images.file_path agreed.
//
// The subfolder machinery is real — imaging_service/file_paths.dart treats the
// naming pattern as a `/`-separated path and creates the directories — but the
// SHIPPED DEFAULT pattern (`$TARGET_$FILTER_$DATE_$SEQ`, database/
// default_settings.dart) contains no separator, so nothing is ever nested.
//
// This test binds the copy to the behaviour: whatever the shipped default
// pattern is, the step is not allowed to promise subfolders the pattern does
// not create.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/capture_dir_step.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// Every rendered string in the step.
List<String> _visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data)
    .whereType<String>()
    .toList();

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'capture_dir_copy_matches_the_shipped_naming_pattern: the step does not '
      'promise subfolders a flat default pattern cannot create',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const OnboardingCaptureDirStep(),
      size: const Size(720, 900),
      settle: false,
    );
    await _drain(tester);

    // The pattern the harness DB was seeded with is the one a fresh install
    // gets, so this reads the real shipped default rather than a fixture.
    final settings = await handle.container.read(appSettingsProvider.future);
    final pattern = settings.fileNamingPattern;
    final createsSubfolders = pattern.contains('/') || pattern.contains(r'\');

    expect(createsSubfolders, isFalse,
        reason: 'Guard on the premise: the shipped default pattern "$pattern" '
            'is expected to be flat. If it gains a separator this test should '
            'be revisited alongside the copy.');

    final texts = _visibleText(tester);
    // A statement of fact about a layout the app will produce — "sessions WILL
    // BE ORGANIZED INTO target/date subfolders". Describing the pattern as the
    // thing that can create folders is fine; asserting that it does is not.
    final promise = RegExp(
      r'(will be|are)\s+organi[sz]ed.*subfolder',
      caseSensitive: false,
      dotAll: true,
    );
    expect(
      texts.where(promise.hasMatch),
      isEmpty,
      reason: 'The default pattern "$pattern" produces no subfolders, so the '
          'step must not state that sessions are organised into any. '
          'Rendered copy was: $texts',
    );
    expect(
      texts.any((t) => t.contains('naming pattern')),
      isTrue,
      reason: 'It must instead point at the thing that DOES control layout, '
          'so the promise and the behaviour cannot drift apart again.',
    );
  });
}

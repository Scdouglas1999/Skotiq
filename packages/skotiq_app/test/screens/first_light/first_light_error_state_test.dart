// The First Light error state must speak to the operator, not dump a stack.
//
// Live capture: the surface rendered "Could not load candidates /
// FormatException: Invalid radix-10 number (at character 1) / tile-1 / ^" —
// class name and caret diagram straight into the UI, telling an operator
// nothing about whether the night's data survived.
//
// (The Retry half of that finding — a drift stream that replays its cached
// failure forever — is already fixed in the provider: see
// skotiq_core/test/providers/first_light_candidates_resilience_test.dart.)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/first_light/first_light_view.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('a load failure explains itself before it quotes the exception',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firstLightCandidatesProvider.overrideWith(
            (ref) => Stream<List<TransientDetectionRow>>.error(
              const FormatException('Invalid radix-10 number', 'tile-1', 0),
            ),
          ),
          recentNarratorFeedProvider.overrideWith(
            (ref) => Stream.value(const <NarratorEvent>[]),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: FirstLightView()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not load candidates'), findsOneWidget);
    expect(
      find.textContaining('untouched'),
      findsOneWidget,
      reason: 'the operator needs to know their frames are safe',
    );
    expect(
      find.textContaining('Details:'),
      findsOneWidget,
      reason: 'the technical text is kept, just not as the whole message',
    );
    expect(find.text('Retry'), findsOneWidget);
  });
}

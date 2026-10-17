import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/first_light/first_light_view.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A `kind` token this build does not know — the shape the audit hit with a
/// row written as `new_source` instead of the wire token `newSource`.
TransientDetectionRow _detection({String kind = 'new_source'}) {
  return TransientDetectionRow(
    id: 1,
    sessionId: null,
    capturedImageId: null,
    tileId: 42,
    detectedAt: DateTime.utc(2026, 6, 19, 22, 30),
    raDeg: 120.5,
    decDeg: -25.25,
    residualFlux: 1500.0,
    deltaMag: null,
    snr: 18.3,
    fwhm: 2.1,
    eccentricity: 0.12,
    positionAngleDeg: 0.0,
    kind: kind,
    catalogMatch: null,
    confidence: 0.81,
    reviewed: true,
    dismissed: false,
  );
}

Future<void> _pump(WidgetTester tester, TransientDetectionRow row) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        firstLightCandidatesProvider.overrideWith((ref) => Stream.value([row])),
        recentNarratorFeedProvider.overrideWith((ref) => Stream.value([])),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: FirstLightView()),
      ),
    ),
  );
}

void main() {
  group('an unrecognised transient-kind token', () {
    test('parses to unknown, not to a claimed dipole morphology', () {
      expect(TransientKind.fromWire('new_source'), TransientKind.unknown);
      expect(TransientKind.unknown.label, 'Unclassified');
      expect(TransientKind.unknown.isSubmittable, isFalse);
      expect(
        TransientKind.unknown.submissionBlockedReason,
        contains('unrecognised classification'),
      );
      // The conservative gate is unchanged for a real dipole.
      expect(TransientKind.dipole.isSubmittable, isFalse);
      expect(
        TransientKind.dipole.submissionBlockedReason,
        contains('Dipole artefacts'),
      );
      expect(TransientKind.newSource.isSubmittable, isTrue);
      expect(TransientKind.newSource.submissionBlockedReason, isNull);
    });

    testWidgets('renders as Unclassified on the candidate card',
        (tester) async {
      await _pump(tester, _detection());
      await tester.pumpAndSettle();

      expect(find.text('Unclassified'), findsOneWidget);
      expect(find.text('Dipole'), findsNothing);
    });

    testWidgets('is refused without asserting it is a dipole', (tester) async {
      await _pump(tester, _detection());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Submit'));
      await tester.pump();

      expect(
        find.textContaining('unrecognised classification'),
        findsOneWidget,
      );
      expect(find.textContaining('Dipole artefacts'), findsNothing);
    });
  });
}

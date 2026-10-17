import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/first_light/first_light_view.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _ResultMountService extends MountCommandService {
  _ResultMountService(super.ref, this.result);

  final CommandActionResult result;

  @override
  bool get isConnected => true;

  @override
  Future<CommandActionResult> slewTo(
    double ra,
    double dec, {
    bool showFeedback = true,
  }) async =>
      result;
}

TransientDetectionRow _detection({
  int id = 1,
  String kind = 'newSource',
  String? catalogMatch,
  double? deltaMag,
  bool reviewed = false,
  bool dismissed = false,
}) {
  return TransientDetectionRow(
    id: id,
    sessionId: null,
    capturedImageId: null,
    tileId: 42,
    detectedAt: DateTime.utc(2026, 6, 19, 22, 30),
    raDeg: 120.5,
    decDeg: -25.25,
    residualFlux: 1500.0,
    deltaMag: deltaMag,
    snr: 18.3,
    fwhm: 2.1,
    eccentricity: 0.12,
    positionAngleDeg: 0.0,
    kind: kind,
    catalogMatch: catalogMatch,
    confidence: 0.81,
    reviewed: reviewed,
    dismissed: dismissed,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required List<TransientDetectionRow> candidates,
  List<NarratorEvent> narrator = const [],
  List<Override> overrides = const [],
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        firstLightCandidatesProvider.overrideWith(
          (ref) => Stream.value(candidates),
        ),
        recentNarratorFeedProvider.overrideWith(
          (ref) => Stream.value(narrator),
        ),
        ...overrides,
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: FirstLightView()),
      ),
    ),
  );
}

void main() {
  group('FirstLightView', () {
    testWidgets('renders the unnamed-transient verdict and cutout strip', (
      tester,
    ) async {
      await _pump(tester, candidates: [_detection()]);
      await tester.pumpAndSettle();

      expect(find.text('Possible unknown transient'), findsOneWidget);
      // The three side-by-side cutout panels (template / science / residual).
      expect(find.text('Template'), findsOneWidget);
      expect(find.text('Science'), findsOneWidget);
      expect(find.text('Residual'), findsOneWidget);
      // No real-pixel crops in a unit test → the honest schematic caption shows.
      expect(
        find.textContaining('Schematic'),
        findsOneWidget,
      );
      // The metrics + actions.
      expect(find.textContaining('SNR 18.3'), findsOneWidget);
      expect(find.text('Submit'), findsOneWidget);
      expect(find.text('Confirm'), findsOneWidget);
    });

    testWidgets('names a catalog-matched brightening and shows the delta mag', (
      tester,
    ) async {
      await _pump(
        tester,
        candidates: [
          _detection(
            kind: 'pointBrightening',
            catalogMatch: 'Star V=12.3',
            deltaMag: -0.42,
          ),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('Star V=12.3'), findsOneWidget);
      expect(find.textContaining('0.42 mag'), findsOneWidget);
    });

    testWidgets(
        'a brightening shows a NEGATIVE signed delta mag '
        '(negative = brighter, matching the stored convention)', (
      tester,
    ) async {
      // Native truth: Δmag is negative when the source brightened. The card must
      // print the real signed value (a brightening -> "-0.42 mag"), not flip the
      // sign so a brightening reads as fainter.
      await _pump(
        tester,
        candidates: [
          _detection(
            kind: 'pointBrightening',
            catalogMatch: 'Star V=12.3',
            deltaMag: -0.42,
          ),
        ],
      );
      await tester.pumpAndSettle();

      // The signed value is shown as negative — NOT "+0.42 mag".
      expect(find.textContaining('-0.42 mag'), findsOneWidget);
      expect(find.textContaining('+0.42 mag'), findsNothing);
    });

    testWidgets('a fading shows a POSITIVE signed delta mag', (tester) async {
      await _pump(
        tester,
        candidates: [
          _detection(
            kind: 'pointBrightening',
            catalogMatch: 'Star V=12.3',
            deltaMag: 0.42, // positive = fainter
          ),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('+0.42 mag'), findsOneWidget);
    });

    testWidgets(
        'the Confirmed filter shows reviewed AND not-dismissed rows '
        'only (a dismissed-but-reviewed artefact is excluded)', (
      tester,
    ) async {
      await _pump(
        tester,
        candidates: [
          // Confirmed: reviewed, not dismissed -> belongs under Confirmed.
          _detection(id: 1, catalogMatch: 'Confirmed SN', reviewed: true),
          // Dismissed artefact: markReviewed sets reviewed=true AND dismissed=true.
          // Must NOT pollute the curated Confirmed list.
          _detection(
            id: 2,
            catalogMatch: 'Dismissed artefact',
            reviewed: true,
            dismissed: true,
          ),
          // Untriaged: reviewed=false -> not Confirmed.
          _detection(id: 3, catalogMatch: 'Untriaged source'),
        ],
      );
      await tester.pumpAndSettle();

      // Switch to the Confirmed filter (the chip is the first "Confirmed" text;
      // reviewed cards also carry a "Confirmed" status badge).
      await tester.tap(find.text('Confirmed').first);
      await tester.pumpAndSettle();

      expect(find.text('Confirmed SN'), findsOneWidget);
      expect(find.text('Dismissed artefact'), findsNothing);
      expect(find.text('Untriaged source'), findsNothing);
    });

    testWidgets('offers a Chase action that warns when no mount is connected', (
      tester,
    ) async {
      // GAP #5: the card must offer a slew/re-image action (the "chase before
      // it fades" loop), not just Submit/Confirm/Dismiss. With no mount
      // connected, tapping Chase surfaces a clear warning rather than no-oping.
      await _pump(tester, candidates: [_detection()]);
      await tester.pumpAndSettle();

      final chase = find.text('Chase');
      expect(chase, findsOneWidget);

      await tester.tap(chase);
      await tester.pump();

      expect(
        find.textContaining('No mount connected'),
        findsOneWidget,
      );
    });

    testWidgets('Chase renders command failures as errors', (tester) async {
      await _pump(
        tester,
        candidates: [_detection()],
        overrides: [
          mountCommandServiceProvider.overrideWith(
            (ref) => _ResultMountService(
              ref,
              const CommandActionResult.failure(
                'This mount reports that GoTo slewing is unsupported',
              ),
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chase'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Slew'));
      await tester.pumpAndSettle();

      expect(
        find.text('This mount reports that GoTo slewing is unsupported'),
        findsOneWidget,
      );
      final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
      final context = tester.element(find.byType(FirstLightView));
      expect(snackBar.backgroundColor, SkotiqColors.of(context).error);
    });

    testWidgets('shows the empty state when there are no candidates', (
      tester,
    ) async {
      await _pump(tester, candidates: const []);
      await tester.pumpAndSettle();

      expect(find.text('No transients yet'), findsOneWidget);
      // No candidate card actions when empty.
      expect(find.text('Submit'), findsNothing);
    });

    testWidgets('surfaces a celebrate Narrator event as the highlight', (
      tester,
    ) async {
      final event = NarratorEvent(
        id: 1,
        sessionId: null,
        capturedImageId: null,
        timestamp: DateTime.now(),
        eventType: 'first_light.transient',
        category: NarratorCategory.discovery,
        severity: NarratorSeverity.celebrate,
        headline: 'Possible transient — a new source at 08h02m',
        body: 'Re-image to confirm.',
        evidence: null,
        dedupeKey: 'first_light.transient:42',
        pinned: true,
      );

      await _pump(tester, candidates: [_detection()], narrator: [event]);
      await tester.pumpAndSettle();

      expect(find.text("Tonight's highlight"), findsOneWidget);
      expect(
        find.text('Possible transient — a new source at 08h02m'),
        findsOneWidget,
      );
    });
  });
}

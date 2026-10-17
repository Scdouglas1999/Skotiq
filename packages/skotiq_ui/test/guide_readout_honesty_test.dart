// The guiding readouts state only what has been measured.
//
// 1. A hard-coded arcsecond suffix on values the guiding screen supplies in
//    guide-camera pixels puts the same three numbers on one card twice with
//    contradictory units ("RA: 0.53 px" in the card header, "RA: 0.53\"" in
//    the row directly beneath it), so GuideGraphAdvanced carries the unit it
//    is given.
// 2. A readout that defaults to 0 lets a guider that has never produced a
//    guide step advertise "Tot: 0.00" — a perfect-guiding claim with no
//    measurement behind it.
// 3. An error-red frame at SNR 0 marks an idle guider, which reports exactly
//    that value, as a rig that has lost the star.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host(Widget child) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(body: SizedBox(width: 600, height: 320, child: child)),
);

void main() {
  group('GuideGraphAdvanced RMS readouts', () {
    testWidgets('render an em dash when there is no measurement', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const GuideGraphAdvanced(data: [])));
      await tester.pump();

      expect(find.text('—'), findsNWidgets(3));
      expect(find.text('0.00"'), findsNothing);
      expect(find.text('0.00 px'), findsNothing);
    });

    testWidgets('use the unit the caller supplied, not a hard-coded arcsec', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const GuideGraphAdvanced(
            data: [],
            rmsRa: 0.53,
            rmsDec: 0.57,
            rmsTotal: 0.78,
            rmsUnit: ' px',
            valueUnit: ' px',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('0.53 px'), findsOneWidget);
      expect(find.text('0.57 px'), findsOneWidget);
      expect(find.text('0.78 px'), findsOneWidget);
      // The unit suffix must follow the unit actually being displayed.
      expect(find.text('0.53"'), findsNothing);
    });

    testWidgets('still defaults to arcsec for callers that pass arcsec', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const GuideGraphAdvanced(
            data: [],
            rmsRa: 0.41,
            rmsDec: 0.44,
            rmsTotal: 0.60,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('0.41"'), findsOneWidget);
      expect(find.text('0.60"'), findsOneWidget);
    });
  });

  group('GuideStarView idle framing', () {
    testWidgets(
      'frames an empty preview with the neutral border, not error red',
      (tester) async {
        await tester.pumpWidget(
          _host(
            const GuideStarView(
              statusMessage:
                  'Press Loop Exposures or Start to acquire a guide star',
            ),
          ),
        );
        await tester.pump();

        final context = tester.element(find.byType(GuideStarView));
        final colors = context.skotiqColors;

        final container = tester.widget<Container>(
          find
              .descendant(
                of: find.byType(GuideStarView),
                matching: find.byType(Container),
              )
              .first,
        );
        final border = (container.decoration as BoxDecoration).border as Border;
        expect(
          border.top.color.toARGB32(),
          colors.border.withValues(alpha: 0.5).toARGB32(),
          reason: 'an idle guide-star preview must not be framed in error red',
        );
        expect(
          border.top.color.toARGB32(),
          isNot(colors.error.withValues(alpha: 0.5).toARGB32()),
        );
        expect(
          find.text('Press Loop Exposures or Start to acquire a guide star'),
          findsOneWidget,
        );
      },
    );
  });
}

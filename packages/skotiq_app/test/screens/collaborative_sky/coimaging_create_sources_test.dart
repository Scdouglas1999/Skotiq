// Starting a co-imaging session used to mean typing RA and Dec in DEGREES by
// hand, next to a connected mount already pointing at the target and a catalog
// search the app runs on the adjacent tab.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/coimaging_create_sheet.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_node_properties.dart'
    show TargetCoordinateMatch, targetCoordinateLookupProvider;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _FixedMount extends MountStateNotifier {
  _FixedMount(super.ref, MountState fixed) {
    state = fixed;
  }
}

const _pointing = MountState(
  connectionState: DeviceConnectionState.connected,
  // RA in HOURS, as MountState reports it: 20h 58m 47s.
  ra: 20.979722,
  dec: 44.31,
);

Future<void> _openSheet(
  WidgetTester tester, {
  MountState mount = const MountState(),
  List<TargetCoordinateMatch> matches = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mountStateProvider.overrideWith((ref) => _FixedMount(ref, mount)),
        targetCoordinateLookupProvider('NGC 7000')
            .overrideWith((ref) async => matches),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showCoImagingCreateSheet(context),
                child: const Text('start'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('start'));
  await tester.pumpAndSettle();
}

/// Joins on the field's own label, never on position in the form.
TextEditingController _field(WidgetTester tester, String label) {
  final field = tester
      .widgetList<SkotiqTextField>(find.byType(SkotiqTextField))
      .firstWhere((f) => f.label == label);
  return field.controller!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('From mount fills the centre from where the scope points',
      (tester) async {
    await _openSheet(tester, mount: _pointing);

    expect(_field(tester, 'Center RA (degrees)').text, isEmpty);

    await tester.tap(find.widgetWithText(SkotiqButton, 'From mount'));
    await tester.pumpAndSettle();

    // 20.979722h * 15 = 314.6958 deg.
    expect(_field(tester, 'Center RA (degrees)').text, '314.6958');
    expect(_field(tester, 'Center Dec (degrees)').text, '44.31');
  });

  testWidgets('From mount is unavailable with no mount connected',
      (tester) async {
    await _openSheet(tester);

    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'From mount'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('a catalog match fills name and centre in one tap',
      (tester) async {
    await _openSheet(
      tester,
      matches: const [
        TargetCoordinateMatch(
          name: 'NGC 7000 North America Nebula',
          catalogId: 'NGC 7000',
          raHours: 20.979722,
          decDegrees: 44.31,
        ),
      ],
    );

    await tester.enterText(find.byType(TextField).first, 'NGC 7000');
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(SkotiqButton, 'Look up coordinates'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('NGC 7000 North America Nebula'));
    await tester.pumpAndSettle();

    expect(_field(tester, 'Center RA (degrees)').text, '314.6958');
    expect(_field(tester, 'Center Dec (degrees)').text, '44.31');
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Start session'),
          )
          .onPressed,
      isNotNull,
      reason: 'a resolved target must be enough to start the session',
    );
  });
}

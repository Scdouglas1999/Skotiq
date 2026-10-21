// Enter in the Framing target search lands on the object the text names.
//
// The owner typed "M42", pressed Enter and was framed on "Cl* NGC 2516 HTR
// M42" (another build: "[SSP2021] M42"). Two faults combined: Enter read the
// result list of the previous keystroke, which is empty while the catalog is
// still loading, and then fell back to a SIMBAD query that took the first
// identifier merely CONTAINING "M42".

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/framing_screen.dart';
import 'package:skotiq_app/widgets/tutorial_keys/framing_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' hide FramingView;

import '../../harness/harness.dart';

/// OpenNGC's row for M42, as the catalog loader builds it.
const _ngc1976 = DeepSkyObject(
  id: 'NGC1976',
  name: 'M42',
  coordinates: CelestialCoordinate(ra: 5.587911, dec: -5.389667),
  type: DsoType.clusterWithNebulosity,
  magnitude: 4.0,
  sizeArcMin: 90,
  catalogIds: ['LBN 974', 'MWSC 0582', 'M42'],
  commonNames: 'Great Orion Nebula,Orion Nebula',
);

/// An object that carries "M42" inside a cross-identifier, the shape of the
/// SIMBAD objects the old search returned. Brighter than M42 on purpose, so
/// magnitude order alone would rank it first.
const _trap = DeepSkyObject(
  id: 'NGC9998',
  name: 'NGC9998',
  coordinates: CelestialCoordinate(ra: 7.968, dec: -60.753),
  type: DsoType.openCluster,
  magnitude: 3.8,
  catalogIds: ['Cl* NGC 2516 HTR M42', '[SSP2021] M42'],
);

class _RecordingFraming extends FramingNotifier {
  _RecordingFraming(super.ref);

  final selected = <FramingTarget>[];

  @override
  void setTarget(FramingTarget target) {
    selected.add(target);
    // ignore: invalid_use_of_protected_member
    state = state.copyWith(target: target);
  }

  @override
  Future<void> loadSurveyImage({double? canvasWidthLogicalPx}) async {}
}

/// Stands in for SIMBAD's exact resolver and records what it was asked.
class _FakeSesame extends SesameNameResolver {
  _FakeSesame(this.answers);

  final Map<String, ResolvedTargetName> answers;
  final asked = <String>[];

  @override
  Future<ResolvedTargetName?> resolve(String name) async {
    asked.add(name);
    return answers[name];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingFraming framing;
  late _FakeSesame sesame;

  Future<void> pumpFraming(
    WidgetTester tester, {
    required Future<List<DeepSkyObject>> catalog,
  }) async {
    sesame = _FakeSesame({
      'Sh2-129': const ResolvedTargetName(
        mainId: 'SH 2-129',
        raHours: 21.196667,
        decDegrees: 59.95,
        objectType: 'HII',
      ),
    });
    await pumpAppScreen(
      tester,
      const FramingView(),
      size: const Size(1280, 900),
      settle: false,
      extraOverrides: [
        framingProvider.overrideWith((ref) => framing = _RecordingFraming(ref)),
        loadedDsosProvider.overrideWith((ref) => catalog),
        sesameNameResolverProvider.overrideWithValue(sesame),
      ],
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder searchField() => find.descendant(
        of: find.byKey(FramingTutorialKeys.targetSearch),
        matching: find.byType(EditableText),
      );

  Future<void> typeAndEnter(WidgetTester tester, String text) async {
    await tester.tap(searchField());
    await tester.enterText(searchField(), text);
    await tester.testTextInput.receiveAction(TextInputAction.search);
  }

  testWidgets('Enter on "M42" while the catalog is still loading frames M42',
      (tester) async {
    final catalog = Completer<List<DeepSkyObject>>();
    await pumpFraming(tester, catalog: catalog.future);

    await typeAndEnter(tester, 'M42');
    await tester.pump(const Duration(milliseconds: 100));
    expect(framing.selected, isEmpty, reason: 'nothing to pick from yet');

    catalog.complete(const [_trap, _ngc1976]);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final target = framing.selected.single;
    expect(target.catalogId, 'NGC1976');
    // Orion Nebula: RA 05h 35m 17s, Dec -05 23'.
    expect(target.raHours, closeTo(5.588, 0.001));
    expect(target.decDegrees, closeTo(-5.390, 0.001));
    expect(sesame.asked, isEmpty, reason: 'M42 is in the local catalog');
  });

  for (final query in ['m42', 'M 42', 'Messier 42', 'Orion Nebula']) {
    testWidgets('Enter on "$query" frames the Orion Nebula', (tester) async {
      await pumpFraming(tester, catalog: Future.value(const [_trap, _ngc1976]));
      await typeAndEnter(tester, query);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(framing.selected.single.catalogId, 'NGC1976');
    });
  }

  testWidgets('the result list puts M42 above the substring match',
      (tester) async {
    await pumpFraming(tester, catalog: Future.value(const [_trap, _ngc1976]));
    await tester.tap(searchField());
    await tester.enterText(searchField(), 'M42');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final rows = find.text('NGC1976');
    expect(rows, findsOneWidget);
    expect(find.text('NGC9998'), findsOneWidget);
    expect(
      tester.getTopLeft(rows).dy,
      lessThan(tester.getTopLeft(find.text('NGC9998')).dy),
    );

    await tester.tap(rows);
    await tester.pump(const Duration(milliseconds: 100));
    expect(framing.selected.single.raHours, closeTo(5.588, 0.001));
  });

  testWidgets('a name the catalog lacks is resolved exactly online',
      (tester) async {
    await pumpFraming(tester, catalog: Future.value(const [_trap, _ngc1976]));
    await typeAndEnter(tester, 'Sh2-129');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(sesame.asked, ['Sh2-129']);
    final target = framing.selected.single;
    expect(target.name, 'SH 2-129');
    expect(target.raHours, closeTo(21.197, 0.001));
    expect(target.decDegrees, closeTo(59.95, 0.001));
  });

  testWidgets('an unknown name says so instead of framing something else',
      (tester) async {
    await pumpFraming(tester, catalog: Future.value(const [_trap, _ngc1976]));
    await typeAndEnter(tester, 'Zzyzx 42');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(framing.selected, isEmpty);
    expect(find.textContaining('No object named "Zzyzx 42"'), findsOneWidget);
  });
}

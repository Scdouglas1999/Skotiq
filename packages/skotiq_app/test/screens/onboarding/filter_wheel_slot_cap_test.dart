// The onboarding filter editor must not invent slots the wheel does not have.
//
// Live finding: after picking the Simulated Filter Wheel the step listed its
// real seven positions and "Add slot" happily created an eighth, pre-filled
// "Filter 8". The only cap was a hardcoded 12, never the count the driver had
// just reported — so onboarding could persist a profile whose filter list the
// hardware can never reach.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/filter_wheel_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Draft standing in for "the user picked the seven-position sim wheel".
class _PickedWheelNotifier extends OnboardingNotifier {
  _PickedWheelNotifier(super.ref, List<String> names) {
    // ignore: invalid_use_of_protected_member
    state = OnboardingDraft(
      currentStep: OnboardingStep.filterWheel,
      filterWheelId: 'sim_filter_wheel_1',
      filterWheelName: 'Simulated Filter Wheel',
      filterNames: names,
    );
  }
}

/// A wheel notifier parked in a fixed state — connected and reporting
/// [slots] positions, or left disconnected when [slots] is empty.
class _StubWheel extends FilterWheelStateNotifier {
  _StubWheel(super.ref, List<String> slots) {
    if (slots.isEmpty) return;
    // ignore: invalid_use_of_protected_member
    state = FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim_filter_wheel_1',
      deviceName: 'Simulated Filter Wheel',
      filterNames: slots,
    );
  }
}

const _sevenSlots = <String>['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'];

Future<void> _pump(
  WidgetTester tester, {
  required List<String> draftNames,
  required List<String> wheelSlots,
}) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 1800);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        onboardingDraftProvider
            .overrideWith((ref) => _PickedWheelNotifier(ref, draftNames)),
        filterWheelStateProvider
            .overrideWith((ref) => _StubWheel(ref, wheelSlots)),
        // The real wheel notifier listens to the active profile; without this
        // the listen opens a drift query stream over the scratch database and
        // the widget test tears down with pending timers.
        activeProfileProvider.overrideWith((ref) => Stream.value(null)),
        allProfilesProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: OnboardingFilterWheelStep()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

SkotiqButton _addSlotButton(WidgetTester tester) =>
    tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Add slot'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // At the cap there is NO button, not a disabled one: a disabled control still
  // publishes a plain button with a tap action to the accessibility tree, and
  // pressing it produces no row, no toast and no message. A wheel with seven
  // positions has no eighth ever, so the reason goes on screen rather than into
  // a tooltip nobody can reach.
  testWidgets('no Add slot control exists once every wheel position is listed',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      draftNames: _sevenSlots,
      wheelSlots: _sevenSlots,
    );

    expect(find.widgetWithText(TextField, 'SII'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'Add slot'),
      findsNothing,
      reason: 'a 7-position wheel has no slot 8 to hold "Filter 8"',
    );

    final tappableAddSlot = <String>[];
    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.label.contains('Add slot') &&
          data.hasAction(SemanticsAction.tap)) {
        tappableAddSlot.add(data.label);
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    expect(
      tappableAddSlot,
      isEmpty,
      reason: 'assistive tech was offered a press that does nothing',
    );

    expect(
      find.textContaining('no slot 8 to hold another filter'),
      findsOneWidget,
      reason: 'a control that vanishes without a reason reads as a bug',
    );
    handle.dispose();
  });

  testWidgets('Add slot still works below the wheel position count',
      (tester) async {
    await _pump(
      tester,
      draftNames: const ['L', 'R', 'G'],
      wheelSlots: _sevenSlots,
    );

    expect(_addSlotButton(tester).onPressed, isNotNull);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Add slot'));
    await tester.pump();
    expect(
      find.widgetWithText(TextField, 'B'),
      findsOneWidget,
      reason: 'the wheel says position 4 holds B',
    );
    expect(find.widgetWithText(TextField, 'Filter 4'), findsNothing);
  });

  // Deleting the last slot and adding it back must not invent "Filter 7" — a
  // filter name nobody typed and no wheel reports, which would travel into
  // FITS headers, flat matching and per-filter focus offsets.
  testWidgets('a re-added slot recovers the wheel\'s own name for it',
      (tester) async {
    await _pump(
      tester,
      draftNames: _sevenSlots,
      wheelSlots: _sevenSlots,
    );

    await tester.tap(find.byIcon(SkotiqIcons.delete).last);
    await tester.pump();
    expect(find.widgetWithText(TextField, 'SII'), findsNothing);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Add slot'));
    await tester.pump();

    expect(find.widgetWithText(TextField, 'Filter 7'), findsNothing);
    expect(find.widgetWithText(TextField, 'SII'), findsOneWidget);
  });

  testWidgets('a slot beyond anything the wheel reports opens blank',
      (tester) async {
    await _pump(
      tester,
      draftNames: const ['L', 'R', 'G'],
      wheelSlots: const <String>[],
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Add slot'));
    await tester.pump();

    expect(find.widgetWithText(TextField, 'Filter 4'), findsNothing);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.length, 4);
    expect(fields.last.controller?.text, isEmpty);
  });

  testWidgets('with no wheel reading the generic cap still applies',
      (tester) async {
    // Twelve names, wheel not connected: nothing reported the real count, so
    // the editor keeps the generic profile-wide bound rather than fabricating
    // one from the hardware.
    await _pump(
      tester,
      draftNames: List<String>.generate(12, (i) => 'F${i + 1}'),
      wheelSlots: const <String>[],
    );

    expect(find.widgetWithText(SkotiqButton, 'Add slot'), findsNothing);
    expect(find.textContaining('positions on this wheel'), findsNothing);
    expect(
      find.text('A profile can hold at most 12 filters.'),
      findsOneWidget,
      reason: 'the generic bound has to say what it is, too',
    );
  });

  testWidgets('removing a middle slot asks first, removing the last does not',
      (tester) async {
    await _pump(
      tester,
      draftNames: const ['L', 'R', 'G'],
      wheelSlots: _sevenSlots,
    );

    final deleteButtons = find.byIcon(SkotiqIcons.delete);
    expect(deleteButtons, findsNWidgets(3));

    // Middle row: renumbers everything below it, so it must be confirmed.
    await tester.tap(deleteButtons.at(0));
    await tester.pumpAndSettle();
    expect(find.text('Remove this slot?'), findsOneWidget);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'L'), findsOneWidget);

    // Last row: cannot renumber anything, so it stays a single click.
    await tester.tap(find.byIcon(SkotiqIcons.delete).at(2));
    await tester.pumpAndSettle();
    expect(find.text('Remove this slot?'), findsNothing);
    expect(find.widgetWithText(TextField, 'G'), findsNothing);
  });
}

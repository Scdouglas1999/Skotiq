// In Settings › Equipment Profiles › Edit the Filter Focus Offsets card is
// built from the SAME controllers as the Filter Configuration chips, so the
// chip's name field must fire a rebuild. Without one the two lists disagree for
// the rest of the edit session: naming the first filter produces no offsets card
// at all, and a filter added with '+' has no offset input until the operator
// saves and re-opens the editor.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/equipment_profiles_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const _emptyRig = EquipmentProfileModel(
  id: 7,
  name: 'Imaging rig',
  isActive: true,
);

const _oneFilterRig = EquipmentProfileModel(
  id: 7,
  name: 'Imaging rig',
  filterNames: ['Lum'],
  isActive: true,
);

class _StaticProfilesNotifier extends EquipmentProfilesNotifier {
  _StaticProfilesNotifier(this.profile);

  final EquipmentProfileModel profile;

  @override
  Future<EquipmentProfilesState> build() => Future.value(
        EquipmentProfilesState(
          profiles: [profile],
          activeProfile: profile,
        ),
      );
}

/// The editable filter-name chips, identified by their placeholder.
Finder get _filterNameFields => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Filter name',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openEditor(
    WidgetTester tester,
    EquipmentProfileModel profile,
  ) async {
    await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      size: const Size(1400, 1400),
      settle: false,
      extraOverrides: [
        equipmentProfilesProvider
            .overrideWith(() => _StaticProfilesNotifier(profile)),
      ],
    );
    await tester.pump();
    await tester.pump();

    final overflow = find.byType(PopupMenuButton<String>);
    expect(overflow, findsWidgets);
    await tester.tap(overflow.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
  }

  testWidgets('naming the first filter reveals its focus-offset row at once',
      (tester) async {
    await openEditor(tester, _emptyRig);

    // A rig with no filters starts with one blank chip and no offsets card.
    expect(find.text('Filter focus offsets'), findsNothing);

    await tester.enterText(_filterNameFields.first, 'Lum');
    await tester.pump();

    expect(find.text('Filter focus offsets'), findsOneWidget,
        reason: 'the offsets card must follow the name in the same session');
    // Chip (EditableText) plus the offsets-row label.
    expect(find.text('Lum'), findsNWidgets(2));
  });

  testWidgets('a filter added with + gets an offset row without saving',
      (tester) async {
    await openEditor(tester, _oneFilterRig);

    expect(find.text('Filter focus offsets'), findsOneWidget);
    expect(_filterNameFields, findsOneWidget);

    await tester.tap(find.byTooltip('Add filter'));
    await tester.pumpAndSettle();
    expect(_filterNameFields, findsNWidgets(2));

    await tester.enterText(_filterNameFields.last, 'Ha');
    await tester.pump();

    // Both filters now describe the same set: chip + offsets label each.
    expect(find.text('Lum'), findsNWidgets(2));
    expect(find.text('Ha'), findsNWidgets(2),
        reason: 'the new filter must have an offset input immediately');
    expect(tester.takeException(), isNull);
  });
}

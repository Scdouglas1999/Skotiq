// Regressions for four live Settings › Equipment Profiles defects:
//
//  * deleting the selected profile left the detail pane rendering the deleted
//    row — with a live "Set Active" that threw "no such profile row" into the
//    log — beside a list that already read "No profiles yet";
//  * a rejected activation was an unhandled zone exception, so the button
//    silently did nothing;
//  * Duplicate reported "Duplicate profile failed: Bad state: ... was absent
//    from the refreshed profile list" for a duplicate that had succeeded (a
//    race against the Drift-stream-backed refresh);
//  * a profile saved without optics stored the model's `0` sentinel, the editor
//    rendered it as a literal `0`, and the shared validator then rejected every
//    subsequent save of that profile;
//  * the startup-default flag that Settings › General promises auto-connect
//    will use had no badge and no action anywhere.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/equipment_profiles_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const _rig = EquipmentProfileModel(
  id: 1,
  name: 'Audit Rig Alpha',
  focalLength: 530,
  aperture: 106,
  isActive: true,
  isDefault: true,
);

/// A profile created through "New Profile": optics unset, stored as the model's
/// `0` sentinel exactly as `createProfile` writes them.
const _blankOptics = EquipmentProfileModel(
  id: 1,
  name: 'Backup Test Rig',
  focalLength: 0,
  aperture: 0,
  isActive: true,
);

/// Profiles notifier whose authoritative list is driven by the test, including
/// the ability to hold a reload open (the desktop provider rebuilds off Drift
/// table streams, so a refresh really can complete from a pre-write snapshot).
class _FakeProfilesNotifier extends EquipmentProfilesNotifier {
  _FakeProfilesNotifier(this.profiles);

  List<EquipmentProfileModel> profiles;
  Completer<EquipmentProfilesState>? heldReload;
  Object? activationError;

  final saved = <EquipmentProfileModel>[];
  final activated = <int>[];
  final defaults = <({int? id, bool makeActive})>[];
  int duplicateCalls = 0;

  @override
  Future<EquipmentProfilesState> build() {
    final held = heldReload;
    if (held != null) return held.future;
    return Future.value(_snapshot());
  }

  EquipmentProfilesState _snapshot() {
    EquipmentProfileModel? active;
    for (final profile in profiles) {
      if (profile.isActive) active = profile;
    }
    return EquipmentProfilesState(profiles: profiles, activeProfile: active);
  }

  /// Publish the current [profiles] list as the authoritative state.
  void publish() {
    heldReload = null;
    ref.invalidateSelf();
  }

  @override
  Future<void> deleteProfile(int profileId) async {
    profiles = profiles.where((p) => p.id != profileId).toList();
    // Hold the reload so the screen keeps painting the pre-delete snapshot for
    // a frame, which is what resurrected the deleted row.
    heldReload = Completer<EquipmentProfilesState>();
    ref.invalidateSelf();
  }

  @override
  Future<void> setActiveProfile(int profileId) async {
    activated.add(profileId);
    final error = activationError;
    if (error != null) throw error;
  }

  @override
  Future<void> setDefaultProfile(int? profileId,
      {bool makeActive = true}) async {
    defaults.add((id: profileId, makeActive: makeActive));
  }

  @override
  Future<int> duplicateProfile(int sourceId, String newName) async {
    duplicateCalls++;
    // The write landed, but the refresh it schedules resolves from a snapshot
    // that does not carry the new row yet.
    ref.invalidateSelf();
    return 99;
  }

  @override
  Future<int> updateProfile(EquipmentProfileModel profile) async {
    saved.add(profile);
    profiles = [
      for (final p in profiles) p.id == profile.id ? profile : p,
    ];
    ref.invalidateSelf();
    return profile.id ?? 0;
  }
}

Future<_FakeProfilesNotifier> _pump(
  WidgetTester tester,
  List<EquipmentProfileModel> profiles,
) async {
  late _FakeProfilesNotifier notifier;
  await pumpAppScreen(
    tester,
    const EquipmentProfilesScreen(),
    size: const Size(1400, 1200),
    settle: false,
    extraOverrides: [
      equipmentProfilesProvider.overrideWith(() {
        notifier = _FakeProfilesNotifier(profiles);
        return notifier;
      }),
    ],
  );
  await tester.pump();
  await tester.pump();
  return notifier;
}

Future<void> _openOverflow(WidgetTester tester) async {
  final overflow = find.byType(PopupMenuButton<String>);
  expect(overflow, findsWidgets);
  await tester.tap(overflow.last);
  await tester.pumpAndSettle();
}

/// The editable field inside the [label]led field card.
Finder _fieldUnder(String label) => find.descendant(
      of: find
          .ancestor(of: find.text(label), matching: find.byType(Column))
          .first,
      matching: find.byType(TextField),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('deleting the last profile leaves no control over the dead row',
      (tester) async {
    final notifier = await _pump(tester, [_rig]);

    // The active profile auto-selects into the detail pane.
    expect(find.text('Duplicate'), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsWidgets);

    await _openOverflow(tester);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    // ConfirmDialog.delete
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    // The reload is still in flight: the screen is painting the pre-delete
    // snapshot and re-selects the (now deleted) active profile.
    await tester.pump();
    await tester.pump();

    // Reload lands with the row gone.
    notifier.publish();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('No profiles yet'), findsOneWidget);
    expect(
      find.text('Audit Rig Alpha'),
      findsNothing,
      reason: 'the deleted profile must not survive in the detail pane',
    );
    expect(find.text('Set active'), findsNothing);
    expect(find.text('Select a profile'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rejected activation is reported, not thrown into the log',
      (tester) async {
    final notifier = await _pump(tester, [
      const EquipmentProfileModel(id: 1, name: 'Rig One', isActive: true),
      const EquipmentProfileModel(id: 2, name: 'Rig Two'),
    ]);

    notifier.activationError =
        StateError('Cannot activate profile 2: no such profile row');

    await tester.tap(find.text('Rig Two'));
    await tester.pump();
    await tester.tap(find.text('Set active'));
    await tester.pump();
    await tester.pump();

    expect(notifier.activated, [2]);
    expect(tester.takeException(), isNull,
        reason: 'a failed activation must never be an unhandled exception');
    expect(find.textContaining('Could not activate "Rig Two"'), findsOneWidget);
  });

  testWidgets('a duplicate that lands one refresh late is not called a failure',
      (tester) async {
    final notifier = await _pump(tester, [_rig]);

    await _openOverflow(tester);
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate').last);
    await tester.pump();
    await tester.pump();

    expect(notifier.duplicateCalls, 1);
    expect(
      find.textContaining('Duplicate profile failed'),
      findsNothing,
      reason: 'the write succeeded; only the refresh was late',
    );
    expect(find.textContaining('absent from the refreshed'), findsNothing);

    // The row arrives on the next emission of the authoritative list.
    notifier.profiles = [
      ...notifier.profiles,
      const EquipmentProfileModel(id: 99, name: 'Audit Rig Alpha (Copy)'),
    ];
    notifier.publish();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Duplicate profile failed'), findsNothing);
    expect(find.text('Audit Rig Alpha (Copy)'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a profile stored without optics can still be edited and saved',
      (tester) async {
    final notifier = await _pump(tester, [_blankOptics]);

    await _openOverflow(tester);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    // The `0` sentinel must not be pre-loaded into a field the validator then
    // rejects.
    expect(
        tester.widget<TextField>(_fieldUnder('Focal Length')).controller!.text,
        isEmpty);
    expect(tester.widget<TextField>(_fieldUnder('Aperture')).controller!.text,
        isEmpty);

    await tester.enterText(find.byType(TextField).first, 'Local Work');
    final save = find.text('Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(notifier.saved, hasLength(1),
        reason: 'a name-only edit must reach the DAO');
    expect(notifier.saved.single.name, 'Local Work');
    expect(notifier.saved.single.focalLength, 0);
  });

  testWidgets('a rejected optic says why on the field itself', (tester) async {
    await _pump(tester, [_blankOptics]);

    await _openOverflow(tester);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(_fieldUnder('Focal Length'), '0');
    final save = find.text('Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();

    // Deliberately scoped to the field card: the summary snackbar carries the
    // same sentence, and on desktop it is drawn behind the persistent bottom
    // status bar, which is why the rejection read as a dead Save button.
    expect(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Focal Length'),
              matching: find.byType(Column),
            )
            .first,
        matching: find.text(
          'Focal length must be a positive number (leave blank if unknown)',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the startup default is visible and can be moved',
      (tester) async {
    final notifier = await _pump(tester, [
      _rig,
      const EquipmentProfileModel(id: 2, name: 'Rig Two'),
    ]);

    // The default row is labelled as such, separately from "Active".
    expect(find.text('Default'), findsOneWidget);

    await tester.tap(find.text('Rig Two'));
    await tester.pump();
    await _openOverflow(tester);
    await tester.tap(find.text('Set as default'));
    await tester.pumpAndSettle();

    expect(notifier.defaults, hasLength(1));
    expect(notifier.defaults.single.id, 2);
    expect(
      notifier.defaults.single.makeActive,
      isFalse,
      reason: 'the startup default is a separate flag from the active profile',
    );
  });
}

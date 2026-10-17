// FilterInProfileRule has to be WIRED, not merely written.
//
// The rule's own unit test calls `FilterInProfileRule().validate(...)`
// directly, so the entire production registration in
// `defaultRefAwareSequenceValidators` could be deleted with that file still
// green. These tests drive `liveValidationProvider` — the provider the
// builder's header badge and issues dialog actually read — so they fail if
// the rule is unregistered.
//
// The second test covers the input the live notifier was NOT listening to:
// the active equipment profile. Fixing the profile has to clear the warning,
// otherwise the badge cries wolf about a name the operator already added.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

/// Test-controllable stand-in for the active equipment profile.
final _profileFilters = StateProvider<List<String>>((_) => const ['L', 'R']);

Sequence _sequenceWithFilter(String filter) {
  final root = InstructionSetNode(id: 'root', name: 'Root');
  final exposure = ExposureNode(
    id: 'ex',
    name: 'Lights',
    durationSecs: 120,
    filter: filter,
  );
  return Sequence.create(
    id: 'seq',
    name: 'Tonight',
    nodes: {
      exposure.id: exposure.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [exposure.id]),
    },
    rootNodeId: root.id,
  );
}

List<Override> _overrides() {
  final editor = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  editor.state = _sequenceWithFilter('Ha');
  return [
    currentSequenceProvider.overrideWith((_) => editor),
    sequenceExecutionStateProvider
        .overrideWith((ref) => SequenceExecutionState.idle),
    activeEquipmentProfileProvider.overrideWith(
      (ref) => EquipmentProfileModel(
        name: 'Test Rig',
        focalLength: 600,
        aperture: 80,
        filterNames: ref.watch(_profileFilters),
      ),
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a filter name absent from the profile reaches the live badge',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SizedBox.shrink(),
      extraOverrides: _overrides(),
      settle: false,
    );
    // Reading creates the notifier, which starts its 500 ms debounce; the
    // pump below has to happen after that or nothing has validated yet.
    handle.container.read(liveValidationProvider);
    await tester.pump(const Duration(milliseconds: 800));

    final issues = handle.container.read(liveValidationProvider).issues;
    expect(
      issues.where((i) => i.title == 'Filter Not in Profile'),
      hasLength(1),
      reason: 'FilterInProfileRule is not registered in the live rule stack',
    );
  });

  testWidgets('adding the filter to the profile clears the warning',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SizedBox.shrink(),
      extraOverrides: _overrides(),
      settle: false,
    );
    // Reading creates the notifier, which starts its 500 ms debounce; the
    // pump below has to happen after that or nothing has validated yet.
    handle.container.read(liveValidationProvider);
    await tester.pump(const Duration(milliseconds: 800));
    expect(
      handle.container
          .read(liveValidationProvider)
          .issues
          .where((i) => i.title == 'Filter Not in Profile'),
      hasLength(1),
    );

    // The operator goes to Equipment and adds the filter they really own.
    handle.container.read(_profileFilters.notifier).state = const [
      'L',
      'R',
      'Ha',
    ];
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(
      handle.container
          .read(liveValidationProvider)
          .issues
          .where((i) => i.title == 'Filter Not in Profile'),
      isEmpty,
      reason: 'live validation does not listen to the equipment profile, so '
          'the badge keeps warning about a filter the profile now lists',
    );
  });
}

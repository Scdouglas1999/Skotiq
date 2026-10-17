// Regression coverage for the cockpit Start affordance while the app has no
// backend that can actually accept a run command.
//
// The live-Android audit observed the Start control rendered enabled, beside
// the copy "Sequence ready — start tonight's run." and a "Ready" badge, while
// the host was unreachable. Per the campaign's defect class (the app stating
// something untrue) a control that cannot possibly work must not present
// itself as ready.
//
// These tests inspect the widget tree's `onTap` nullability rather than
// tapping the live control, so the verdict is about what the widget OFFERS,
// not about what a tap happens to do.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_run_controls.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

class _SeedingNotifier extends CurrentSequenceNotifier {
  _SeedingNotifier(Ref ref) : super(ref: ref) {
    loadSequence(_launchableSequence(), discardUnsaved: true);
  }
}

/// A sequence with a target AND exposures — i.e. "launchable" by the widget's
/// own definition, so the Start branch is the one under test.
Sequence _launchableSequence() {
  final target = TargetHeaderNode(
    id: 'target-1',
    name: 'Test Target',
    targetName: 'Test Target',
    raHours: 12,
    decDegrees: 20,
  );
  final exposure = ExposureNode(
    id: 'exp-1',
    name: 'Lights',
    parentId: target.id,
    durationSecs: 60,
    count: 5,
  );
  return Sequence.create(
    name: 'Offline Start Test',
    nodes: {
      target.id: target.copyWith(childIds: [exposure.id]),
      exposure.id: exposure,
    },
    rootNodeId: target.id,
  );
}

Future<void> _pump(
  WidgetTester tester,
  SkotiqBackend backend,
) async {
  tester.view.devicePixelRatio = 1;
  // The 1080x2400 phone the audit ran on, in logical pixels.
  tester.view.physicalSize = const Size(1080, 2400);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, backend),
        ),
        currentSequenceProvider.overrideWith(_SeedingNotifier.new),
        sequenceExecutionStateProvider.overrideWith(
          (ref) => SequenceExecutionState.idle,
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: CockpitRunControls(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The `onTap` of the InkWell backing the labelled control, or null when the
/// control is presented as disabled.
VoidCallback? _onTapFor(WidgetTester tester, String label) {
  final inkWell = tester.widget<InkWell>(
    find.ancestor(
      of: find.text(label),
      matching: find.byType(InkWell),
    ),
  );
  return inkWell.onTap;
}

void main() {
  testWidgets(
    'Start is NOT offered as actionable when no backend can command a run',
    (tester) async {
      await _pump(tester, DisconnectedBackend());

      // The control must not advertise itself as tappable.
      expect(
        _onTapFor(tester, 'Start'),
        isNull,
        reason: 'Start must not be actionable with no reachable host',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'copy does not claim readiness while no backend can command a run',
    (tester) async {
      await _pump(tester, DisconnectedBackend());

      // The copy must not assert a readiness the system does not have.
      expect(find.text('Sequence ready — start tonight’s run.'), findsNothing);
      expect(find.text('Ready'), findsNothing);
      // …and it must say why instead.
      expect(find.textContaining('reconnect'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
    },
  );

  testWidgets(
    'Start IS actionable and reads Ready on a local (FFI/host) backend',
    (tester) async {
      await _pump(tester, FfiBackend());

      expect(
        _onTapFor(tester, 'Start'),
        isNotNull,
        reason: 'the local host must keep a working Start',
      );
      expect(
          find.text('Sequence ready — start tonight’s run.'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

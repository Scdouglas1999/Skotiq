// What the Analytics session dialog's header publishes to assistive tech.
//
// The header is seven icon-only buttons — review, refine, report, three
// exports and close — and an icon has no text for a screen reader to read.
// Driving the release build through AT-SPI, all seven came out as buttons with
// an EMPTY accessible name: seven anonymous controls in a row, indistinguishable
// from each other and unreachable by name.
//
// The trap this test pins down is the fix that looks right and is not: wrapping
// a Material [IconButton] in `Semantics(label: …)` does NOT name the button.
// `ButtonStyleButton` wraps itself in `Semantics(container: true, …)`, so the
// enclosing annotation cannot merge into it — it forms a SECOND node above the
// button, and what ships is a named node carrying no tap action sitting over a
// nameless node that carries the action. The name has to go inside the button's
// own node, which is what `Icon.semanticLabel` does.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _PinnedBackend extends BackendNotifier {
  _PinnedBackend(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'NoopTutorialProgressDao.${invocation.memberName} called in test',
      );
}

/// A night that HAS a master, so all seven controls are live.
///
/// The Darkroom action is disabled with its reason on a night with nothing to
/// open — that rule has its own file. This one is about what a live control
/// publishes, so it is given a live one.
class _OneMasterResolver implements DawnMasterResolver {
  @override
  Future<DawnMasterSet> resolve(int sessionId) async => DawnMasterSet(
        sessionId: sessionId,
        masters: const [
          DawnMaster(
            masterId: 9,
            targetId: 1,
            name: 'M31 Ha',
            filter: 'Ha',
            masterFitsPath: '/masters/m31_ha.fits',
            channels: 1,
            width: 4000,
            height: 3000,
            frameCount: 40,
            totalIntegrationSeconds: 12000,
          ),
        ],
        withoutFile: const [],
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openDialog(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final session = ImagingSession(
      id: 5,
      name: 'Night A - M31',
      startTime: DateTime(2026, 7, 30),
      totalExposures: 12,
      successfulExposures: 12,
      failedExposures: 0,
      totalIntegrationSecs: 1440,
      autofocusCount: 0,
      status: 'completed',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _PinnedBackend(ref, DisconnectedBackend()),
          ),
          allSessionsProvider.overrideWith(
            (ref) => Stream<List<ImagingSession>>.value([session]),
          ),
          standaloneImagesProvider.overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
          allDbImagesProvider.overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
          dbSessionImagesProvider(5).overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
          tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
          dawnMasterResolverProvider.overrideWithValue(_OneMasterResolver()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: AnalyticsScreen(initialTab: AnalyticsTab.history),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Night A - M31'));
    // pump, not pumpAndSettle: the thumbnail futures never go idle locally.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('every header action publishes a name, a role and its tap', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await openDialog(tester);

    final buttons = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(SkotiqIconButton),
    );
    // Review, refine, report, JSON, CSV, HTML report, close. The share button
    // exists only on Android/iOS, and this runs on the host.
    expect(buttons, findsNWidgets(7));

    final names = <String>[];
    for (var i = 0; i < 7; i++) {
      final node = tester.getSemantics(buttons.at(i));
      final data = node.getSemanticsData();
      expect(
        data.label,
        isNotEmpty,
        reason: 'header action $i publishes no accessible name',
      );
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
      expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
      // The name and the action on ONE node. A split publishes the name on a
      // node that cannot be activated.
      expect(
        data.hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'the node carrying the name for action $i carries no tap',
      );
      names.add(data.label);
    }

    expect(names, [
      'Review & integrate',
      'Refine in Darkroom',
      'Session report',
      'Export to JSON',
      'Export to CSV',
      'Export HTML report',
      'Close',
    ]);
    // Every action is distinguishable from every other one by name alone.
    expect(names.toSet(), hasLength(7));
    handle.dispose();
  });

  testWidgets('no anonymous button is left in the dialog', (tester) async {
    final handle = tester.ensureSemantics();
    await openDialog(tester);

    final anonymous = <String>[];
    void walk(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.hasFlag(SemanticsFlag.isButton) &&
          data.hasAction(SemanticsAction.tap) &&
          data.label.isEmpty &&
          data.tooltip.isEmpty) {
        anonymous.add('${node.id} @ ${node.rect}');
      }
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    walk(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    expect(
      anonymous,
      isEmpty,
      reason: 'these actionable buttons announce nothing at all',
    );
    handle.dispose();
  });
}

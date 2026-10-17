// The Analytics session dialog's header at the widths it is actually opened at.
//
// Two defects lived here, and both are about a control the app claims to offer
// and does not:
//
//  * the action cluster was a horizontally scrolling Row, so at phone width the
//    first three icons — "Review & integrate", "Refine in Darkroom" and
//    "Session Report" — were clipped away while the accessibility tree went on
//    advertising all seven, and a tap where one used to be landed on nothing;
//  * the Darkroom refusal was posted to the page's ScaffoldMessenger while the
//    dialog deliberately stayed up to carry it, so the modal route painted over
//    the SnackBar and the operator read half a sentence, or two words of it.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockImagesDao extends Mock implements ImagesDao {}

class _MockIntegratedMastersDao extends Mock implements IntegratedMastersDao {}

/// A night that has a master when the header is BUILT and none by the time the
/// operator presses.
///
/// The refusal itself now lives on the control — a night with no master is
/// disabled with its reason before anybody reaches for it, and that rule is
/// pinned in `session_detail_darkroom_test.dart`. What is left for the
/// after-press path is exactly this: the window between the read the control
/// was drawn from and the press, which a deleted master or a re-run
/// integration can change. That is the case this file drives, because it is
/// the only remaining way an inline refusal is produced.
class _VanishingMasterResolver extends DawnMasterResolver {
  _VanishingMasterResolver()
      : super(images: _MockImagesDao(), masters: _MockIntegratedMastersDao());

  int calls = 0;

  @override
  Future<DawnMasterSet> resolve(int sessionId) async {
    final first = calls++ == 0;
    return DawnMasterSet(
      sessionId: sessionId,
      masters: first
          ? const [
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
            ]
          : const [],
      withoutFile: const [],
    );
  }
}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openDialog(WidgetTester tester, {required Size window}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = window;
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
          dawnMasterResolverProvider
              .overrideWithValue(_VanishingMasterResolver()),
          // The Session Report action opens a dialog over this one and watches
          // this. Scripted so the tap reaches no database: what is under test
          // is what the press does to the alert BELOW the report, not the
          // report.
          sessionReportProvider(5).overrideWith(
            (ref) => throw StateError('no session report in this test'),
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

  /// Every named, tappable control the semantics tree currently publishes.
  List<String> tappableNames(WidgetTester tester) {
    final names = <String>[];
    void walk(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.hasFlag(SemanticsFlag.isButton) &&
          data.hasAction(SemanticsAction.tap) &&
          data.label.isNotEmpty) {
        names.add(data.label);
      }
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    walk(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    return names;
  }

  testWidgets('a laptop-width dialog keeps every action inline', (
    tester,
  ) async {
    await openDialog(tester, window: const Size(1400, 900));

    expect(
      find.byKey(const ValueKey('session_detail_actions_menu')),
      findsNothing,
      reason: 'there is room for the icons, so nothing folds',
    );
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(SkotiqIconButton),
      ),
      findsNWidgets(7),
      reason: 'six actions plus the close button',
    );
    expect(
      find.byKey(const ValueKey('session_detail_darkroom')),
      findsOneWidget,
    );
  });

  testWidgets('at phone width the cluster folds and the tree follows it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await openDialog(tester, window: const Size(430, 900));

    // What paints: one overflow button and the close.
    expect(
      find.byKey(const ValueKey('session_detail_actions_menu')),
      findsOneWidget,
    );
    // One SkotiqIconButton (close). The overflow menu beside it is a
    // PopupMenuButton, which used to be counted here only because Material
    // renders one THROUGH an IconButton; the sheet's icon button does not.
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(SkotiqIconButton),
      ),
      findsOneWidget,
    );

    // What the tree says: exactly the same two, and NOT the six that used to be
    // announced from inside a clipped scroll view.
    final announced = tappableNames(tester);
    expect(announced, contains('Session actions'));
    expect(announced, contains('Close'));
    expect(announced, isNot(contains('Refine in Darkroom')));
    expect(announced, isNot(contains('Review & integrate')));
    expect(announced, isNot(contains('Session report')));

    // And every one of them is reachable once the menu is open.
    await tester.tap(find.byKey(const ValueKey('session_detail_actions_menu')));
    // pump, not pumpAndSettle: the dialog behind the menu holds thumbnail
    // futures that never go idle here.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    for (final label in const [
      'Review & integrate',
      'Refine in Darkroom',
      'Session report',
      'Export to JSON',
      'Export to CSV',
      'Export HTML report',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label is unreachable');
    }
    handle.dispose();
  });

  testWidgets('the Darkroom refusal renders inside the dialog that carries it',
      (tester) async {
    await openDialog(tester, window: const Size(1100, 800));

    await tester.tap(find.byKey(const ValueKey('session_detail_darkroom')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    const reason = 'This session has no integrated master yet. Integrate it in '
        'Session Review first, then refine it here.';
    // Inside the dialog subtree — not in the page's ScaffoldMessenger, which
    // this modal route paints over.
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text(reason),
      ),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
    expect(
      find.byType(Dialog),
      findsOneWidget,
      reason: 'the dialog stays up to carry the explanation',
    );

    // And the control catches up with the sentence under it. Left as it was,
    // the header would go on offering an action the alert beneath it has just
    // said cannot run — two claims about one night on one screen.
    expect(
      tester
          .widget<SkotiqIconButton>(
              find.byKey(const ValueKey('session_detail_darkroom')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<SkotiqIconButton>(
              find.byKey(const ValueKey('session_detail_darkroom')))
          .tooltip,
      reason,
    );

    // It is dismissible, and dismissing it leaves the dialog behind.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('session_detail_refusal')),
        matching: findIconButtonByTooltip('Dismiss'),
      ),
    );
    await tester.pump();
    expect(find.text(reason), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
  });

  testWidgets('a standing refusal does not outlive the next press',
      (tester) async {
    await openDialog(tester, window: const Size(1100, 800));

    await tester.tap(find.byKey(const ValueKey('session_detail_darkroom')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byKey(const ValueKey('session_detail_refusal')),
      findsOneWidget,
    );

    // A different action: whatever it goes on to do, the sentence about the
    // last one has stopped describing anything on screen. Session Report is
    // the one action that neither dismisses this dialog nor writes a file —
    // it opens a second dialog over it whose own data is an AsyncValue.
    await tester.tap(findIconButtonByTooltip('Session report'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('session_detail_refusal')), findsNothing);
  });
}

/// Finds a [SkotiqIconButton] by the tooltip it publishes.
///
/// `find.byTooltip` cannot: SkotiqIconButton draws its own overlay tooltip
/// rather than wrapping a Material [Tooltip]. The string is still the button's
/// Semantics label, so this is the same contract read from the widget.
Finder findIconButtonByTooltip(String tooltip) => find.byWidgetPredicate(
      (widget) => widget is SkotiqIconButton && widget.tooltip == tooltip,
      description: 'SkotiqIconButton(tooltip: "$tooltip")',
    );

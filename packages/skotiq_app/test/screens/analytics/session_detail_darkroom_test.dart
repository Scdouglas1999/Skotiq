// The Analytics session dialog's ways into the Darkroom and Session Review.
//
// The dialog is where an operator looks at a night days later, which is exactly
// when "open this in the Darkroom" is worth having. Both controls share one
// host-only gate: the recipes, the linear masters, the full-resolution subs and
// their pixels all live on the imaging computer.
//
// The gate is the client ROLE. Asked as `backend is NetworkBackend` it was a
// CONNECTION fact, which reads false for the whole life of a `--remote-host`
// launch before its first handshake — and in that window the dialog kept its
// host-capable labels and "Review & integrate" navigated onto the Session
// Review host-only wall instead of refusing. That case is the third test here.
//
// WHERE THE REFUSAL IS READ. These assertions go through the published
// SEMANTICS NODE, not through `Icon.semanticLabel` and not through `tooltip:`.
// An earlier version of this file checked the widget properties and passed
// while the refusal reached nobody but a mouse: Flutter publishes `tooltip:` as
// `SemanticsProperties.tooltip`, the Linux AT-SPI bridge does not fold that
// into the accessible name, and the header buttons are icon-only — so a screen
// reader was handed `Refine on imaging host [DISABLED]` with no reason and
// there was no visible reason either. The node's `label` is the one string
// every reader is given, so it is the one this file asserts on.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_app/utils/darkroom_navigation.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

/// A resolver that answers with a scripted set instead of reading a database.
///
/// The real one is overridden rather than the provider that wraps it, so these
/// tests run the same resolution the control and the press both go through.
class _ScriptedResolver implements DawnMasterResolver {
  _ScriptedResolver(this.set, {this.delay});

  final DawnMasterSet set;

  /// How long the read takes. Non-null holds the control in the state it is in
  /// while the masters are being read, which is its own answer.
  final Duration? delay;

  @override
  Future<DawnMasterSet> resolve(int sessionId) async {
    final wait = delay;
    if (wait != null) await Future<void>.delayed(wait);
    return set;
  }
}

DawnMasterSet _oneMaster() => const DawnMasterSet(
      sessionId: 5,
      masters: [
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
      withoutFile: [],
    );

DawnMasterSet _noMaster() =>
    const DawnMasterSet(sessionId: 5, masters: [], withoutFile: []);

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

  Future<void> openDialog(
    WidgetTester tester, {
    required SkotiqBackend backend,
    bool launchedAsRemoteClient = false,
    Size size = const Size(1400, 900),
    DawnMasterResolver? resolver,
    int pumps = 8,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
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
          backendProvider.overrideWith((ref) => _PinnedBackend(ref, backend)),
          remoteClientLaunchProvider.overrideWithValue(launchedAsRemoteClient),
          allSessionsProvider.overrideWith(
            (ref) => Stream<List<ImagingSession>>.value([session]),
          ),
          standaloneImagesProvider.overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
          allDbImagesProvider.overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
          dbSessionImagesProvider(
            5,
          ).overrideWith(
              (ref) => Stream<List<DbCapturedImage>>.value(const [])),
          tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
          dawnMasterResolverProvider.overrideWithValue(
            resolver ?? _ScriptedResolver(_oneMaster()),
          ),
        ],
        child: const MaterialApp(
          home:
              Scaffold(body: AnalyticsScreen(initialTab: AnalyticsTab.history)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Night A - M31'));
    // pump, not pumpAndSettle: the thumbnail futures never go idle locally.
    for (var i = 0; i < pumps; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The name the control actually PUBLISHES: the label on the semantics node
  /// a reader is handed, whichever widget in the subtree contributed it.
  ///
  /// Deliberately not `Icon.semanticLabel` or `IconButton.tooltip`. Those are
  /// authoring inputs; only one of them ends up in the node's name, and the
  /// tooltip is not it.
  String publishedNameOf(WidgetTester tester, Finder button) =>
      tester.getSemantics(button).label;

  /// Every non-empty name in the published tree, read the way the AT-SPI
  /// bridge reads it: off the semantics nodes, including the ones a popup
  /// route puts in the overlay rather than in the dialog's own subtree.
  List<String> publishedNames(WidgetTester tester) {
    final names = <String>[];
    void walk(SemanticsNode node) {
      final label = node.getSemanticsData().label;
      if (label.isNotEmpty) names.add(label);
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    walk(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    return names;
  }

  testWidgets('the host dialog offers both actions, live', (tester) async {
    // Without this the semantics tree is never built and every `label`
    // assertion below reads an empty string, which passes nothing. Disposed by
    // hand rather than in a tearDown: the handle is verified before those run.
    final handle = tester.ensureSemantics();
    await openDialog(tester, backend: DisconnectedBackend());

    for (final entry in {
      'session_detail_darkroom': 'Refine in Darkroom',
      'session_detail_review': 'Review & integrate',
    }.entries) {
      final button = find.byKey(ValueKey(entry.key));
      expect(button, findsOneWidget);
      expect(tester.widget<SkotiqIconButton>(button).tooltip, entry.value);
      expect(publishedNameOf(tester, button), entry.value);
      expect(tester.widget<SkotiqIconButton>(button).onPressed, isNotNull);
    }
    handle.dispose();
  });

  testWidgets('a connected remote client is refused on both controls',
      (tester) async {
    final handle = tester.ensureSemantics();
    await openDialog(tester, backend: _MockNetworkBackend());

    final darkroom = find.byKey(const ValueKey('session_detail_darkroom'));
    expect(
      publishedNameOf(tester, darkroom),
      unavailableControlName(
        'Refine on imaging host',
        kDarkroomHostOnlyRefusal,
      ),
      reason: 'carried as a tooltip alone the reason reached a pointer and '
          'nobody else — these buttons are icon-only, so the name is the only '
          'place left to read it',
    );
    // One node, and it states the refusal rather than leaving it to be
    // inferred from a control that simply does not respond.
    final data = tester.getSemantics(darkroom).getSemanticsData();
    expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(data.hasFlag(SemanticsFlag.isEnabled), isFalse);
    expect(
      tester.widget<SkotiqIconButton>(darkroom).tooltip,
      kDarkroomHostOnlyRefusal,
      reason: 'the pointer keeps the tooltip it already had',
    );
    expect(tester.widget<SkotiqIconButton>(darkroom).onPressed, isNull);

    // Session Review's refusal is the dialog's own sentence, so it is matched
    // by shape rather than by importing a private constant.
    final reviewName = publishedNameOf(
      tester,
      find.byKey(const ValueKey('session_detail_review')),
    );
    expect(reviewName, startsWith('Review on imaging host — '));
    expect(reviewName, contains('Session Review works on the imaging host'));
    expect(
      tester
          .widget<SkotiqIconButton>(
              find.byKey(const ValueKey('session_detail_review')))
          .onPressed,
      isNull,
    );
    handle.dispose();
  });

  testWidgets('the folded header states the refusal in the row\'s own name',
      (tester) async {
    // Below the width where the action cluster and a readable title both fit,
    // the buttons become menu rows — and a popup row has no tooltip hung on
    // it, so the folded header was the one place the reason existed nowhere at
    // all.
    final handle = tester.ensureSemantics();
    await openDialog(
      tester,
      backend: _MockNetworkBackend(),
      size: const Size(560, 900),
    );

    final menu = find.byKey(const ValueKey('session_detail_actions_menu'));
    expect(menu, findsOneWidget, reason: 'the header folded');
    await tester.tap(menu);
    // Twice: the menu's own route has to be pushed and then its opening
    // animation run before the rows carry anything.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      publishedNames(tester),
      contains(
        unavailableControlName(
          'Refine on imaging host',
          kDarkroomHostOnlyRefusal,
        ),
      ),
      reason: 'a popup row has no tooltip to hang the sentence on, so the '
          'folded header stated the refusal nowhere at all',
    );
    handle.dispose();
  });

  testWidgets(
      'a client that has not reached its rig is refused too, and Review does '
      'not navigate', (tester) async {
    // The pre-handshake window: launched with `--remote-host`, backend still
    // Disconnected. `backend is NetworkBackend` reads FALSE here, which is
    // exactly why the question has to be the role.
    final handle = tester.ensureSemantics();
    await openDialog(
      tester,
      backend: DisconnectedBackend(),
      launchedAsRemoteClient: true,
    );

    final darkroom = find.byKey(const ValueKey('session_detail_darkroom'));
    expect(
      publishedNameOf(tester, darkroom),
      unavailableControlName(
        'Refine on imaging host',
        kDarkroomHostOnlyRefusal,
      ),
    );
    expect(tester.widget<SkotiqIconButton>(darkroom).onPressed, isNull);

    final review = find.byKey(const ValueKey('session_detail_review'));
    expect(
      publishedNameOf(tester, review),
      startsWith('Review on imaging host — '),
    );
    expect(
      tester.widget<SkotiqIconButton>(review).onPressed,
      isNull,
      reason: 'pressing it popped the dialog and landed on the Session Review '
          'host-only wall',
    );

    await tester.tap(review, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('session_detail_review')),
      findsOneWidget,
      reason: 'a disabled action leaves the dialog up rather than navigating',
    );
    handle.dispose();
  });

  // The ROLE was answered on the control; the MASTER was answered only inside
  // the tap handler. Measured on a night whose two frames were both rejected:
  // the tree read `button: Refine in Darkroom` at full contrast with no
  // [DISABLED] and no reason anywhere, and the sentence explaining that there
  // is nothing to open arrived after the press. One predicate short of the
  // shape this dialog's remote refusal already has.
  testWidgets('a night with no master refuses on the control, not after it',
      (tester) async {
    final handle = tester.ensureSemantics();
    await openDialog(
      tester,
      backend: DisconnectedBackend(),
      resolver: _ScriptedResolver(_noMaster()),
    );

    const reason = 'This session has no integrated master yet. Integrate it '
        'in Session Review first, then refine it here.';
    final darkroom = find.byKey(const ValueKey('session_detail_darkroom'));
    expect(
      publishedNameOf(tester, darkroom),
      unavailableControlName('Refine in Darkroom', reason),
      reason: 'the label keeps its own name — this machine IS the host, the '
          'night simply has nothing to open',
    );
    expect(tester.widget<SkotiqIconButton>(darkroom).onPressed, isNull);
    expect(tester.widget<SkotiqIconButton>(darkroom).tooltip, reason);

    final data = tester.getSemantics(darkroom).getSemanticsData();
    expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(data.hasFlag(SemanticsFlag.isEnabled), isFalse);

    // Review & integrate is the way OUT of this state, so it stays live.
    expect(
      tester
          .widget<SkotiqIconButton>(
              find.byKey(const ValueKey('session_detail_review')))
          .onPressed,
      isNotNull,
    );
    handle.dispose();
  });

  testWidgets('a night whose masters are still being read is not offered yet',
      (tester) async {
    // "Not yet known" is not "available": a control enabled on the way to an
    // answer is live for exactly as long as it takes to press it wrongly.
    final handle = tester.ensureSemantics();
    await openDialog(
      tester,
      backend: DisconnectedBackend(),
      resolver: _ScriptedResolver(
        _oneMaster(),
        delay: const Duration(seconds: 5),
      ),
      pumps: 2,
    );

    final darkroom = find.byKey(const ValueKey('session_detail_darkroom'));
    expect(
      publishedNameOf(tester, darkroom),
      unavailableControlName(
        'Refine in Darkroom',
        kDarkroomMastersReadingReason,
      ),
    );
    expect(tester.widget<SkotiqIconButton>(darkroom).onPressed, isNull);

    // And it comes live on its own once the read lands.
    await tester.pump(const Duration(seconds: 6));
    expect(publishedNameOf(tester, darkroom), 'Refine in Darkroom');
    expect(tester.widget<SkotiqIconButton>(darkroom).onPressed, isNotNull);
    handle.dispose();
  });

  testWidgets('a night with a master keeps a live control', (tester) async {
    final handle = tester.ensureSemantics();
    await openDialog(
      tester,
      backend: DisconnectedBackend(),
      resolver: _ScriptedResolver(_oneMaster()),
    );

    final darkroom = find.byKey(const ValueKey('session_detail_darkroom'));
    expect(publishedNameOf(tester, darkroom), 'Refine in Darkroom');
    expect(tester.widget<SkotiqIconButton>(darkroom).onPressed, isNotNull);
    handle.dispose();
  });
}

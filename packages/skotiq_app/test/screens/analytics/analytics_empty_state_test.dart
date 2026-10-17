// The Analytics tabs must present ONE empty state, and Diagnostics must not be
// the one tab with a page title and an essay.
//
// Left unpinned they drift: Session centred with a full stop, History with no
// stops, Projects left-aligned with two, Equipment Stats with no empty state at
// all, Diagnostics with a star glyph — four structures, two punctuation rules,
// and not one of the five offering an action, plus a Diagnostics H1 ("Optical
// Train Diagnostics") and a ~95-word paragraph none of its siblings carry.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_app/screens/analytics/widgets/analytics_empty_state.dart';
import 'package:skotiq_app/screens/diagnostics/diagnostics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao());

  @override
  // ignore: invalid_use_of_protected_member
  TutorialProgress get state => const TutorialProgress(tutorialsEnabled: false);
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A session whose PSF field measured cleanly, so Diagnostics reaches its
/// DATA branch — the health grade card with its two score bars — rather than
/// the "pick a session" empty state.
const int _measuredSessionId = 7;

class _MeasuredSession extends SessionStateNotifier {
  _MeasuredSession(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const SessionState(isActive: true, dbSessionId: _measuredSessionId);
  }
}

ImagingSession _measuredImagingSession() => ImagingSession(
      id: _measuredSessionId,
      name: 'Night G - M31',
      startTime: DateTime.utc(2026, 9, 9, 21),
      totalExposures: 60,
      successfulExposures: 60,
      failedExposures: 0,
      totalIntegrationSecs: 1800,
      autofocusCount: 0,
      status: 'completed',
    );

/// A flat, well-behaved field: nine tiles at the same low eccentricity. Real
/// rows through the real `OpticalTrainDiagnosticsService`, so the card under
/// test renders a grade it actually earned.
PsfFieldTileRow _measuredTile(int index) => PsfFieldTileRow(
      id: index + 1,
      capturedImageId: 1,
      sessionId: _measuredSessionId,
      tileRow: index ~/ 3,
      tileCol: index % 3,
      starCount: 40,
      medianFwhm: 3.0,
      medianHfr: 1.5,
      medianEccentricity: 0.20,
      roundness: 0.9,
      timestamp: DateTime.utc(2026, 9, 9, 22),
    );

Widget _host(Widget child, {List<Override> extraOverrides = const []}) =>
    ProviderScope(
      overrides: [
        standaloneImagesProvider
            .overrideWith((ref) => Stream.value(const <DbCapturedImage>[])),
        allDbImagesProvider
            .overrideWith((ref) => Stream.value(const <DbCapturedImage>[])),
        allSessionsProvider
            .overrideWith((ref) => Stream.value(const <ImagingSession>[])),
        tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
        ...extraOverrides,
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: child),
      ),
    );

/// Drives the Diagnostics data branch: one completed session, selected, with
/// nine PSF tiles behind it.
List<Override> _measuredDiagnosticsOverrides() => [
      allSessionsProvider.overrideWith(
        (ref) =>
            Stream<List<ImagingSession>>.value([_measuredImagingSession()]),
      ),
      sessionStateProvider.overrideWith((ref) => _MeasuredSession(ref)),
      sessionPsfTilesProvider.overrideWith(
        (ref, id) =>
            Stream.value([for (var i = 0; i < 9; i++) _measuredTile(i)]),
      ),
      sessionResidualVectorsProvider.overrideWith(
        (ref, id) => Stream.value(const <AstrometryResidualVectorRow>[]),
      ),
    ];

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 900);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  group('AnalyticsEmptyState', () {
    testWidgets('states one sentence, labels the title, and offers an action',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const AnalyticsEmptyState(
            icon: Icons.folder_open,
            // Both halves deliberately wrong: a title punctuated as a sentence
            // and a body with no terminal stop. The widget is the one place
            // that rule lives, so translations cannot reintroduce the split.
            title: 'No session history.',
            body: 'Complete an imaging session to see history here',
          ),
        ),
      );

      expect(find.text('No session history'), findsOneWidget);
      expect(
        find.text('Complete an imaging session to see history here.'),
        findsOneWidget,
      );
      // The action is the sheet's own button now (05 §12: an empty state
      // ends in ONE button), not a bare Material TextButton.
      expect(find.byType(SkotiqButton), findsOneWidget);
    });

    testWidgets('does not double-punctuate a body that is already a sentence',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const AnalyticsEmptyState(
            icon: Icons.folder_open,
            title: 'Nothing captured yet',
            body: 'Start a capture and this tab fills in.',
          ),
        ),
      );

      expect(
        find.text('Start a capture and this tab fills in.'),
        findsOneWidget,
      );
    });
  });

  testWidgets('the Session tab renders the shared widget, with its action',
      (tester) async {
    await tester.pumpWidget(_host(
      const AnalyticsScreen(initialTab: AnalyticsTab.session),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(AnalyticsEmptyState), findsOneWidget);
    // Every tab's empty state offers an action.
    expect(find.text('Go to Imaging'), findsOneWidget);
  });

  // The other four tabs need a live database to reach their empty branch at
  // all (run stats, project progress, sessionless PSF tiles), so the pin that
  // they share the one widget is structural. Both halves matter: five call
  // sites using it, and no call site keeping a hand-rolled column.
  test('all five Analytics empty states go through AnalyticsEmptyState', () {
    const sites = <String, String>{
      'Session': 'lib/screens/analytics/analytics_screen/session_tab.dart',
      'History': 'lib/screens/analytics/analytics_screen/history_tab.dart',
      'Projects': 'lib/screens/analytics/widgets/project_tracking_panel.dart',
      'Equipment Stats':
          'lib/screens/analytics/analytics_screen/equipment_stats.dart',
      'Diagnostics': 'lib/screens/diagnostics/diagnostics_screen.dart',
    };
    final missing = <String>[];
    sites.forEach((tab, path) {
      final file = File(path);
      if (!file.existsSync() ||
          !file.readAsStringSync().contains('AnalyticsEmptyState(')) {
        missing.add('$tab ($path)');
      }
    });
    expect(
      missing,
      isEmpty,
      reason: 'these tabs still hand-roll an empty state: '
          '${missing.join(', ')}',
    );
  });

  group('Diagnostics chrome', () {
    testWidgets('the Analytics tab prints no page title and no essay',
        (tester) async {
      await tester.pumpWidget(_host(const DiagnosticsTabContent()));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text('Optical train diagnostics'),
        findsNothing,
        reason: 'the tab strip two rows above already names this tab, and no '
            'sibling tab prints an H1',
      );
      expect(
        find.textContaining('Analytics tracks per-frame image quality'),
        findsNothing,
        reason: 'the scope contrast belongs in the guide the chip opens',
      );
      // The score-direction legend is NOT page chrome and must not come back
      // as a subtitle here — it belongs to the card whose numbers it reads,
      // which the next test pins.
      expect(
        find.textContaining('Lower scores are better.'),
        findsNothing,
        reason: 'a legend printed above an empty state labels nothing',
      );
    });

    testWidgets('a measured session still says which direction is good',
        (tester) async {
      // The one line worth keeping off the old explainer paragraph. It rides
      // on the health grade card, directly above the two bars whose figures it
      // reads, so it appears exactly when there are scores to read — and it
      // says SCORES, because the figure at the end of each bar is the reading
      // and the bar is the decoration.
      await tester.pumpWidget(
        _host(
          const DiagnosticsTabContent(),
          extraOverrides: _measuredDiagnosticsOverrides(),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Optical Health'), findsOneWidget);
      expect(
        find.textContaining('Lower scores are better.'),
        findsOneWidget,
        reason: 'a penalty score is the one number here that is better low, '
            'and nothing else on the card says so',
      );
      // Still no screen hint riding along with it (07 "What NOT to do").
      expect(
        find.textContaining('quick summary before diving into'),
        findsNothing,
      );
    });

    testWidgets('the standalone route keeps its title', (tester) async {
      await tester.pumpWidget(
        _host(const DiagnosticsTabContent(showTitle: true)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Optical train diagnostics'), findsOneWidget);
    });
  });
}

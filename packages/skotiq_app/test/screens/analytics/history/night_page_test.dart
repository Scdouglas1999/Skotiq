// A night opens as a page of Analytics > History: Summary, Frames, Run log,
// Report and Workbench, with what can be done to the night in its header.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/utils/darkroom_navigation.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'history_app.dart';
import 'history_fixtures.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _ScriptedResolver implements DawnMasterResolver {
  _ScriptedResolver(this.set, {this.delay});

  final DawnMasterSet set;
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

const _desktop = Size(1400, 1000);
const _phone = Size(390, 844);
const _darkroomButton = ValueKey('night_open_darkroom');

void main() {
  final start = DateTime(2026, 7, 30, 21);
  final night = session(
    5,
    name: 'Night A - M31',
    start: start,
    end: start.add(const Duration(hours: 3)),
    exposures: 12,
    integration: 1440,
    hfr: 2.14,
    rms: 0.61,
  );

  Future<void> open(
    WidgetTester tester, {
    String query = 'night=5',
    Size size = _desktop,
    SkotiqBackend? backend,
    bool launchedAsRemoteClient = false,
    DawnMasterResolver? resolver,
    int pumps = 8,
    List<Override> overrides = const [],
    bool withRun = true,
  }) async {
    useWindow(tester, size);
    final built = historyApp(
      location: '/analytics?tab=history&$query',
      sessions: [night],
      runs: [
        if (withRun)
          run(
            8,
            name: 'Night A - M31',
            start: start,
            end: start.add(const Duration(hours: 3)),
            sequenceId: 4,
            stats: {
              'wallClockSecs': 10800,
              'integrationSecs': 1440,
              'framesCaptured': 12,
              'framesRejected': 2,
              'meridianFlips': 1,
              'errorMessages': ['Guider lost the star'],
              'targetBreakdown': {
                'M 31': {
                  'Ha': {'captured': 12, 'integrationSecs': 1440},
                },
              },
            },
          ),
      ],
      images: [
        for (var i = 0; i < 10; i++)
          frame(i + 1, sessionId: 5, at: start.add(Duration(minutes: i * 5))),
        frame(11, sessionId: 5, at: start, accepted: false),
        frame(12, sessionId: 5, at: start, accepted: false),
        frame(13, sessionId: 5, at: start, type: 'dark'),
      ],
      overrides: [
        backendProvider.overrideWith(
          (ref) => _PinnedBackend(ref, backend ?? DisconnectedBackend()),
        ),
        remoteClientLaunchProvider.overrideWithValue(launchedAsRemoteClient),
        dawnMasterResolverProvider
            .overrideWithValue(resolver ?? _ScriptedResolver(_oneMaster())),
        ...overrides,
      ],
    );
    await tester.pumpWidget(built.app);
    for (var i = 0; i < pumps; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Readout readout(WidgetTester tester, String label) => tester
      .widgetList<Readout>(find.byType(Readout))
      .firstWhere((r) => r.label?.toLowerCase() == label.toLowerCase());

  testWidgets('a night that is not on record says so and offers the way back',
      (tester) async {
    await open(tester, query: 'night=-1&view=report');

    expect(find.text('This night is not on record'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Back to History'));
    await settle(tester);
    expect(find.text('Night A - M31'), findsOneWidget);
    expect(find.text('This night is not on record'), findsNothing);
  });

  testWidgets('the Summary states what was captured, kept and thrown away',
      (tester) async {
    await open(tester);

    expect(find.text('Night A - M31'), findsOneWidget);
    expect(find.widgetWithText(SkotiqChip, 'Completed'), findsOneWidget);
    expect(readout(tester, 'Total exposures').value, '12');
    expect(readout(tester, 'Accepted').value, '10');
    expect(readout(tester, 'Rejected').value, '2');
    expect(readout(tester, 'Avg HFR').value, '2.14');
    expect(
      find.textContaining(
        'Reported by the run Guider lost the star',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(readout(tester, 'Meridian flips').value, '1');
    expect(find.text('M 31'), findsOneWidget);
    expect(find.textContaining('12 frames'), findsOneWidget);
  });

  testWidgets('a link that knows only the run opens the same night',
      (tester) async {
    await open(tester, query: 'run=8&view=log');

    expect(find.text('Night A - M31'), findsOneWidget);
    expect(find.text('TIMELINE'), findsOneWidget);
    expect(find.text('DECISIONS'), findsOneWidget);
    expect(find.textContaining('NOTES'), findsOneWidget);
  });

  testWidgets('Frames says how many of the frames are calibration',
      (tester) async {
    await open(tester, query: 'night=5&view=frames');

    expect(find.textContaining('12 light · 1 calibration'), findsOneWidget);
    expect(find.text('Total 13'), findsOneWidget);
  });

  testWidgets('a session with no run offers no Run log', (tester) async {
    await open(tester, query: 'night=5&view=log', withRun: false);

    expect(find.text('Run log'), findsNothing);
    expect(find.text('Summary'), findsOneWidget);
    expect(readout(tester, 'Total exposures').value, '12');
  });

  testWidgets('the header names every action', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester);

    expect(tester.getSemantics(find.byKey(_darkroomButton)).label,
        'Open in Darkroom');
    await tester.tap(find.byKey(const ValueKey('night_actions_menu')));
    await settle(tester);

    for (final label in [
      'Session report',
      'Compare with the previous run',
      'Export to JSON',
      'Export to CSV',
      'Export HTML report',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // Share exists only where the OS has a share sheet.
    expect(find.text('Share'), findsNothing);
    handle.dispose();
  });

  group('Open in Darkroom', () {
    String nameOf(WidgetTester tester) =>
        tester.getSemantics(find.byKey(_darkroomButton)).label;
    bool enabled(WidgetTester tester) =>
        tester.widget<SkotiqButton>(find.byKey(_darkroomButton)).onPressed !=
        null;

    testWidgets('is live on the host for a night with a master',
        (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester);

      expect(nameOf(tester), 'Open in Darkroom');
      expect(enabled(tester), isTrue);
      handle.dispose();
    });

    testWidgets('is refused on a linked client, in the name and the tooltip',
        (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, backend: _MockNetworkBackend());

      expect(
        nameOf(tester),
        unavailableControlName('Open in Darkroom', kDarkroomHostOnlyRefusal),
      );
      final data = tester
          .getSemantics(find.byKey(_darkroomButton))
          .getSemanticsData();
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
      expect(data.hasFlag(SemanticsFlag.isEnabled), isFalse);
      expect(enabled(tester), isFalse);
      expect(find.byTooltip(kDarkroomHostOnlyRefusal), findsOneWidget);
      handle.dispose();
    });

    testWidgets('is refused on a client that has not reached its rig',
        (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, launchedAsRemoteClient: true);

      expect(
        nameOf(tester),
        unavailableControlName('Open in Darkroom', kDarkroomHostOnlyRefusal),
      );
      expect(enabled(tester), isFalse);
      handle.dispose();
    });

    testWidgets('a night with no master refuses on the control, not after it',
        (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, resolver: _ScriptedResolver(_noMaster()));

      expect(nameOf(tester), startsWith('Open in Darkroom: '));
      expect(nameOf(tester), contains('no integrated master'));
      expect(enabled(tester), isFalse);
      handle.dispose();
    });

    testWidgets('a night whose masters are still being read is not offered yet',
        (tester) async {
      final handle = tester.ensureSemantics();
      await open(
        tester,
        resolver: _ScriptedResolver(
          _oneMaster(),
          delay: const Duration(seconds: 5),
        ),
        pumps: 2,
      );

      expect(
        nameOf(tester),
        unavailableControlName(
          'Open in Darkroom',
          kDarkroomMastersReadingReason,
        ),
      );
      expect(enabled(tester), isFalse);

      await tester.pump(const Duration(seconds: 6));
      expect(nameOf(tester), 'Open in Darkroom');
      expect(enabled(tester), isTrue);
      handle.dispose();
    });
  });

  testWidgets('the Report is refused on a linked client, where it is opened',
      (tester) async {
    await open(
      tester,
      query: 'night=5&view=report',
      backend: _MockNetworkBackend(),
    );

    expect(find.text('Open this on the imaging host'), findsOneWidget);
    expect(find.byKey(const ValueKey('night_review_build')), findsNothing);
  });

  testWidgets('at phone width the page fits and the menu carries the Darkroom',
      (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, size: _phone, backend: _MockNetworkBackend());

    expect(tester.takeException(), isNull);
    expect(find.byKey(_darkroomButton), findsNothing);
    await tester.tap(find.byKey(const ValueKey('night_actions_menu')));
    await settle(tester);

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
    expect(
      names,
      contains(
        unavailableControlName('Open in Darkroom', kDarkroomHostOnlyRefusal),
      ),
      reason: 'a menu row has no tooltip a finger can reach, so the reason '
          'is in its name',
    );
    handle.dispose();
  });
}

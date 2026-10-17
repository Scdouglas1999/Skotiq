// The shell chrome must reach the accessibility tree.
//
// On the running Linux bundle `tree --all` contained ZERO title-bar nodes and
// ZERO nav-rail destinations while the dashboard's own content and the status
// bar WERE exposed, which left Settings — reachable only through the gear —
// unreachable to assistive tech.
//
// The loss was never in these widgets: each of them annotates itself, and the
// three tests below pin that. It was in how the shell composes them with the
// routed page. go_router's `ShellRoute` hands `AppShell` a nested `Navigator`;
// a `ModalRoute`'s first overlay entry is a `ModalBarrier`, which is a
// `BlockSemantics`; and Flutter propagates that "drop everything painted
// before me" flag up through every ancestor that is not a semantics boundary.
// It escaped the navigator and erased the rail out of the shell Row and the
// top band out of the shell Column. `_ContentSemanticsBoundary` in
// app_shell.dart is the boundary that stops it, and the last test here pumps
// the REAL shell around a real routed page route so a regression fails here
// rather than on a rig.
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_app/screens/shell/shell_navigation.dart';
import 'package:skotiq_app/screens/shell/widgets/side_navigation.dart';
import 'package:skotiq_app/screens/shell/widgets/window_chrome.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// The real alert stream opens a 15-minute polling timer that outlives the
/// widget tree; the chrome only cares that it resolves.
/// The rail joined that list when it grew the attention dot. It reads the
/// verdict through `railWeatherUnsafeProvider`, a one-bool view, precisely so
/// a test about the rail's LABELS does not have to build the weather-safety
/// subsystem — whose constructor schedules a re-evaluation that is still
/// pending when the binding checks for leaked timers.
final _quietAlerts = <Override>[
  activeTransientAlertsProvider.overrideWith(
    (ref) => Stream.value(const <TransientAlert>[]),
  ),
  railWeatherUnsafeProvider.overrideWithValue(false),
  railAnyDeviceConnectedProvider.overrideWithValue(true),
];

/// Every label in the compiled semantics tree, in traversal order.
List<String> _semanticsLabels(WidgetTester tester) =>
    _semanticsNodes(tester).map((node) => node.label).toList();

/// Every labelled node in the compiled semantics tree, in traversal order.
List<SemanticsData> _semanticsNodes(WidgetTester tester) {
  final root = tester.binding.pipelineOwner.semanticsOwner?.rootSemanticsNode;
  if (root == null) return const <SemanticsData>[];
  final nodes = <SemanticsData>[];
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.label.isNotEmpty) nodes.add(data);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return nodes;
}

/// Flutter merges a labelled ancestor with the Text inside it into ONE node
/// whose label is both strings joined by a newline ("Collapse navigation\nCollapse").
/// Match on containment so a control that also renders its word on screen is
/// not reported missing.
Matcher _publishes(String label) => predicate<List<String>>(
      (labels) => labels.any((l) => l.contains(label)),
      'publishes a semantics label containing "$label"',
    );

/// Exact-match lookup, for rows whose whole name is the string.
SemanticsData? _nodeLabelledExactly(List<SemanticsData> nodes, String label) {
  for (final node in nodes) {
    if (node.label == label) return node;
  }
  return null;
}

/// The shell reads the checkpoint API on startup; keep that quiet so the test
/// is about semantics, not about startup IO.
class _QuietBackend extends DisconnectedBackend {
  @override
  Future<void> sequencerSetCheckpointDir(String path) async {}

  @override
  Future<bool> hasCheckpoint() async => false;
}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

void _mockPathProvider(String root) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => root);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}

/// The routed page as go_router builds it: a nested [Navigator] holding a
/// [ModalRoute]. The barrier that route publishes is the whole point — a
/// bare widget here would pass with the boundary removed.
Widget _routedPage(String marker) => Navigator(
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => Semantics(
          label: marker,
          child: const SizedBox.expand(),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the collapse button names itself and its action',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      SideNavigation(
        currentIndex: 0,
        onTabSelected: (_) {},
        isExpanded: true,
        onToggleExpanded: () {},
      ),
      settle: false,
      extraOverrides: _quietAlerts,
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(_semanticsLabels(tester), _publishes('Collapse navigation'));

    semantics.dispose();
  });

  testWidgets('a collapsed rail still names the control that expands it',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      SideNavigation(
        currentIndex: 0,
        onTabSelected: (_) {},
        isExpanded: false,
        onToggleExpanded: () {},
      ),
      settle: false,
      extraOverrides: _quietAlerts,
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Collapsed, the glyph has no text beside it at all — this label is the
    // only thing that names it.
    expect(_semanticsLabels(tester), _publishes('Expand navigation'));

    semantics.dispose();
  });

  testWidgets('the desktop chrome column publishes top band and rail alike',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      Column(
        children: [
          const ShellTopBand(),
          Expanded(
            child: Row(
              children: [
                SideNavigation(
                  currentIndex: 0,
                  onTabSelected: (_) {},
                  isExpanded: true,
                  onToggleExpanded: () {},
                ),
                const Expanded(child: Center(child: Text('Routed content'))),
              ],
            ),
          ),
        ],
      ),
      settle: false,
      extraOverrides: _quietAlerts,
      size: const Size(1600, 900),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final labels = _semanticsLabels(tester);
    // The top-band icons the live tree could not find. The equipment-profile
    // shortcut is no longer among them: profiles live on Equipment and in the
    // instrument bar, and a third way in was a third thing to keep in sync.
    expect(labels, _publishes('Settings'));
    expect(labels, _publishes('Help for this screen'));
    // A nav destination and the rail's own control.
    expect(labels, _publishes('Tonight'),
        reason: 'the rail must publish its destinations');
    expect(labels, _publishes('Collapse navigation'));
    // And the routed content, so the assertion above is not vacuous.
    expect(labels, _publishes('Routed content'));

    semantics.dispose();
  });

  testWidgets('window controls reach the compiled tree beside the rail',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      Column(
        children: [
          const ShellTopBand(),
          Expanded(
            child: SideNavigation(
              currentIndex: 0,
              onTabSelected: (_) {},
              isExpanded: true,
              onToggleExpanded: () {},
            ),
          ),
        ],
      ),
      settle: false,
      extraOverrides: _quietAlerts,
      size: const Size(1600, 900),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final labels = _semanticsLabels(tester);
    // WindowControls only render on a desktop window; on the test host
    // (Platform.isLinux) they do, and this is the exact string the live audit
    // grepped for and did not find.
    expect(labels, _publishes('Close window'));

    semantics.dispose();
  });

  testWidgets('the whole desktop shell survives the routed page route barrier',
      (tester) async {
    // Synchronous on purpose: `testWidgets` runs inside a fake-async zone, and
    // an awaited dart:io future never completes there.
    final root = Directory.systemTemp.createTempSync('sk-shell-semantics-');
    addTearDown(() => root.deleteSync(recursive: true));
    _mockPathProvider(root.path);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1600, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _StubBackendNotifier(ref, _QuietBackend()),
          ),
          ..._quietAlerts,
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: AppShell(child: _routedPage('Routed content')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final nodes = _semanticsNodes(tester);
    final labels = nodes.map((n) => n.label).toList();
    final l10n = SkotiqLocalizations(const Locale('en'));

    // Non-vacuous: the routed page is inside the barrier and always published.
    expect(labels, _publishes('Routed content'));

    // Every rail destination, with a role and a selected state — a name with
    // no role reads as static text to a screen reader.
    for (var index = 0;
        index < ShellNavigation.primaryDestinations.length;
        index++) {
      final destination = ShellNavigation.primaryDestinations[index];
      final name = destination.label(l10n);
      // The rail row's Semantics label is EXACTLY the destination name (the
      // descriptions are gone in the Observatory rail), so match on equality:
      // a `contains` match would let the top bar's own buttons answer for a
      // rail row that is not published at all.
      final node = _nodeLabelledExactly(nodes, name);
      expect(
        node,
        isNotNull,
        reason: 'the rail destination "$name" must reach the semantics tree; '
            'the routed page route barrier used to erase the whole rail',
      );
      expect(node!.label, name,
          reason: 'the rail row must announce its destination by name');
      expect(node.flagsCollection.isButton, isTrue,
          reason: '"$name" must publish a button role');
      expect(node.flagsCollection.isEnabled, Tristate.isTrue,
          reason: '"$name" is live and must not announce as disabled');
      // No GoRouter above this shell, so `_getCurrentLocation` falls back to
      // /dashboard and index 0 is the selected destination. `Tristate.none`
      // would mean the rail never says which screen the operator is on.
      expect(
        node.flagsCollection.isSelected,
        index == 0 ? Tristate.isTrue : Tristate.isFalse,
        reason: '"$name" must publish whether it is the current screen, and '
            'only the current destination may announce as selected',
      );
    }

    // The rail's own control and the title-bar action row, in the order a
    // reader meets them. A fresh profile starts with the rail collapsed
    // (Observatory shell default), so the control it publishes is "Expand".
    expect(labels, _publishes('Expand navigation'));
    expect(labels, _publishes(l10n.text('settingsTitle')));
    expect(labels, _publishes('Minimize'));
    expect(labels, _publishes('Maximize'));
    expect(labels, _publishes('Close window'));

    semantics.dispose();

    // Unmount inside the test body so the drift stream-close timers the
    // ProviderScope schedules on dispose can drain.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
  }, timeout: const Timeout(Duration(seconds: 90)));
}

// A `/settings?section=<key>` deep link taken while Settings is ALREADY open
// must move the screen to that section.
//
// The router rebuilds the same `SettingsScreen` element with a new
// `initialSection` (go_router's page for `/settings` is keyless, so the
// Navigator updates the existing route rather than pushing a second one), so a
// screen that reads the key only in `initState` ignores it. Every in-Settings
// link that points back at Settings — the title bar's profile icon
// (`?section=equipment-profiles`) and ~8 siblings — then does nothing at all
// once the screen is up.
//
// The host below is the router's behaviour reduced to what matters: the same
// widget position, a changing `initialSection`. A screen that only reads the
// key in initState fails the first test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/about_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/help_tutorials_settings.dart';

import '../../harness/harness.dart';

/// Rebuilds [SettingsScreen] in place with whatever section it is given,
/// exactly as the `/settings` route's pageBuilder does on a new query string.
class _RouteHost extends StatefulWidget {
  const _RouteHost({super.key, required this.initialSection});

  final String? initialSection;

  @override
  State<_RouteHost> createState() => _RouteHostState();
}

class _RouteHostState extends State<_RouteHost> {
  late String? _section = widget.initialSection;

  /// A new navigation to /settings carrying a different `?section=`.
  void navigateTo(String? section) => setState(() => _section = section);

  /// A plain parent rebuild that carries the same section the screen was
  /// deep-linked with (theme change, locale change, router refresh).
  void rebuildUnchanged() => setState(() {});

  @override
  Widget build(BuildContext context) =>
      SettingsScreen(initialSection: _section);
}

/// Drops "overflowed" layout exceptions; re-forwards everything else. Some
/// settings panes overflow a few pixels at the test surface size.
void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() {
    FlutterError.onError = defaultOnError;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a section deep link taken while Settings is open moves to that section',
      (tester) async {
    _swallowKnownOverflows();
    final hostKey = GlobalKey<_RouteHostState>();

    await pumpAppScreen(
      tester,
      _RouteHost(key: hostKey, initialSection: 'help'),
      size: const Size(1280, 800),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(HelpTutorialsSettings), findsOneWidget);

    // The router hands the SAME screen a new section.
    hostKey.currentState!.navigateTo('about');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(AboutSettings), findsOneWidget,
        reason: 'A /settings?section= link followed while Settings is already '
            'open must open the named section, not silently do nothing.');
    expect(find.byType(HelpTutorialsSettings), findsNothing);
  });

  testWidgets('a merged-away alias deep link resolves on the open screen',
      (tester) async {
    _swallowKnownOverflows();
    final hostKey = GlobalKey<_RouteHostState>();

    await pumpAppScreen(
      tester,
      _RouteHost(key: hostKey, initialSection: 'help'),
      size: const Size(1280, 800),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 16));

    // An unknown key names no section: the screen must stay where it is
    // rather than fall back to the first category under the operator.
    hostKey.currentState!.navigateTo('not-a-section');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(HelpTutorialsSettings), findsOneWidget,
        reason: 'An unknown section key is not a navigation request.');
  });

  testWidgets('an unchanged section link does not fight in-screen navigation',
      (tester) async {
    _swallowKnownOverflows();
    final hostKey = GlobalKey<_RouteHostState>();

    await pumpAppScreen(
      tester,
      _RouteHost(key: hostKey, initialSection: 'help'),
      size: const Size(1280, 800),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 16));

    // The operator walks to another section from the sidebar.
    await tester.tap(find.text('About').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(AboutSettings), findsOneWidget);

    // A parent rebuild carrying the SAME deep-link key must not snap the
    // screen back to it.
    hostKey.currentState!.rebuildUnchanged();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(AboutSettings), findsOneWidget,
        reason: 'Only a CHANGED section key is a navigation request; a plain '
            'rebuild must leave the operator where they are.');
  });

  // The same link CLICKED AGAIN after the operator moved by hand.
  //
  // Click the person icon (lands on Equipment Profiles), click "Connection" in
  // the sidebar, click the person icon again: the route is unchanged, so a key
  // comparison declines and the pane stays on Connection — but the operator is
  // not looking at what the link names, so from the outside the icon is dead.
  testWidgets('a repeat click on the same deep link moves the screen back',
      (tester) async {
    _swallowKnownOverflows();
    SettingsSectionRequest.reset();
    addTearDown(SettingsSectionRequest.reset);
    final hostKey = GlobalKey<_RouteHostState>();

    await pumpAppScreen(
      tester,
      _RouteHost(key: hostKey, initialSection: 'help'),
      size: const Size(1280, 800),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 16));

    // The operator walks away from the section the link names.
    await tester.tap(find.text('About').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(AboutSettings), findsOneWidget);

    // The chrome raises the SAME link again. The route does not change, so
    // the host is rebuilt unchanged exactly as go_router does.
    SettingsSectionRequest.raise('help');
    hostKey.currentState!.rebuildUnchanged();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(HelpTutorialsSettings), findsOneWidget,
        reason: 'clicking a deep link is a request even when the URL is '
            'identical to the one already loaded');
  });

  testWidgets('a stale request is not replayed by a later rebuild',
      (tester) async {
    _swallowKnownOverflows();
    SettingsSectionRequest.reset();
    addTearDown(SettingsSectionRequest.reset);
    final hostKey = GlobalKey<_RouteHostState>();

    SettingsSectionRequest.raise('help');
    await pumpAppScreen(
      tester,
      _RouteHost(key: hostKey, initialSection: 'help'),
      size: const Size(1280, 800),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 16));

    await tester.tap(find.text('About').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(AboutSettings), findsOneWidget);

    // No new click: a rebuild alone must not resurrect the last request.
    hostKey.currentState!.rebuildUnchanged();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(AboutSettings), findsOneWidget);
  });
}

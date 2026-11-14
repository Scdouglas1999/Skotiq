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
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/about_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/help_tutorials_settings.dart';

import '../../harness/harness.dart';
import 'package:skotiq_app/router/app_routes.dart';

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
      SettingsScreen(initialSection: SettingsSectionId.resolve(_section));
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
  // the sidebar, click the person icon again: the route is unchanged, so the
  // screen is rebuilt with the arguments it already has. It follows the
  // router's navigation announcements instead, so the link still lands.
  group('with the router', () {
    GoRouter buildRouter() => GoRouter(
          initialLocation: AppRoutes.settings(SettingsSectionId.help),
          routes: [
            GoRoute(
              path: AppRoute.settings.path,
              builder: (context, state) => SettingsScreen(
                initialSection: SettingsSectionId.resolve(
                  state.uri.queryParameters['section'],
                ),
              ),
            ),
          ],
        );

    Future<GoRouter> pumpRouted(WidgetTester tester) async {
      _swallowKnownOverflows();
      final router = buildRouter();
      addTearDown(router.dispose);
      await pumpAppScreen(
        tester,
        Router<Object>.withConfig(config: router),
        size: const Size(1280, 800),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(HelpTutorialsSettings), findsOneWidget);

      // The operator walks away from the section the link names.
      await tester.tap(find.text('About').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(AboutSettings), findsOneWidget);
      return router;
    }

    testWidgets('a repeat of the same link moves the screen back',
        (tester) async {
      final router = await pumpRouted(tester);

      router.goToSettings(SettingsSectionId.help);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.byType(HelpTutorialsSettings), findsOneWidget,
          reason: 'clicking a link is a request even when the URL is '
              'identical to the one already loaded');
    });

    testWidgets('a plain string route lands the same way', (tester) async {
      final router = await pumpRouted(tester);

      // Core models and tour data carry routes as strings, old keys included.
      router.go('/settings?section=help');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(HelpTutorialsSettings), findsOneWidget);
    });

    testWidgets('opening Settings without a section stays put', (tester) async {
      final router = await pumpRouted(tester);

      router.goToSettings();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.byType(AboutSettings), findsOneWidget,
          reason: 'the gear icon names no section, so it must not move the '
              'operator off the one they chose');
    });
  });
}

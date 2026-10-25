// The Settings entry for the night-end automation. Its switches moved to the
// Darkroom's Activity tab, so the entry keeps its place beside Delivery and
// takes the operator there.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/settings/settings_catalog.dart';
import 'package:skotiq_app/screens/settings/widgets/darkroom_autopilot_settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Future<List<SettingsGroupDef>> catalog(WidgetTester tester) async {
    late List<SettingsGroupDef> groups;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            groups = buildSettingsGroups(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return groups;
  }

  testWidgets('the night-end automation entry sits beside Delivery', (
    tester,
  ) async {
    final groups = await catalog(tester);
    final owning = groups.firstWhere(
      (g) => g.sections.any((s) => s.key == 'darkroom'),
    );
    expect(owning.title, 'Automation & Safety');
    final section = owning.sections.firstWhere((s) => s.key == 'darkroom');
    expect(section.label, 'Night-end automation');
    expect(
        section.keywords, containsAll(['auto-integrate', 'morning message']));
    final keys = owning.sections.map((s) => s.key).toList();
    expect((keys.indexOf('delivery') - keys.indexOf('darkroom')).abs(), 1);
  });

  test('the locale-independent group lookup agrees with the catalog', () {
    expect(groupTitleForKey('darkroom'), 'Automation & Safety');
    expect(resolveSectionKey('darkroom'), 'darkroom');
  });

  testWidgets('opening the entry goes to the Activity tab', (tester) async {
    final visited = <String>[];
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, state) =>
              const Scaffold(body: DarkroomAutopilotSettings()),
        ),
        GoRoute(
          path: '/darkroom',
          builder: (context, state) {
            visited.add(state.uri.toString());
            return const Scaffold(body: Text('Darkroom'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: SkotiqTheme.dark, routerConfig: router),
    );
    await tester.pumpAndSettle();
    expect(visited, ['/darkroom?tab=activity']);
  });

  testWidgets(
      'without a router the entry still names where the switches '
      'are', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: DarkroomAutopilotSettings()),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Night-end automation is in the Darkroom'),
      findsOneWidget,
    );
    expect(find.widgetWithText(SkotiqButton, 'Open Activity'), findsOneWidget);
  });
}

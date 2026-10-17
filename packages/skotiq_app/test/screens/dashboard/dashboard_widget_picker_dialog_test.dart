import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout_provider.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_screen.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _TestDashboardLayoutNotifier extends DashboardLayoutNotifier {
  @override
  Future<DashboardLayout> build() async {
    final disabledTiles = DashboardLayout.defaultLayout()
        .tiles
        .map((tile) => tile.copyWith(enabled: false))
        .toList();

    return DashboardLayout(
      version: DashboardLayout.currentVersion,
      tiles: disabledTiles,
      secondaryZoneWidth: 0.4,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Widget picker dialog opens without exceptions', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(780, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardLayoutProvider
              .overrideWith(() => _TestDashboardLayoutNotifier()),
          // Edit arranges the cockpit tiles and is refused while the standby
          // briefing (which has none) is on screen.
          dashboardStandbyProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: DashboardScreen(),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 200));

    final editButton = find.byWidgetPredicate(
      (widget) => widget is SkotiqButton && widget.label == 'Edit layout',
    );
    expect(editButton, findsOneWidget);

    await tester.tap(editButton);
    await tester.pump(const Duration(milliseconds: 200));

    final widgetsButton = find.byWidgetPredicate(
      (widget) =>
          widget is SkotiqButton && widget.icon == LucideIcons.layoutGrid,
    );
    expect(widgetsButton, findsOneWidget);

    await tester.tap(widgetsButton);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Dashboard Widgets'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

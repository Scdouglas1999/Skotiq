// A Settings row gives its description the width the control leaves, and the
// navigation marks the entries that take you out of Settings.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const _description = 'Sound an alarm here when a run hits a critical problem, '
    'such as a mount fault or a failed recovery.';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

Widget _row(Widget trailing) => MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 880,
            child: SettingsSection(
              title: 'Critical problems',
              trailing: const [Text('group action')],
              children: [
                SettingRow(
                  icon: LucideIcons.bell,
                  title: 'Ring on this computer',
                  subtitle: _description,
                  trailing: trailing,
                ),
              ],
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a switch leaves the description most of the row',
      (tester) async {
    await tester.pumpWidget(_row(SkotiqSwitch(value: true, onChanged: (_) {})));

    final description = tester.getSize(find.text(_description)).width;
    expect(description, greaterThan(600),
        reason: 'it wrapped at half the row beside a 40 px switch');
    expect(find.text('group action'), findsOneWidget);
  });

  testWidgets('a wide control still gets no more than half the row',
      (tester) async {
    await tester.pumpWidget(
      _row(const SizedBox(width: 2000, height: 20, key: ValueKey('wide'))),
    );

    expect(tester.getSize(find.byKey(const ValueKey('wide'))).width,
        lessThanOrEqualTo(440));
    expect(tester.takeException(), isNull);
  });

  testWidgets('entries that open the Darkroom say so in the navigation',
      (tester) async {
    final defaultOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      defaultOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = defaultOnError);

    await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 1600),
      extraOverrides: [
        appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
      ],
    );

    final markers = find.byWidgetPredicate(
      (w) => w is Tooltip && w.message == 'Opens in the Darkroom',
    );
    expect(markers, findsNWidgets(2));
    for (final entry in ['Calibration', 'Night-end automation']) {
      final item = find.ancestor(
        of: find.text(entry),
        matching: find.byType(InkWell),
      );
      expect(find.descendant(of: item.first, matching: markers), findsOneWidget,
          reason: entry);
    }
  });
}

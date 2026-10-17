import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/glance_mode_toggle.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _FailingGlanceModeNotifier extends GlanceModeNotifier {
  _FailingGlanceModeNotifier(super.ref);

  @override
  Future<void> toggle() => Future<void>.error(StateError('write failed'));
}

void main() {
  testWidgets('failed persistence is reported and leaves the toggle off',
      (tester) async {
    late _FailingGlanceModeNotifier notifier;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          glanceModeProvider.overrideWith((ref) {
            notifier = _FailingGlanceModeNotifier(ref);
            return notifier;
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => GlanceModeToggle(
                colors: SkotiqColors.of(context),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(GlanceModeToggle));
    await tester.pumpAndSettle();

    expect(
        find.text('Could not save the Glance mode setting.'), findsOneWidget);
    expect(notifier.state, isFalse);
  });

  // The toggle worked but permanently advertised itself as unavailable: the
  // accessibility tree read "button: Glance mode [off,DISABLED]" before a click
  // and "[ON,DISABLED]" after one, because the Semantics node set `toggled` but
  // never `enabled`, so it published CHECKABLE without ENABLED. A screen-reader
  // user is told the control is dimmed and skips it.
  testWidgets('a working toggle announces itself as enabled', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => GlanceModeToggle(
                colors: SkotiqColors.of(context),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSemantics(find.bySemanticsLabel('Glance mode')),
      isSemantics(
        label: 'Glance mode',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasToggledState: true,
        isToggled: false,
      ),
    );
    handle.dispose();
  });
}

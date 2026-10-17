// Regression guard for: "The mosaic project screen's back breadcrumb always
// says 'Mosaic projects' even when it returns somewhere else".
//
// The label was a bare string literal beside the back button, but the handler
// POPS: reached from the Collaborative Sky mosaic detail (Join mosaic), from
// Framing, or from the sequencer mosaic wizard, pressing '< Mosaic projects'
// returns to THAT screen, not to the projects list. Only an empty stack — where
// the handler falls back to context.go('/mosaic') — really lands there.
//
// The Observatory overhaul folded that full-width row into a header action
// (04-shell §4 gives this screen ONE header, and the row was a second one), so
// the promise now lives in the control's tooltip, which is also its accessible
// name. The lie is still the thing being guarded against; only where it would
// be written has moved.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// The remote guard renders the screen's chrome (including the header) with
/// no database work, which is all this test needs.
List<Override> _overrides() => [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, _MockNetworkBackend()),
      ),
      mosaicProjectsDaoProvider.overrideWith(
        (ref) => throw StateError('no DAO work in this test'),
      ),
    ];

Widget _app(Widget home) => ProviderScope(
      overrides: [..._overrides()],
      child: MaterialApp(theme: SkotiqTheme.dark, home: home),
    );

/// The header's back control, whatever it currently promises.
final Finder _backAction = find.byWidgetPredicate(
  (widget) =>
      widget is SkotiqIconButton &&
      widget.icon == SkotiqIcons.arrowLeft,
);

/// What that control promises, in the words a pointer and a screen reader both
/// get.
String _promise(WidgetTester tester) =>
    tester.widget<SkotiqIconButton>(_backAction).tooltip;

/// Push the mosaic project screen on top of [label], the way the Collaborative
/// Sky detail and the sequencer wizard both do.
Widget _pushedOver(String label) => _app(
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const MosaicProjectScreen(
                    projectId: 42,
                    artifactsBaseDir: '/m',
                  ),
                ),
              ),
              child: Text(label),
            ),
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'an empty stack promises the projects list, because it goes '
      'there', (tester) async {
    await tester.pumpWidget(
      _app(const MosaicProjectScreen(projectId: 42, artifactsBaseDir: '/m')),
    );
    await tester.pump();

    expect(_promise(tester), 'Back to mosaic projects');
  });

  testWidgets('pushed on top of another screen it does not promise the list', (
    tester,
  ) async {
    await tester.pumpWidget(_pushedOver('join'));
    await tester.tap(find.text('join'));
    await tester.pumpAndSettle();

    expect(
      _promise(tester),
      isNot(contains('mosaic projects')),
      reason: 'this control returns to whatever pushed it, not to the list',
    );

    // ...and it really does return there.
    await tester.tap(_backAction);
    await tester.pumpAndSettle();
    expect(find.text('join'), findsOneWidget);
  });

  // An icon-only control with no accessible name publishes as a role with
  // nothing to say where it goes.
  testWidgets('the control is a named, enabled button', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_pushedOver('open'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final node = tester.getSemantics(_backAction);
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(node.label, contains('Back'));

    await tester.tap(_backAction);
    await tester.pumpAndSettle();
    expect(_backAction, findsNothing);
    handle.dispose();
  });
}

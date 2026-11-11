import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/authority_bound_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

class _Dialog extends ConsumerStatefulWidget {
  const _Dialog({this.message = 'The connected host changed. Canceled.'});

  final String? message;

  @override
  ConsumerState<_Dialog> createState() => _DialogState();
}

class _DialogState extends ConsumerState<_Dialog>
    with HostBoundDialogState<_Dialog> {
  @override
  String? get hostChangedMessage => widget.message;

  @override
  Widget build(BuildContext context) => AlertDialog(
        content: Text(host.isCurrent ? 'current' : 'stale'),
      );
}

Future<_SwappableBackendNotifier> _pumpLauncher(
  WidgetTester tester,
  SkotiqBackend initial,
  _Dialog dialog,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, initial),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => dialog,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.text('open')))
      .read(backendProvider.notifier) as _SwappableBackendNotifier;
}

void main() {
  testWidgets('the dialog closes with its message when the host changes',
      (tester) async {
    final hostA = DisconnectedBackend();
    final hostB = DisconnectedBackend();
    addTearDown(hostA.dispose);
    addTearDown(hostB.dispose);
    final notifier = await _pumpLauncher(tester, hostA, const _Dialog());

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('current'), findsOneWidget);
    final state = tester.state<_DialogState>(find.byType(_Dialog));
    expect(state.host.value, same(hostA));

    notifier.switchTo(hostB);
    await tester.pumpAndSettle();

    expect(find.byType(_Dialog), findsNothing);
    expect(find.text('The connected host changed. Canceled.'), findsOneWidget);
    expect(find.text('open'), findsOneWidget);
    expect(state.host.isStale, isTrue);
  });

  testWidgets('a dialog without a message closes without a notice',
      (tester) async {
    final hostA = DisconnectedBackend();
    final hostB = DisconnectedBackend();
    addTearDown(hostA.dispose);
    addTearDown(hostB.dispose);
    final notifier =
        await _pumpLauncher(tester, hostA, const _Dialog(message: null));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    notifier.switchTo(hostB);
    await tester.pumpAndSettle();

    expect(find.byType(_Dialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('scopes stay stale after the app links back to the first host',
      (tester) async {
    final hostA = DisconnectedBackend();
    final hostB = DisconnectedBackend();
    addTearDown(hostA.dispose);
    addTearDown(hostB.dispose);
    final notifier = await _pumpLauncher(tester, hostA, const _Dialog());

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final state = tester.state<_DialogState>(find.byType(_Dialog));
    final load = state.hostScopes.beginLatest();
    expect(load.isCurrent, isTrue);
    expect(state.hostScopes.beginLatest().isCurrent, isTrue);
    expect(load.isStale, isTrue, reason: 'a newer load superseded it');

    notifier.switchTo(hostB);
    notifier.switchTo(hostA);

    expect(state.host.isStale, isTrue);
    expect(state.hostScopes.begin().isStale, isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(_Dialog), findsNothing);
  });
}

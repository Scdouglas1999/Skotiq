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
  const _Dialog();

  @override
  ConsumerState<_Dialog> createState() => _DialogState();
}

class _DialogState extends ConsumerState<_Dialog>
    with HostBoundDialogState<_Dialog> {
  @override
  String get hostChangedMessage => 'The connected host changed. Canceled.';

  @override
  Widget build(BuildContext context) => AlertDialog(
        content: Text(host.isCurrent ? 'current' : 'stale'),
      );
}

void main() {
  testWidgets('the dialog closes with its message when the host changes',
      (tester) async {
    final hostA = DisconnectedBackend();
    final hostB = DisconnectedBackend();
    addTearDown(hostA.dispose);
    addTearDown(hostB.dispose);
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => notifier = _SwappableBackendNotifier(ref, hostA),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _Dialog(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

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
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A [FocusRing] that creates its own [FocusNode] and is later given an
/// external one must dispose the node it owned.
///
/// A live [FocusNode] stays registered with [FocusManager], so leaking it
/// leaks a listener, not just memory.
void main() {
  Widget host(FocusNode? node) => MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: FocusRing(
        focusNode: node,
        child: const SizedBox(width: 40, height: 40),
      ),
    ),
  );

  /// The node the ring is currently driving, read off the [Focus] it builds.
  FocusNode activeNode(WidgetTester tester) => tester
      .widget<Focus>(
        find.descendant(
          of: find.byType(FocusRing),
          matching: find.byType(Focus),
        ),
      )
      .focusNode!;

  /// A disposed [FocusNode] rejects a new listener with a [FlutterError].
  final isDisposed = throwsA(isA<FlutterError>());

  testWidgets('a self-created node is disposed when an external node arrives', (
    tester,
  ) async {
    await tester.pumpWidget(host(null));
    final owned = activeNode(tester);

    final external = FocusNode();
    addTearDown(external.dispose);
    await tester.pumpWidget(host(external));

    expect(activeNode(tester), same(external));
    expect(() => owned.addListener(() {}), isDisposed);
  });

  testWidgets('an external node is never disposed by the ring', (tester) async {
    final first = FocusNode();
    addTearDown(first.dispose);
    await tester.pumpWidget(host(first));

    final second = FocusNode();
    addTearDown(second.dispose);
    await tester.pumpWidget(host(second));

    expect(activeNode(tester), same(second));
    // Still usable: the caller owns it.
    first.addListener(() {});
    first.removeListener(() {});
  });

  testWidgets('swapping an external node back to none re-owns the new node', (
    tester,
  ) async {
    final external = FocusNode();
    addTearDown(external.dispose);
    await tester.pumpWidget(host(external));

    await tester.pumpWidget(host(null));
    final owned = activeNode(tester);
    expect(owned, isNot(same(external)));

    // Tearing the tree down must dispose the node the ring now owns.
    await tester.pumpWidget(const SizedBox());
    expect(() => owned.addListener(() {}), isDisposed);
  });

  testWidgets('a self-created node survives an unrelated rebuild', (
    tester,
  ) async {
    await tester.pumpWidget(host(null));
    final owned = activeNode(tester);

    await tester.pumpWidget(host(null));

    expect(activeNode(tester), same(owned));
    owned.addListener(() {});
    owned.removeListener(() {});
  });
}

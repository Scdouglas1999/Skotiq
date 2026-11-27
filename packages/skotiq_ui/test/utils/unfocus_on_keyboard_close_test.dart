import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('a field loses focus when the keyboard closes', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: UnfocusOnKeyboardClose(
          child: Scaffold(body: TextField(focusNode: focus)),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focus.hasFocus, isTrue);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(focus.hasFocus, isTrue, reason: 'keyboard open: still editing');

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    tester.view.resetViewInsets();
  });

  testWidgets('a field focused without a keyboard keeps focus', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: UnfocusOnKeyboardClose(
          child: Scaffold(body: TextField(focusNode: focus)),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    expect(focus.hasFocus, isTrue);
  });

  Future<bool> refocusedAfterDialog(
    WidgetTester tester,
    TargetPlatform platform,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [UnfocusTextOnPopupObserver()],
        home: Scaffold(body: TextField(focusNode: focus)),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    showDialog<void>(
      context: tester.element(find.byType(TextField)),
      builder: (_) => const AlertDialog(content: Text('Allow?')),
    );
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('Allow?'))).pop();
    await tester.pumpAndSettle();
    final refocused = focus.hasFocus;
    debugDefaultTargetPlatformOverride = null;
    return refocused;
  }

  testWidgets('on a phone a closed dialog leaves the field alone', (
    tester,
  ) async {
    expect(await refocusedAfterDialog(tester, TargetPlatform.android), isFalse);
  });

  testWidgets('on a desktop focus returns to the field', (tester) async {
    expect(await refocusedAfterDialog(tester, TargetPlatform.linux), isTrue);
  });

  testWidgets('a dialog that focuses its own field keeps that focus', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final page = FocusNode();
    final inDialog = FocusNode();
    addTearDown(page.dispose);
    addTearDown(inDialog.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [UnfocusTextOnPopupObserver()],
        home: Scaffold(body: TextField(focusNode: page)),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    showDialog<void>(
      context: tester.element(find.byType(TextField)),
      builder: (_) =>
          AlertDialog(content: TextField(focusNode: inDialog, autofocus: true)),
    );
    await tester.pumpAndSettle();
    expect(inDialog.hasFocus, isTrue);
    expect(page.hasFocus, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });
}

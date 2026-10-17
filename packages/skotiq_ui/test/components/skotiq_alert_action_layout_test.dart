import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The Darkroom's branch-delete refusal, raised at 430x900 on the running
/// desktop build, laid its title out ONE GLYPH PER LINE — 'T/h/at/br/a/n/c/h' —
/// in a ~14px column that ran off the bottom of the window and took the whole
/// editor with it. The alert beside it on the same bar, the `.nsrecipe` import
/// refusal, reflowed correctly at the same width; the only difference between
/// them is that the branch refusal carries a wide `action`.
///
/// The seam is [SkotiqAlert] itself, not its caller: a `Row` measures its
/// inflexible children against the full incoming width first, so an
/// unconstrained action of two buttons never wrapped and the only `Expanded`
/// child — the text column — was left what remained, which measured 0px.
///
/// These cases pin the component's own layout at three widths, so every caller
/// with a wide action is covered rather than the one that happened to be
/// found.
const _refusalTitle = 'That branch has branches of its own';

const _refusalMessage =
    '"Master · B draft" cannot be deleted while 1 branch diverges from it '
    '(Master · B draft variant). Each of those branches records the step of '
    '"Master · B draft" it stopped matching, so re-pointing them at its parent '
    'would leave them rendering while describing a lineage that never '
    'happened. Delete those branches first, or delete this branch and '
    'everything descended from it.';

/// The action `_branch_bar.dart` passes, button for button.
Widget _refusalAction() {
  return Wrap(
    spacing: SkotiqTokens.spaceXs,
    runSpacing: SkotiqTokens.spaceXs,
    children: [
      SkotiqButton(
        label: 'Delete "Master · B draft" and its 1 branch',
        icon: SkotiqIcons.delete,
        variant: ButtonVariant.destructive,
        size: ButtonSize.small,
        onPressed: () {},
      ),
      SkotiqButton(
        label: 'Keep them',
        variant: ButtonVariant.outline,
        size: ButtonSize.small,
        onPressed: () {},
      ),
    ],
  );
}

Future<void> _pumpRefusal(
  WidgetTester tester,
  Size size, {
  bool withAction = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
          child: SkotiqAlert(
            severity: SkotiqAlertSeverity.warning,
            title: _refusalTitle,
            message: _refusalMessage,
            compact: true,
            action: withAction ? _refusalAction() : null,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('at 430px the title reads as a sentence, not a glyph column', (
    tester,
  ) async {
    await _pumpRefusal(tester, const Size(430, 900));

    final title = tester.getSize(find.text(_refusalTitle));

    // One glyph per line is what the break looks like from here: 35 characters
    // stacked at ~19px each ran past 600px tall in a column ~14px wide.
    expect(
      title.width,
      greaterThan(200),
      reason:
          'the title column collapsed to ${title.width}px, so the '
          'action took the width the text needed',
    );
    expect(
      title.height,
      lessThan(80),
      reason:
          'a title ${title.height}px tall at this width is wrapping '
          'per glyph rather than per word',
    );
  });

  testWidgets('at 430px the alert costs its action and nothing more', (
    tester,
  ) async {
    // The control the finding used: the same alert with no action, which
    // reflowed correctly at this width all along. An action may add its own
    // height to the banner; it may not multiply it.
    await _pumpRefusal(tester, const Size(430, 900), withAction: false);
    final withoutAction = tester.getSize(find.byType(SkotiqAlert)).height;

    await _pumpRefusal(tester, const Size(430, 900));
    final alert = tester.getSize(find.byType(SkotiqAlert));

    expect(
      alert.width,
      lessThanOrEqualTo(430),
      reason: 'the alert must fit the window it is shown in',
    );
    expect(
      alert.height,
      lessThan(withoutAction * 2),
      reason:
          'the same text without an action is ${withoutAction}px tall, so '
          '${alert.height}px means the text is wrapping around the action '
          'instead of beside it',
    );
  });

  testWidgets('at 430px the action reads under the title, above the message', (
    tester,
  ) async {
    await _pumpRefusal(tester, const Size(430, 900));

    final title = tester.getRect(find.text(_refusalTitle));
    final action = tester.getRect(find.byType(Wrap));
    final message = tester.getRect(find.text(_refusalMessage));

    expect(
      action.top,
      greaterThanOrEqualTo(title.bottom),
      reason: 'the refusal is named before the controls that answer it',
    );
    expect(
      action.bottom,
      lessThanOrEqualTo(message.top),
      reason:
          'and the controls stay where the reader already is — a panel '
          'that scrolls must not put them past its own fold',
    );
    expect(
      action.width,
      greaterThan(tester.getSize(find.byType(SkotiqAlert)).width / 2),
      reason:
          'the action was laid out ${action.width}px wide, so it is still '
          'squeezed into a fraction of the alert',
    );
  });

  testWidgets('on a wide alert the action still sits beside the text', (
    tester,
  ) async {
    await _pumpRefusal(tester, const Size(1400, 900));

    final text = tester.getTopRight(find.text(_refusalTitle));
    final action = tester.getTopLeft(find.byType(Wrap));

    expect(
      action.dx,
      greaterThanOrEqualTo(text.dx),
      reason:
          'the desktop shape is unchanged: title column first, action to '
          'its right',
    );
    expect(
      tester.getSize(find.byType(SkotiqAlert)).height,
      lessThan(200),
      reason: 'a wide alert stays a banner',
    );
  });

  testWidgets('at a mid width the text column keeps half the alert', (
    tester,
  ) async {
    await _pumpRefusal(tester, const Size(700, 900));

    final alert = tester.getSize(find.byType(SkotiqAlert));
    final title = tester.getSize(find.text(_refusalTitle));

    expect(
      title.width,
      greaterThan(alert.width * 0.35),
      reason:
          'a wide action must not starve the sentence it is answering: '
          'the title got ${title.width}px of ${alert.width}px',
    );
  });

  _intrinsicHostCases();
}

/// [AlertDialog] measures its content with `IntrinsicWidth`, and a
/// [LayoutBuilder] cannot answer an intrinsic query — the first build of this
/// component's width-adaptive body crashed every alert-with-action hosted in
/// a dialog (found by the startup-checkpoint recovery dialog's own tests).
/// The component answers the query itself now; this pins that an alert
/// renders inside the exact widget shape that threw.
void _intrinsicHostCases() {
  testWidgets('an alert with a wide action survives an IntrinsicWidth host', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: IntrinsicWidth(
              child: SkotiqAlert(
                severity: SkotiqAlertSeverity.error,
                title: _refusalTitle,
                message: _refusalMessage,
                action: _refusalAction(),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(_refusalTitle), findsOneWidget);
  });

  testWidgets('an alert with an action renders inside an AlertDialog', (
    tester,
  ) async {
    // A short message: the case pins the intrinsic-measuring HOST, and a
    // seven-line message at the dialog's collapsed width would overflow the
    // test viewport vertically — a harness artifact, not the defect.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AlertDialog(
            content: SkotiqAlert(
              severity: SkotiqAlertSeverity.warning,
              title: _refusalTitle,
              message: 'The checkpoint could not be resumed.',
              action: _refusalAction(),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(_refusalTitle), findsOneWidget);
  });

  // The width overrides above answer an `IntrinsicWidth` host; the HEIGHT
  // overrides answered zero, and an alert measured for its intrinsic height —
  // any child of an [IntrinsicHeight], used across ~8 screens for equal-height
  // card rows — collapsed to that zero and rendered invisibly. A plain banner
  // (no action) reads none of its own width, so it no longer defers its build
  // to the LayoutBuilder that cannot answer the query: it is an ordinary Row
  // that measures its own height, inside an IntrinsicHeight as anywhere else.
  testWidgets('a plain banner keeps its height inside an IntrinsicHeight', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const banner = SkotiqAlert(
      severity: SkotiqAlertSeverity.info,
      title: _refusalTitle,
      message: _refusalMessage,
    );

    // The alert as one child of an equal-height row, beside a short sibling: the
    // IntrinsicHeight measures the row's tallest child, and a banner reporting
    // zero would be flattened to the sibling's height.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 500,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: banner),
                    SizedBox(width: 12, height: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final hosted = tester.getSize(find.byType(SkotiqAlert)).height;

    // The same banner at the same width, laid out on its own: the height the
    // IntrinsicHeight host must not shrink.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 500 - 12, child: banner),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final natural = tester.getSize(find.byType(SkotiqAlert)).height;

    expect(
      natural,
      greaterThan(60),
      reason: 'a multi-line banner is well over one line tall',
    );
    expect(
      hosted,
      closeTo(natural, 1.0),
      reason:
          'the banner measured ${hosted}px inside an IntrinsicHeight against a '
          '${natural}px natural height — a shortfall is the zero-height collapse',
    );
  });
}

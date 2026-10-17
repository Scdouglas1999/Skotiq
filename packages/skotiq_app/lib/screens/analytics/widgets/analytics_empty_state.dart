import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The one empty state every Analytics tab uses.
///
/// Left to themselves the five tabs drift into four different structures —
/// centred vs left-aligned, icon vs star glyph vs nothing at all, sentences
/// with full stops and sentences without — and none of them offers the reader
/// anything to do. A tab with nothing to show is the most common thing a new
/// user sees, so it is the worst place for the app to look like five different
/// products.
///
/// The contract, enforced below: an icon, a short title with no terminal
/// punctuation, exactly one sentence ending in a full stop, and one action.
class AnalyticsEmptyState extends StatelessWidget {
  final IconData icon;

  /// Short noun phrase naming what is missing. A trailing full stop is
  /// stripped, so a translation that carries one still reads as a label.
  final String title;

  /// One sentence saying how the tab gets filled. A missing terminal stop is
  /// supplied here rather than in each caller — one punctuation rule, in one
  /// place, is the whole point of this widget.
  final String body;

  final String actionLabel;

  /// What the action does. Defaults to sending the reader to Imaging, which is
  /// where every one of these tabs gets its data from.
  final VoidCallback? onAction;

  const AnalyticsEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel = 'Go to Imaging',
    this.onAction,
  });

  /// The title as a label: never punctuated like a sentence.
  String get _label =>
      title.endsWith('.') ? title.substring(0, title.length - 1) : title;

  /// The body as a sentence: always punctuated like one.
  String get _sentence =>
      RegExp(r'[.!?]$').hasMatch(body.trimRight()) ? body : '$body.';

  @override
  Widget build(BuildContext context) {
    // The rendering is the design system's ONE empty state (05 §12): 28 px
    // muted glyph, `sectionTitle`, one `bodySm` sentence, one `secondary sm`
    // button, internal padding. What survives here is the Analytics-specific
    // CONTRACT — the punctuation rules above and the default "Go to Imaging"
    // destination — not a second visual pattern.
    final state = EmptyState(
      icon: icon,
      title: _label,
      body: _sentence,
      action: SkotiqButton(
        label: actionLabel,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        onPressed: onAction ?? () => GoRouter.maybeOf(context)?.go('/imaging'),
      ),
    );

    // An empty state is a Column of fixed-height parts, so a short viewport
    // overflows it -- a landscape phone gives this slot 167 px and the state
    // wants 174. 07 says not to scale the type down to make something fit and
    // to let it scroll instead, so it scrolls, and still centres whenever
    // there is room.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedHeight) return state;
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: state,
          ),
        );
      },
    );
  }
}

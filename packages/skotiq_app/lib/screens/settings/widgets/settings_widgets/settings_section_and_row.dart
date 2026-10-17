part of '../settings_widgets.dart';

/// One eyebrow-labelled group of setting rows on a Settings page (06 §Settings).
///
/// `[EYEBROW]` then a single [SkotiqPanel] run flush, with the rows
/// separated by hairlines and no hairline after the last one. The panel is
/// flush because the rows carry the padding: a padded panel around padded rows
/// is the panel-inside-a-panel the tonal ladder forbids.
class SettingsSection extends StatelessWidget {
  final String title;

  final List<Widget> children;

  final bool isMobile;

  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A search result can name this HEADING as well as a row: the
        // generated index cannot tell a `SettingsSection(title:)` from a
        // `SettingRow(title:)`, so "Dithering", "Meridian Flip" and
        // "Notification Events" are all offered as tappable results. Without
        // this the heading results opened the page at the top and marked
        // nothing — the dead end the row results exist to end.
        _HighlightedRow(
          active: SettingsRowHighlight.targets(context, title: title),
          child: Text(
            title.toUpperCase(),
            style: SkotiqTypography.eyebrow.copyWith(
              color: colors.textMuted,
            ),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqPanel(
          flush: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _separated(colors),
          ),
        ),
        const SizedBox(height: SkotiqTokens.space2xl),
      ],
    );
  }

  /// The rows with a hairline BETWEEN each pair and none at either end.
  ///
  /// The separator is drawn by the section, not by the row, because
  /// [SettingRow.isLast] is a fact about a list that only the list knows: every
  /// section that added a row without updating the previous row's flag grew a
  /// hairline sitting on the panel's bottom edge. Owning it here also means a
  /// conditional row (`if (!isRemoteMode) SettingRow(...)`) cannot leave a
  /// dangling rule behind it.
  List<Widget> _separated(SkotiqColors colors) {
    final result = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        result.add(Divider(height: 1, thickness: 1, color: colors.border));
      }
      result.add(children[i]);
    }
    return result;
  }
}

/// The row a settings search asked to be shown, published to every
/// [SettingRow] under the detail pane.
///
/// The index knows which ROW title matched, so the row id is published rather
/// than just the section: a section name alone opens a long page at the top
/// with no indication of where the match is.
class SettingsRowHighlight extends InheritedWidget {
  const SettingsRowHighlight({
    super.key,
    required this.rowTitle,
    required super.child,
  });

  /// Title of the row to reveal, or null when nothing is being sought.
  final String? rowTitle;

  static String? titleOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsRowHighlight>()
      ?.rowTitle;

  /// Is the row described by [title]/[subtitle] the one being sought?
  ///
  /// The subtitle counts because the generated search index cannot tell a
  /// `title:` from a `subtitle:` (its pattern has no left word boundary), so a
  /// short subtitle can legitimately be the term the operator recognised and
  /// tapped. Matching only on the title would open the page and then mark
  /// nothing, which is the state this whole mechanism exists to end.
  static bool targets(
    BuildContext context, {
    required String title,
    String? subtitle,
  }) {
    final sought = titleOf(context);
    if (sought == null) return false;
    return sought == title || sought == subtitle;
  }

  @override
  bool updateShouldNotify(SettingsRowHighlight oldWidget) =>
      oldWidget.rowTitle != rowTitle;
}

/// Scrolls its row into view and tints it while it is the search target.
class _HighlightedRow extends StatefulWidget {
  const _HighlightedRow({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_HighlightedRow> createState() => _HighlightedRowState();
}

class _HighlightedRowState extends State<_HighlightedRow> {
  @override
  void initState() {
    super.initState();
    if (widget.active) _reveal();
  }

  @override
  void didUpdateWidget(covariant _HighlightedRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _reveal();
  }

  /// After the frame that placed this row: the enclosing scroll view does not
  /// exist yet during build, and a settings page mounted by a search result is
  /// laid out in the same frame the target is chosen in.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Scrollable.maybeOf(context) == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.15,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      color: widget.active
          ? colors.primary.withValues(alpha: 0.14)
          : Colors.transparent,
      child: widget.child,
    );
  }
}

/// A single row on a Settings page: title (+ optional description) on the
/// left, its control right-aligned (06 §Settings).
///
/// 12 / 16 padding, title in `bodyMedium`, description in `caption`
/// `textSecondary`. The row draws no rule of its own — [SettingsSection] owns
/// the hairlines between its rows.
class SettingRow extends StatelessWidget {
  /// Ignored. A settings row is title + control: the mockup has no icon column
  /// and the old 36 px icon square was the "card" look the panel replaced. The
  /// parameter stays so the ~300 call sites keep compiling; wave 4 removes it.
  final IconData icon;

  /// Ignored, with [icon].
  final Color? iconColor;

  final String title;

  final String? subtitle;

  final Widget trailing;

  /// Ignored. [SettingsSection] draws the hairlines between its rows, so a row
  /// no longer needs to know where it sits in the list. Kept for call sites;
  /// wave 4 removes it.
  final bool isLast;

  final bool isMobile;

  /// If true, stack the trailing widget below the title on mobile

  final bool stackOnMobile;

  /// Optional field-level help. When supplied, a [helpAffordance] icon is
  /// rendered to the right of the [title] showing the rich tooltip from
  /// [helpFor]. Use only for genuinely non-obvious settings (the same bar as
  /// the imaging-panel rows); leave null for self-evident rows.
  final FieldHelpId? helpId;

  /// How much of the row the control column may take, against the label's 1.
  ///
  /// Default 1: label and control split the row, which is right for a switch or
  /// a 160 px dropdown. A wider control says so — the three 132 px theme cards
  /// need 416 px and wrapped onto a second row at an even split, and a picker
  /// that reflows is not the one the mockup shows.
  final int controlFlex;

  const SettingRow({
    super.key,
    required this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    required this.trailing,
    this.isLast = false,
    this.isMobile = false,
    this.stackOnMobile = false,
    this.helpId,
    this.controlFlex = 1,
  });

  /// The title text plus an optional trailing help affordance. Extracted so
  /// the row and stacked layouts share one definition of "how the title +
  /// help icon look".
  Widget _buildTitle(BuildContext context, SkotiqColors colors) {
    final titleText = Text(
      title,
      style:
          SkotiqTypography.bodyMedium.copyWith(color: colors.textPrimary),
    );
    final id = helpId;
    if (id == null) {
      return titleText;
    }
    final copy = helpFor(id);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(child: titleText),
        const SizedBox(width: SkotiqTokens.spaceXs),
        helpAffordance(
          context,
          title: copy.title,
          body: copy.body,
        ),
      ],
    );
  }

  /// Title + description: the left column of the row.
  Widget _label(BuildContext context, SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTitle(context, colors),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: SkotiqTypography.caption
                .copyWith(color: colors.textSecondary),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final shouldStack = isMobile && stackOnMobile;

    // The row's title and its trailing control are ONE thing to a screen
    // reader.
    //
    // Without this the switch is a correctly-toggled but ANONYMOUS node —
    // assistive tech can report that something is on without being able to say
    // which setting it is. Merging binds each control to the label beside it.
    return MergeSemantics(
      child: _HighlightedRow(
        active: SettingsRowHighlight.targets(
          context,
          title: title,
          subtitle: subtitle,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal:
                isMobile ? SkotiqTokens.spaceMd : SkotiqTokens.spaceLg,
            vertical: SkotiqTokens.spaceMd,
          ),
          child: shouldStack
              ? _buildStackedLayout(context, colors)
              : _buildRowLayout(context, colors),
        ),
      ),
    );
  }

  Widget _buildRowLayout(BuildContext context, SkotiqColors colors) {
    return Row(
      children: [
        Expanded(child: _label(context, colors)),
        const SizedBox(width: SkotiqTokens.space2xl),
        // Flexible (loose) bounds the trailing slot to the space the label's
        // Expanded leaves free. Finite controls (dropdowns, switches) keep their
        // intrinsic size; a content-sized [Wrap] trailing (e.g. the Integrations
        // plugin row's pill + Configure + switch cluster) gets a finite width to
        // wrap within instead of demanding unbounded width and overflowing.
        //
        // Align pins the control to the panel's right edge. Without it the
        // control sat at the LEFT of its flexible half — i.e. at the row's
        // horizontal midpoint — which looks correct at ~1600px only by
        // coincidence and stranded every control mid-screen with ~2100px of
        // empty panel beside it on an ultrawide monitor (audit 2026-07-29).
        Flexible(
          flex: controlFlex,
          child: Align(alignment: Alignment.centerRight, child: trailing),
        ),
      ],
    );
  }

  Widget _buildStackedLayout(BuildContext context, SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(context, colors),
        const SizedBox(height: SkotiqTokens.spaceMd),
        trailing,
      ],
    );
  }
}

/// Debounced toggle for settings rows backed by [SettingRow].

///

/// Use inside [SettingRow.trailing] when the row already supplies icon, title,

/// and subtitle. Wraps [SkotiqSwitch] with a 300 ms debounce so rapid

/// toggles coalesce to the final value before persisting.

///

/// For a self-contained label + switch row (no icon column), use

/// [SkotiqSwitchRow] instead. For a bare toggle with no label (toolbar,

/// table cell), use [SkotiqSwitch] directly.

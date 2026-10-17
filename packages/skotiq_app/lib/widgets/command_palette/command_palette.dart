import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';
import 'command_entry.dart';
import 'command_sources.dart';

export 'command_entry.dart' show CommandEntry, CommandGroup;

/// Opens the command palette (04-shell §7).
///
/// `showGeneralDialog` with a top-aligned child rather than `SkotiqDialog`,
/// which forces a title row, a close button and centre alignment. A palette
/// has none of those: its title is the thing you type, its close is Esc, and
/// it belongs near the field that opened it, not in the middle of the window.
Future<void> showCommandPalette(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss the command palette',
    barrierColor: Colors.black.withValues(alpha: _scrimOpacity),
    transitionDuration: SkotiqTokens.durationFast,
    pageBuilder: (context, animation, secondaryAnimation) =>
        const _CommandPaletteRoute(),
    transitionBuilder: (context, animation, secondary, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: SkotiqTokens.curveStandard,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.02),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// The dim behind a dialog or the palette.
const double _scrimOpacity = SkotiqTokens.opacityScrim;

class _CommandPaletteRoute extends StatelessWidget {
  const _CommandPaletteRoute();

  /// The palette sits below the top bar rather than in the middle of the
  /// window: it is the command field's own surface, and an operator who
  /// clicked the field looks where the field was.
  static const double _topInset = 96.0;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceLg,
        ).copyWith(top: _topInset),
        child: const CommandPalette(),
      ),
    );
  }
}

/// The palette itself. Public so a widget test can pump it without a router.
class CommandPalette extends ConsumerStatefulWidget {
  const CommandPalette({super.key});

  static const double width = 560.0;
  static const double inputHeight = 40.0;

  /// How tall the results list is allowed to get before it scrolls.
  static const double maxResultsHeight = 420.0;

  @override
  ConsumerState<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<CommandPalette> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// The input owns the focus, and its node intercepts the navigation keys.
  ///
  /// `onKeyEvent` ON THE NODE runs BEFORE the editable consumes the event,
  /// which is the only place these bindings work: a single-line `TextField`
  /// handles Arrow Up / Down itself (they move the caret to the start and end
  /// of the line) and returns `handled`, so an ancestor `CallbackShortcuts`
  /// never sees them and the palette's selection could not be moved from the
  /// keyboard at all.
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _handleKey);

  /// Index into the FLAT filtered list. The group eyebrows are not selectable,
  /// so selection is over entries, not over rendered rows.
  int _selected = 0;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final next = _controller.text.trim().toLowerCase();
      if (next == _query) return;
      // Any change to the query invalidates the selection: keeping the index
      // would leave the highlight on whatever now happens to sit at that
      // position, and Enter would run something the operator never read.
      setState(() {
        _query = next;
        _selected = 0;
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<CommandEntry> _entries() {
    final all = <CommandEntry>[
      ...buildScreenEntries(context),
      ...buildSettingEntries(context, _query),
      ...buildActionEntries(context, ref),
    ];
    final matched = all.where((e) => e.matches(_query)).toList();
    // Stable within a group: the sort key is (group, rank), and List.sort is
    // not stable, so the original position is the final tiebreak.
    final position = <String, int>{
      for (var i = 0; i < matched.length; i++) matched[i].id: i,
    };
    matched.sort((a, b) {
      final byGroup = a.group.index.compareTo(b.group.index);
      if (byGroup != 0) return byGroup;
      final byRank = a.rank(_query).compareTo(b.rank(_query));
      if (byRank != 0) return byRank;
      return position[a.id]!.compareTo(position[b.id]!);
    });
    return matched;
  }

  /// Arrow keys move the selection, Enter runs it, Esc closes the palette.
  ///
  /// Everything else is the operator typing, and belongs to the field.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final entries = _entries();
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1, entries.length);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1, entries.length);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (entries.isEmpty) return KeyEventResult.handled;
        _invoke(entries[_selected.clamp(0, entries.length - 1)]);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// Moves the selection, wrapping at both ends.
  ///
  /// Dart's `%` returns a non-negative result for a negative left operand, so
  /// Up from the first row lands on the last without a second branch.
  void _move(int delta, int length) {
    if (length == 0) return;
    setState(() => _selected = (_selected + delta) % length);
    _revealSelected();
  }

  /// Keeps the highlighted row inside the viewport when the arrows walk past
  /// its edge; without it the selection moves invisibly and Enter runs
  /// something off screen.
  void _revealSelected() {
    if (!_scrollController.hasClients) return;
    final target = (_selected * _CommandRow.height) -
        (CommandPalette.maxResultsHeight / 2) +
        _CommandRow.height;
    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: SkotiqTokens.durationFast,
      curve: SkotiqTokens.curveStandard,
    );
  }

  void _invoke(CommandEntry entry) {
    if (!entry.enabled) return;
    // Close first: a handler that pushes a route or opens a dialog must not
    // be doing it underneath a palette that is still dismissing.
    Navigator.of(context).pop();
    entry.invoke(context, ref);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final entries = _entries();
    final selected =
        _selected.clamp(0, entries.isEmpty ? 0 : entries.length - 1);

    // No ancestor Focus: the input takes the focus and keeps it, and its node
    // owns the key bindings. An `autofocus` Focus around this took the focus
    // FROM the field, which left the palette open with a caret nowhere and
    // typing doing nothing at all.
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: CommandPalette.width),
        child: Container(
          decoration: SkotiqDecorations.dialog(colors),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _input(colors),
              if (entries.isEmpty)
                _empty(colors)
              else
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: CommandPalette.maxResultsHeight,
                    ),
                    child: _results(colors, entries, selected),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _input(SkotiqColors colors) {
    return Container(
      height: CommandPalette.inputHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.search,
            size: SkotiqTokens.iconSm,
            color: colors.textMuted,
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              style: SkotiqTypography.input.copyWith(
                color: colors.textPrimary,
              ),
              cursorColor: colors.primary,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: context.l10n.text('commandPalettePlaceholder'),
                hintStyle: SkotiqTypography.input.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.all(SkotiqTokens.space2xl),
      child: Text(
        'Nothing matches "${_controller.text.trim()}".',
        style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
      ),
    );
  }

  Widget _results(
    SkotiqColors colors,
    List<CommandEntry> entries,
    int selected,
  ) {
    // One flat list with an eyebrow rendered above the first entry of each
    // group: a nested list would make the arrow keys walk a tree, and the
    // arrow keys must walk exactly what the eye reads.
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final startsGroup =
            index == 0 || entries[index - 1].group != entry.group;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (startsGroup)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  SkotiqTokens.spaceMd,
                  index == 0
                      ? SkotiqTokens.spaceSm
                      : SkotiqTokens.spaceMd,
                  SkotiqTokens.spaceMd,
                  SkotiqTokens.spaceXs,
                ),
                child: Text(
                  entry.group.label.toUpperCase(),
                  style: SkotiqTypography.eyebrow.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ),
            _CommandRow(
              entry: entry,
              isSelected: index == selected,
              colors: colors,
              onTap: () => _invoke(entry),
            ),
          ],
        );
      },
    );
  }
}

/// One result row.
///
/// Hover is a HOVER, not a selection. The row used to move the palette's
/// selection on `onEnter`, so a pointer resting anywhere over the list stole
/// the Enter target from the keyboard: Ctrl+K, "weath", Enter opened "Weather
/// safety" — the fifth row, the one under the cursor — instead of the first
/// result. 04 §7 gives the arrows the selection and nothing else moves it.
///
/// The two states are therefore drawn differently, because they mean
/// different things and one of them is what Enter will run: the selected row
/// takes the `primary` tint every selected thing in this language takes, and
/// a merely hovered row takes `surfaceHover`, like any hoverable row.
class _CommandRow extends StatefulWidget {
  final CommandEntry entry;
  final bool isSelected;
  final SkotiqColors colors;
  final VoidCallback onTap;

  const _CommandRow({
    required this.entry,
    required this.isSelected,
    required this.colors,
    required this.onTap,
  });

  /// Fixed so the arrow keys can compute where the selection is without
  /// measuring every row.
  static const double height = 36.0;

  @override
  State<_CommandRow> createState() => _CommandRowState();
}

class _CommandRowState extends State<_CommandRow> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (!mounted || _hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final isSelected = widget.isSelected;
    final colors = widget.colors;
    final foreground = entry.enabled
        ? (isSelected ? colors.textPrimary : colors.textSecondary)
        : colors.textMuted.withValues(
            alpha: SkotiqTokens.opacityDisabled,
          );
    final hint = entry.enabled ? entry.hint : entry.disabledReason;

    return Semantics(
      button: true,
      enabled: entry.enabled,
      selected: isSelected,
      label: hint == null ? entry.label : '${entry.label}, $hint',
      child: MouseRegion(
        cursor:
            entry.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: GestureDetector(
          onTap: entry.enabled ? widget.onTap : null,
          child: Container(
            height: _CommandRow.height,
            margin: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm,
            ),
            decoration: BoxDecoration(
              color: isSelected
                  ? colors.primary.withValues(
                      alpha: SkotiqTokens.opacityAccentTint,
                    )
                  : (_hovered && entry.enabled
                      ? colors.surfaceHover
                      : Colors.transparent),
              borderRadius: SkotiqTokens.borderRadiusSm,
            ),
            child: Row(
              children: [
                Icon(
                  entry.icon,
                  size: SkotiqTokens.iconSm,
                  color: entry.enabled ? colors.textMuted : foreground,
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    entry.label,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: foreground,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                if (hint != null) ...[
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Text(
                    hint,
                    style: SkotiqTypography.captionSm.copyWith(
                      color: colors.textMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

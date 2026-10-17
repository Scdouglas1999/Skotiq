// The Notes inspector tab (spec §8).
//
// Two note surfaces live here because they answer different questions:
//   * [TargetNotesSection] — the database-backed journal entries attached to
//     the TARGET ("M31 collected 40 frames over three nights"), shown only
//     for [TargetHeaderNode].
//   * the node comment editor — the free-text [SequenceNode.comment] the
//     tree already renders as a muted italic line under the row. Nothing in
//     the app edited it before this tab.
//
// The comment commits on focus loss, Ctrl/Cmd+Enter, or unmount through the
// canonical `currentSequenceProvider.notifier.updateNode` path, guarded by
// `canEditSequenceProvider` and wrapped in `withSequenceMutation` like every
// other inspector edit. "No comment" is stored as `''` — every node's
// `copyWith(comment:)` is keep-or-replace so null cannot clear it, and both
// the tree's italic line and the tab's dot check `isNotEmpty`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/sequence_mutator_helper.dart';
import 'node_property_widgets.dart';
import 'notes_panel.dart';

class NodeNotesTab extends ConsumerWidget {
  final SkotiqColors colors;
  final SequenceNode node;
  final ScrollController? scrollController;
  final bool isMobile;

  const NodeNotesTab({
    super.key,
    required this.colors,
    required this.node,
    this.scrollController,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(canEditSequenceProvider);
    final node = this.node;

    // The edit lock mirrors `_NodeEditor`: dim outside the scroll view,
    // pointer-blocking inside it, so a locked (running) sequence still lets
    // the operator READ their notes — and the sheet keeps scrolling on
    // mobile.
    return Material(
      type: MaterialType.transparency,
      child: Opacity(
        opacity: canEdit ? 1.0 : SkotiqTokens.opacityDisabled,
        child: SingleChildScrollView(
          controller: scrollController,
          padding: EdgeInsets.all(
            isMobile ? SkotiqTokens.spaceXl : SkotiqTokens.spaceLg,
          ),
          child: IgnorePointer(
            ignoring: !canEdit,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (node is TargetHeaderNode) ...[
                  TargetNotesSection(
                    targetId: node.targetName,
                    colors: colors,
                  ),
                  const SizedBox(height: SkotiqTokens.space2xl),
                ],
                NodePropertyField(
                  colors: colors,
                  label: 'Comment',
                  helpText: 'Shown as an italic line under this node in the '
                      'tree. Ctrl+Enter saves.',
                  child: _NodeCommentEditor(node: node, colors: colors),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Multi-line editor for [SequenceNode.comment]. Commits happen three ways:
/// focus loss and Ctrl/Cmd+Enter go through [_commit] (a live context, so
/// failures can still reach a snackbar); selection switches and unmounts go
/// through [_commitText] on a microtask — provider writes are illegal
/// mid-build (`didUpdateWidget`) and `ref` is dead after `dispose`, so both
/// deferred paths write through the container captured in `initState` and
/// re-read the LIVE comment before comparing (the interactive commit may
/// already have landed the same text — re-checking the stale widget prop
/// would double-commit and mint a duplicate undo entry).
class _NodeCommentEditor extends ConsumerStatefulWidget {
  final SequenceNode node;
  final SkotiqColors colors;

  const _NodeCommentEditor({required this.node, required this.colors});

  @override
  ConsumerState<_NodeCommentEditor> createState() => _NodeCommentEditorState();
}

class _NodeCommentEditorState extends ConsumerState<_NodeCommentEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  /// Captured in `initState` while `context` is still safe for inherited
  /// lookup — `dispose()` runs after deactivate, where `containerOf` throws.
  late final ProviderContainer _container;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _controller = TextEditingController(text: widget.node.comment ?? '');
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    // Unmount mid-edit is still a commit opportunity — the focus listener
    // dies with the widget, so the pending text would otherwise vanish. The
    // write runs on a microtask: synchronous provider writes from dispose
    // are as illegal as mid-build ones.
    final node = widget.node;
    final text = _controller.text;
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    Future.microtask(() => _commitText(_container, node, text));
    super.dispose();
  }

  @override
  void didUpdateWidget(_NodeCommentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.id != widget.node.id) {
      // Selection moved while the field may hold uncommitted text: commit it
      // against the node it was typed on — carrying it onto the new node's
      // comment would silently misattribute the note. Deferred: writing
      // currentSequenceProvider inside didUpdateWidget trips Riverpod's
      // "modified during build" assert.
      final oldNode = oldWidget.node;
      final pendingText = _controller.text;
      Future.microtask(() => _commitText(_container, oldNode, pendingText));
      _controller.text = widget.node.comment ?? '';
    } else if (!_focusNode.hasFocus &&
        widget.node.comment != oldWidget.node.comment) {
      // The comment changed under us (undo/redo): adopt the new text unless
      // the user is mid-edit — typing must not lose its place because the
      // model re-emitted the same node.
      _controller.text = widget.node.comment ?? '';
    }
  }

  void _handleFocusChange() {
    if (_focused != _focusNode.hasFocus) {
      setState(() => _focused = _focusNode.hasFocus);
    }
    if (!_focusNode.hasFocus) _commit();
  }

  /// Interactive commit (focus loss, Ctrl/Cmd+Enter): a live context, so the
  /// shared mutation wrapper can still surface errors as snackbars. The
  /// comparison reads the comment from the provider — `widget.node.comment`
  /// is the value this build was handed and may lag the commit that just ran.
  void _commit() {
    final node = widget.node;
    final text = _controller.text.trim();
    final current =
        ref.read(currentSequenceProvider)?.nodes[node.id]?.comment ?? '';
    if (text == current) return;
    if (!ref.read(canEditSequenceProvider)) return;
    withSequenceMutation(
      context,
      ref,
      operationName: 'update note',
      action: () async {
        ref.read(currentSequenceProvider.notifier).updateNode(
              node.copyWith(comment: text),
            );
      },
    );
  }

  /// Deferred commit: writes [raw] as [node]'s comment via [container]
  /// (valid where `ref` and `context` are not), skipping the write when the
  /// live comment already says the same thing — the dedupe that keeps a
  /// focus-loss commit and a node-switch commit from landing twice.
  static void _commitText(
    ProviderContainer container,
    SequenceNode node,
    String raw,
  ) {
    final text = raw.trim();
    final current =
        container.read(currentSequenceProvider)?.nodes[node.id]?.comment ?? '';
    if (text == current) return;
    if (!container.read(canEditSequenceProvider)) return;
    container.read(currentSequenceProvider.notifier).updateNode(
          node.copyWith(comment: text),
        );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Node comment',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceMd,
          vertical: SkotiqTokens.spaceSm,
        ),
        decoration: SkotiqDecorations.field(widget.colors, focused: _focused),
        // Enter inserts a newline in a multiline field — `onSubmitted` never
        // fires there — so the keyboard commit is Ctrl/Cmd+Enter via
        // CallbackShortcuts, which sees the keys before the field eats them.
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                _commit,
            const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                _commit,
          },
          child: TextField(
            key: const ValueKey('node-comment-field'),
            controller: _controller,
            focusNode: _focusNode,
            minLines: 4,
            maxLines: 10,
            // A tap anywhere else — another tab, another row — is the
            // focus-loss commit; without this the field would keep focus until
            // it unmounted and the half-typed note would silently vanish.
            onTapOutside: (_) => _focusNode.unfocus(),
            style: SkotiqTypography.bodySm.copyWith(
              color: widget.colors.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'Add a note for this node…',
              hintStyle: SkotiqTypography.bodySm.copyWith(
                color: widget.colors.textMuted,
              ),
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
      ),
    );
  }
}

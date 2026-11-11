part of '../sequencer_screen.dart';

class _SnippetPaletteContent extends ConsumerWidget {
  final SkotiqColors colors;

  const _SnippetPaletteContent({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SnippetPalette(
      colors: colors,
      onSnippetTap: (snippet) => insertIntoTree(
        context,
        ref,
        snippet,
        parentId: ref.read(selectedNodeIdProvider),
      ),
    );
  }
}

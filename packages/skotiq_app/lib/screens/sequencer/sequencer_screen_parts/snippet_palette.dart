part of '../sequencer_screen.dart';

class _SnippetPaletteContent extends ConsumerWidget {
  final SkotiqColors colors;

  const _SnippetPaletteContent({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SnippetPalette(
      colors: colors,
      onSnippetTap: (snippet) {
        // insertSnippet can throw SnippetDeserializationException for
        // unknown node types and SequenceLockedException while a run is in
        // flight. Uncaught, either pops a red Flutter error overlay, so both
        // are caught with user-visible feedback: the mutator helper renders a
        // structured dialog + snackbar.
        withSequenceMutation(
          context,
          ref,
          operationName: 'insert snippet',
          action: () async {
            final selectedId = ref.read(selectedNodeIdProvider);
            final profile = ref.read(activeEquipmentProfileProvider);
            ref.read(currentSequenceProvider.notifier).insertSnippet(
                  snippet,
                  parentId: selectedId,
                  profileFilterNames: profile?.filterNames,
                );
          },
        );
      },
    );
  }
}

/// A panel that can collapse to a thin icon strip or expand to full content

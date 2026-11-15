// The "Starters" section: the bundled, read-only sample sequences, above the
// templates, so a beginner can load and run a complete sequence in one tap.
// Cards clone the sample into the Builder through [SampleSequenceService].
part of '../templates_tab.dart';

/// The bundled starters. It loads them lazily; [searchQuery] filters the
/// cards so the toolbar's search covers starters and templates alike.
class _StartersSection extends ConsumerWidget {
  const _StartersSection({required this.searchQuery});

  final String searchQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final samplesAsync = ref.watch(sampleSequencesProvider);

    return samplesAsync.when(
      data: (samples) {
        final q = searchQuery.toLowerCase();
        final filtered = q.isEmpty
            ? samples
            : [
                for (final s in samples)
                  if (s.displayName.toLowerCase().contains(q) ||
                      s.description.toLowerCase().contains(q))
                    s,
              ];

        // A search that hides every starter drops the section; the templates
        // section below still says when nothing matches.
        if (filtered.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: SkotiqTokens.space2xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Using one calls loadSequence, which REPLACES the sequence in
              // the Builder (after a confirm when it has unsaved changes).
              const _CatalogSectionHead(
                title: 'Starters',
                clause: 'Ready-to-run samples. Using one replaces your '
                    'current sequence.',
              ),
              _CardGrid(
                children: [
                  for (final sample in filtered) _StarterCard(sample: sample),
                ],
              ),
            ],
          ),
        );
      },
      loading: () => const Padding(
        padding: SkotiqTokens.padding2xl,
        child: Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
        ),
      ),
      error: (error, _) => EmptyState.error(
        title: 'Could not load the starters',
        body: userFacingError(error),
        onRetry: () => ref.invalidate(sampleSequencesProvider),
      ),
    );
  }
}

class _StarterCard extends ConsumerWidget {
  const _StarterCard({required this.sample});

  final SampleSequence sample;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Using a starter replaces the current sequence, so not while it runs.
    final canEdit = ref.watch(canEditSequenceProvider);
    return _CatalogCard(
      icon: _iconFor(sample.iconName),
      title: sample.displayName,
      facts: '${sample.skillLevel.label} · ${sample.expectedTotalTime}',
      description: sample.description,
      primary: SkotiqButton(
        onPressed: canEdit ? () async => _useStarter(context, ref) : null,
        label: 'Use this starter',
        icon: LucideIcons.copy,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        semanticsHint: canEdit
            ? 'Replaces the sequence currently in the builder.'
            : 'The sequence is running, so the builder cannot be replaced.',
      ),
    );
  }

  Future<void> _useStarter(BuildContext context, WidgetRef ref) async {
    final host = ref.backendScope();
    final service = ref.read(sampleSequenceServiceProvider);
    final notifier = ref.read(currentSequenceProvider.notifier);

    // A starter names the standard filters; a wheel that spells one
    // differently ("Lum", "Red") gets the plan in its own spelling.
    final starter = service.cloneForUse(sample);
    final filterRenames = filterRenamesFor(
      starter,
      ref.read(effectiveFiltersProvider),
    );
    final cloned = renameFilters(starter, filterRenames);
    try {
      notifier.loadSequence(cloned);
    } on UnsavedChangesException catch (e) {
      if (!context.mounted) return;
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard unsaved changes?'),
          content: ConstrainedBox(
            constraints:
                AdaptiveDialogConstraints.hybrid(ctx, designMaxWidth: 440),
            child: Text('"${e.currentSequenceName}" has unsaved changes. '
                'Loading "${sample.displayName}" will discard them.'),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            SkotiqButton(
              label: 'Discard and load',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      if (discard != true || !context.mounted || host.isStale) {
        return;
      }
      try {
        notifier.loadSequence(cloned, discardUnsaved: true);
      } on SequenceLockedException catch (e) {
        if (context.mounted) context.showErrorSnackBar(e.message);
        return;
      }
    } on SequenceLockedException catch (e) {
      if (context.mounted) context.showErrorSnackBar(e.message);
      return;
    }

    // Switch to Builder tab so the user sees the loaded sequence.
    ref.read(sequencerTabProvider.notifier).state = 0;

    context.showSuccessSnackBar(
      filterRenames.isEmpty
          ? 'Loaded "${sample.displayName}" into the builder'
          : 'Loaded "${sample.displayName}" into the builder with your '
              'filter names: ${[
              for (final MapEntry(:key, :value) in filterRenames.entries)
                '$key → $value',
            ].join(', ')}',
    );
  }

  static IconData _iconFor(String name) {
    switch (name) {
      case 'camera':
        return LucideIcons.camera;
      case 'moon':
        return LucideIcons.moon;
      case 'aperture':
        return LucideIcons.aperture;
      case 'circle':
        return LucideIcons.circle;
      case 'layers':
        return LucideIcons.layers;
      default:
        return LucideIcons.fileText;
    }
  }
}

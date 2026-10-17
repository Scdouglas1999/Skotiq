// The "Starters" section: the bundled, read-only SAMPLE sequences that used
// to live in a separate "Samples" tab. They are merged into the Templates tab
// here, delineated as built-in starters (with a "Starter" badge) above the
// user's saved templates, so beginners can load-and-run a complete sequence
// in one tap. Cards clone the sample into the current builder via the shared
// [SampleSequenceService] (kept in skotiq_core).
part of '../templates_tab.dart';

/// Built-in starter sequences section. Always rendered (it lazily loads the
/// bundled samples); the [searchQuery] filters the cards so the parent's
/// search box covers starters and templates alike.
class _StartersSection extends ConsumerWidget {
  final SkotiqColors colors;
  final String searchQuery;
  final bool isMobile;

  const _StartersSection({
    required this.colors,
    required this.searchQuery,
    required this.isMobile,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final samplesAsync = ref.watch(sampleSequencesProvider);

    return samplesAsync.when(
      data: (samples) {
        var filtered = samples;
        if (searchQuery.isNotEmpty) {
          final q = searchQuery.toLowerCase();
          filtered = samples
              .where((s) =>
                  s.displayName.toLowerCase().contains(q) ||
                  s.description.toLowerCase().contains(q))
              .toList();
        }

        // When a search hides every starter, drop the whole section so we
        // don't show an empty header — the templates section below still
        // renders its own "no results" state.
        if (filtered.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TemplatesSectionHeader(
              colors: colors,
              icon: LucideIcons.library,
              title: 'Starters',
              // "copy one into your current sequence" read as append/merge.
              // _useStarter calls loadSequence, which REPLACES the loaded
              // sequence outright (it only pauses to confirm when the current
              // one is dirty).
              subtitle: 'Bundled, ready-to-run sample sequences. Loading one '
                  'replaces your current sequence.',
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final crossAxisCount = _columnsForWidth(constraints.maxWidth);
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: isMobile ? 1.3 : 1.5,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) => _StarterCard(
                    sample: filtered[index],
                    colors: colors,
                  ),
                );
              },
            ),
            const SizedBox(height: 28),
          ],
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => _StartersError(colors: colors, error: error),
    );
  }

  static int _columnsForWidth(double width) {
    if (width < 640) return 1;
    if (width < 1100) return 2;
    return 3;
  }
}

class _StarterCard extends ConsumerWidget {
  final SampleSequence sample;
  final SkotiqColors colors;

  const _StarterCard({required this.sample, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // "Replace with this starter" calls loadSequence, which
    // replaces the current sequence — disable while running.
    final canEdit = ref.watch(canEditSequenceProvider);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: SkotiqDecorations.statusChip(
                    _skillColor(colors, sample.skillLevel),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    bordered: false,
                  ),
                  child: Icon(
                    _iconFor(sample.iconName),
                    color: _skillColor(colors, sample.skillLevel),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sample.displayName,
                        style: SkotiqTypography.h5
                            .copyWith(color: colors.textPrimary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _StarterBadge(colors: colors),
                          const SizedBox(width: 6),
                          _SkillBadge(
                            colors: colors,
                            skillLevel: sample.skillLevel,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  LucideIcons.clock,
                                  size: 11,
                                  color: colors.textMuted,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    sample.expectedTotalTime,
                                    style: TextStyle(
                                      fontSize: SkotiqTypography.fontSize11,
                                      color: colors.textMuted,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  sample.description,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Secondary, and sized to its words. Six starter cards on one
            // view meant six full-width PRIMARY buttons; 02 rule 4 allows one
            // primary per page and it is Start, in the header.
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                onPressed:
                    canEdit ? () async => _useStarter(context, ref) : null,
                label: 'Use this starter',
                icon: LucideIcons.copy,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                semanticsHint: canEdit
                    ? 'Replaces the sequence currently in the builder.'
                    : 'The sequence is running, so the builder cannot be '
                        'replaced.',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _useStarter(BuildContext context, WidgetRef ref) async {
    final authority = ref.read(backendProvider);
    final service = ref.read(sampleSequenceServiceProvider);
    final notifier = ref.read(currentSequenceProvider.notifier);

    final cloned = service.cloneForUse(sample);
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
      if (discard != true ||
          !context.mounted ||
          !identical(ref.read(backendProvider), authority)) {
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
      'Loaded "${sample.displayName}" into the builder',
    );
  }

  static Color _skillColor(
    SkotiqColors colors,
    SampleSequenceSkillLevel level,
  ) {
    switch (level) {
      case SampleSequenceSkillLevel.beginner:
        return colors.success;
      case SampleSequenceSkillLevel.intermediate:
        return colors.primary;
      case SampleSequenceSkillLevel.advanced:
        return colors.warning;
    }
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

/// Small "Starter" badge that distinguishes the bundled samples from the
/// user's own saved templates within the merged tab.
class _StarterBadge extends StatelessWidget {
  final SkotiqColors colors;

  const _StarterBadge({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: SkotiqDecorations.statusChip(
        colors.accent,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Text(
        'Starter',
        style: TextStyle(
          fontSize: SkotiqTypography.fontSize10,
          fontWeight: FontWeight.w600,
          color: colors.accent,
        ),
      ),
    );
  }
}

class _SkillBadge extends StatelessWidget {
  final SkotiqColors colors;
  final SampleSequenceSkillLevel skillLevel;

  const _SkillBadge({required this.colors, required this.skillLevel});

  @override
  Widget build(BuildContext context) {
    final color = _StarterCard._skillColor(colors, skillLevel);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: SkotiqDecorations.statusChip(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Text(
        skillLevel.label,
        style: TextStyle(
          fontSize: SkotiqTypography.fontSize10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _StartersError extends StatelessWidget {
  final SkotiqColors colors;
  final Object error;

  const _StartersError({required this.colors, required this.error});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.alertTriangle, size: 32, color: colors.error),
            const SizedBox(height: 12),
            Text(
              'Failed to load starter sequences',
              style:
                  SkotiqTypography.h5.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

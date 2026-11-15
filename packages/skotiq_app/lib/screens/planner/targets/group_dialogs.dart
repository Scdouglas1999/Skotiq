part of 'plan_targets_tab.dart';

class _GroupFormResult {
  const _GroupFormResult({required this.name, this.description});
  final String name;
  final String? description;
}

/// Names a new group or renames an existing one.
class _GroupFormDialog extends StatefulWidget {
  const _GroupFormDialog({this.existing});

  final Project? existing;

  @override
  State<_GroupFormDialog> createState() => _GroupFormDialogState();
}

class _GroupFormDialogState extends State<_GroupFormDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _notes =
      TextEditingController(text: widget.existing?.description ?? '');
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Give the group a name');
      return;
    }
    final notes = _notes.text.trim();
    Navigator.of(context).pop(
      _GroupFormResult(name: name, description: notes.isEmpty ? null : notes),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return SkotiqDialog(
      title: editing ? 'Rename group' : 'New group',
      width: 480,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          key: const ValueKey('plan-group-form-save'),
          label: editing ? 'Save' : 'Create group',
          onPressed: _submit,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FormRow(
            label: 'Name',
            child: SkotiqTextField(
              key: const ValueKey('plan-group-form-name'),
              controller: _name,
              hint: 'Fall galaxies',
              autofocus: true,
              errorText: _nameError,
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          FormRow(
            label: 'Notes',
            child: SkotiqTextField(controller: _notes, maxLines: 3),
          ),
        ],
      ),
    );
  }
}

/// Picks a target to add: one already saved, or an object from the installed
/// sky catalog, which is saved first. Pops the target's id.
class _AddTargetDialog extends ConsumerStatefulWidget {
  const _AddTargetDialog({required this.hiddenTargetIds, this.groupName});

  /// Saved targets left out because the group already holds them.
  final Set<int> hiddenTargetIds;

  /// The group the pick goes into; null adds to the list of all targets, where
  /// only catalog objects are new.
  final String? groupName;

  @override
  ConsumerState<_AddTargetDialog> createState() => _AddTargetDialogState();
}

class _AddTargetDialogState extends ConsumerState<_AddTargetDialog> {
  String _query = '';
  String? _adding;
  String? _addError;

  Future<void> _addFromCatalog(CatalogSearchResult match) async {
    setState(() {
      _adding = match.catalogId;
      _addError = null;
    });
    try {
      final target =
          await ref.read(targetLibraryServiceProvider).ensureCatalogTarget(
                targetName: match.name,
                raHours: match.ra / 15.0,
                decDegrees: match.dec,
                catalogId: match.catalogId,
                objectType: match.type,
                constellation: match.constellation,
                magnitude: match.magnitude,
              );
      if (!mounted) return;
      Navigator.of(context).pop(target.id);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _adding = null;
        _addError = userFacingError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final targetsAsync = ref.watch(allDbTargetsProvider);
    final catalog = ref.watch(installedCatalogSearchProvider(_query));
    final intoGroup = widget.groupName != null;

    return SkotiqDialog(
      title: intoGroup ? 'Add target to "${widget.groupName}"' : 'Add target',
      width: 640,
      height: 560,
      scrollableBody: false,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkotiqSearchField(
            key: const ValueKey('plan-add-target-search'),
            hint: intoGroup
                ? 'Search your targets or the sky catalog'
                : 'Search the sky catalog: M31, NGC 7000, IC 1805',
            autofocus: true,
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
          if (_addError != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            SkotiqBanner(
              title: 'Could not add the target',
              message: _addError,
              tone: BannerTone.error,
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceMd),
          Expanded(
            child: targetsAsync.when(
              loading: () => const Center(
                child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 24),
              ),
              error: (error, _) => EmptyState.error(
                title: 'Could not load your targets',
                body: userFacingError(error),
                onRetry: () => ref.invalidate(allDbTargetsProvider),
              ),
              data: (targets) {
                final query = _query.toLowerCase();
                // Outside a group every saved target is already listed, so
                // only the catalog has something to add.
                final saved = !intoGroup
                    ? const <DbTarget>[]
                    : (targets
                        .where((t) => !widget.hiddenTargetIds.contains(t.id))
                        .where(
                          (t) =>
                              query.isEmpty ||
                              t.name.toLowerCase().contains(query),
                        )
                        .toList()
                      ..sort(
                        (a, b) => a.name
                            .toLowerCase()
                            .compareTo(b.name.toLowerCase()),
                      ));
                final savedKeys = {
                  for (final t in targets) t.name.trim().toUpperCase(),
                  for (final t in targets)
                    if (t.catalogId != null) t.catalogId!.trim().toUpperCase(),
                };
                final fromCatalog = [
                  for (final m
                      in catalog.valueOrNull ?? const <CatalogSearchResult>[])
                    if (!savedKeys.contains(m.name.trim().toUpperCase()) &&
                        !savedKeys.contains(m.catalogId.trim().toUpperCase()))
                      m,
                ];

                if (saved.isEmpty && fromCatalog.isEmpty) {
                  final catalogReady = ref
                      .watch(catalogStateProvider)
                      .dsoCatalogStatus
                      .isInstalled;
                  if (!catalogReady) {
                    return EmptyState.compact(
                      icon: LucideIcons.download,
                      title: 'No sky catalog installed',
                      body: 'Install the OpenNGC catalog once and any object '
                          'can be added from here.',
                      action: SkotiqButton(
                        label: 'Open catalog settings',
                        size: ButtonSize.small,
                        variant: ButtonVariant.secondary,
                        onPressed: () {
                          final router = GoRouter.of(context);
                          Navigator.of(context).pop();
                          router.go(AppRoute.plateSolvingSettings.path);
                        },
                      ),
                    );
                  }
                  return EmptyState.compact(
                    icon:
                        _query.isEmpty ? LucideIcons.search : LucideIcons.searchX,
                    title: _query.isEmpty
                        ? 'Search for an object'
                        : 'Nothing matches "$_query"',
                    body: _query.isEmpty
                        ? 'Type a name or catalog number, such as M31 or '
                            'NGC 7000.'
                        : 'Check the spelling, or try its catalog number.',
                  );
                }

                return ListView(
                  children: [
                    for (final t in saved)
                      ListRow(
                        key: ValueKey('plan-add-saved-${t.id}'),
                        title: t.name,
                        subtitle: t.objectType,
                        onTap: () => Navigator.of(context).pop(t.id),
                      ),
                    if (fromCatalog.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          SkotiqTokens.spaceSm,
                          SkotiqTokens.spaceMd,
                          SkotiqTokens.spaceSm,
                          SkotiqTokens.spaceXs,
                        ),
                        child: Text(
                          'FROM THE SKY CATALOG',
                          style: SkotiqTypography.eyebrow
                              .copyWith(color: colors.textMuted),
                        ),
                      ),
                      for (final m in fromCatalog)
                        ListRow(
                          key: ValueKey('plan-add-catalog-${m.catalogId}'),
                          title: m.name,
                          subtitle: [
                            m.type,
                            if (m.constellation?.isNotEmpty ?? false)
                              m.constellation!,
                            if (m.magnitude != null)
                              'mag ${m.magnitude!.toStringAsFixed(1)}',
                          ].join(' · '),
                          trailing: _adding == m.catalogId ? 'Adding' : null,
                          onTap:
                              _adding == null ? () => _addFromCatalog(m) : null,
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

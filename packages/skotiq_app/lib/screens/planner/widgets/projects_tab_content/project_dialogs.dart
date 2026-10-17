part of '../projects_tab_content.dart';

// Create / edit project dialog.

class _ProjectFormDialog extends StatefulWidget {
  final Project? existing;

  const _ProjectFormDialog({this.existing});

  @override
  State<_ProjectFormDialog> createState() => _ProjectFormDialogState();
}

class _ProjectFormDialogState extends State<_ProjectFormDialog> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _descCtl;
  String? _nameError;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: widget.existing?.name ?? '');
    _descCtl = TextEditingController(text: widget.existing?.description ?? '');
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _descCtl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Project name is required');
      return;
    }
    final desc = _descCtl.text.trim();
    Navigator.of(context).pop(
      _ProjectFormResult(
        name: name,
        description: desc.isEmpty ? null : desc,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqDialog(
      title: _isEdit ? 'Edit project' : 'New project',
      icon: _isEdit ? LucideIcons.pencil : LucideIcons.folderPlus,
      width: 480,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: _isEdit ? 'Save' : 'Create',
          icon: LucideIcons.check,
          size: ButtonSize.small,
          onPressed: _submit,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Group several targets into a multi-night project to track '
            'integration goals across clear nights.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          SkotiqTextField(
            controller: _nameCtl,
            label: 'Name',
            hint: 'e.g. Winter Nebulae',
            prefixIcon: LucideIcons.folder,
            errorText: _nameError,
            onChanged: (_) {
              if (_nameError != null) setState(() => _nameError = null);
            },
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqTextField(
            controller: _descCtl,
            label: 'Description (optional)',
            hint: 'Notes about this project',
            maxLines: 3,
          ),
        ],
      ),
    );
  }
}

// Add-target dialog: searchable catalog picker.

class _AddTargetDialog extends ConsumerStatefulWidget {
  final Set<int> attachedTargetIds;

  const _AddTargetDialog({required this.attachedTargetIds});

  @override
  ConsumerState<_AddTargetDialog> createState() => _AddTargetDialogState();
}

class _AddTargetDialogState extends ConsumerState<_AddTargetDialog> {
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';
  String? _adding;
  String? _addError;

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  /// Creates (or resolves) a library row for a sky-catalog object and returns
  /// its id to the caller, which attaches it to the project.
  Future<void> _addFromCatalog(CatalogSearchResult match) async {
    setState(() {
      _adding = match.catalogId;
      _addError = null;
    });
    try {
      final target =
          await ref.read(targetLibraryServiceProvider).ensureCatalogTarget(
                targetName: match.name,
                // The library stores RA in decimal HOURS; catalog search
                // results carry degrees.
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
        _addError = 'Could not add ${match.name}: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final targetsAsync = ref.watch(allDbTargetsProvider);
    final catalogAsync = ref.watch(installedCatalogSearchProvider(_query));

    return SkotiqDialog(
      title: 'Add target',
      icon: LucideIcons.plus,
      width: 560,
      height: 560,
      scrollableBody: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkotiqTextField(
            controller: _searchCtl,
            hint: 'Search your targets or the sky catalog…',
            prefixIcon: LucideIcons.search,
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
          if (_addError != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            SkotiqBanner(
                title: 'Could not add target',
                message: _addError!,
                tone: BannerTone.error),
          ],
          const SizedBox(height: SkotiqTokens.spaceMd),
          Expanded(
            child: targetsAsync.when(
              loading: () => const Center(
                child: const SizedBox(
                  width: SkotiqTokens.iconLg,
                  height: SkotiqTokens.iconLg,
                  child: const SkotiqMark(
                      motion: SkotiqMarkMotion.loading, size: 24),
                ),
              ),
              error: (err, _) => SkotiqBanner(
                  title: 'Failed to load targets',
                  message: err.toString(),
                  tone: BannerTone.error),
              data: (targets) {
                final query = _query.toLowerCase();
                final available = targets
                    .where((t) => !widget.attachedTargetIds.contains(t.id))
                    .where((t) =>
                        query.isEmpty || t.name.toLowerCase().contains(query))
                    .toList()
                  ..sort((a, b) =>
                      a.name.toLowerCase().compareTo(b.name.toLowerCase()));

                // Sky-catalog objects that are not library rows yet. Names
                // already in the library are dropped so the same object never
                // appears in both lists.
                final libraryKeys = {
                  for (final t in targets) t.name.trim().toUpperCase(),
                  for (final t in targets)
                    if (t.catalogId != null) t.catalogId!.trim().toUpperCase(),
                };
                final newFromCatalog = (catalogAsync.valueOrNull ??
                        const <CatalogSearchResult>[])
                    .where((m) =>
                        !libraryKeys.contains(m.name.trim().toUpperCase()) &&
                        !libraryKeys.contains(m.catalogId.trim().toUpperCase()))
                    .toList(growable: false);

                if (available.isEmpty && newFromCatalog.isEmpty) {
                  // Nothing is bundled: the OpenNGC catalog is a download.
                  // On the fresh profile this whole finding is about, the
                  // library is empty AND no catalog exists, so telling the
                  // user to "search for an object" — or that nothing matches
                  // "M31" — is the same dead end in nicer words. There is
                  // nothing on this machine to match against. Say so, and
                  // offer the one action that changes it, the way the
                  // planner's own empty state (_FilteredEmptyState) already
                  // does.
                  final catalogReady = ref
                      .watch(catalogStateProvider)
                      .dsoCatalogStatus
                      .isInstalled;
                  if (!catalogReady) {
                    return EmptyState.compact(
                      icon: LucideIcons.download,
                      title: 'No sky catalog installed',
                      body: targets.isEmpty
                          ? 'Your target library is empty and the OpenNGC '
                              'catalog has not been downloaded, so there is '
                              'nothing here to search. Install it once and any '
                              'object can be added from this sheet.'
                          : 'The OpenNGC catalog has not been downloaded, so '
                              'only targets already in your library can be '
                              'found here.',
                      action: SkotiqButton(
                        label: 'Open catalog settings',
                        icon: LucideIcons.download,
                        size: ButtonSize.small,
                        onPressed: () {
                          final router = GoRouter.of(context);
                          Navigator.of(context).pop();
                          router.go('/settings/plate-solving');
                        },
                      ),
                    );
                  }
                  return EmptyState.compact(
                    icon:
                        _query.isEmpty ? LucideIcons.star : LucideIcons.searchX,
                    title: targets.isEmpty
                        ? 'No targets yet'
                        : 'No matching targets',
                    body: _query.isEmpty
                        ? 'Search for an object by name or catalog id — M31, '
                            'NGC 7000, IC 1805 — and add it here.'
                        : 'Nothing in your library or the installed sky '
                            'catalogs matches "$_query".',
                  );
                }

                return ListView(
                  children: [
                    for (final t in available) ...[
                      _CatalogTargetTile(
                        colors: colors,
                        name: t.name,
                        onTap: () => Navigator.of(context).pop(t.id),
                      ),
                      const SizedBox(height: SkotiqTokens.spaceXs),
                    ],
                    if (newFromCatalog.isNotEmpty) ...[
                      const SizedBox(height: SkotiqTokens.spaceSm),
                      Text(
                        'Not in your targets yet',
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(height: SkotiqTokens.spaceXs),
                      for (final m in newFromCatalog) ...[
                        _CatalogTargetTile(
                          colors: colors,
                          name: m.name,
                          subtitle: [
                            m.type,
                            if (m.magnitude != null)
                              'mag ${m.magnitude!.toStringAsFixed(1)}',
                            if (m.constellation != null &&
                                m.constellation!.isNotEmpty)
                              m.constellation!,
                          ].join(' · '),
                          trailingIcon: LucideIcons.plus,
                          busy: _adding == m.catalogId,
                          onTap:
                              _adding == null ? () => _addFromCatalog(m) : null,
                        ),
                        const SizedBox(height: SkotiqTokens.spaceXs),
                      ],
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

class _CatalogTargetTile extends StatelessWidget {
  final SkotiqColors colors;
  final String name;
  final String? subtitle;
  final IconData trailingIcon;

  /// Non-null while this row's add is in flight, so the row shows progress and
  /// a second tap cannot create a duplicate.
  final bool busy;

  /// Null disables the row (another add is in flight).
  final VoidCallback? onTap;

  const _CatalogTargetTile({
    required this.colors,
    required this.name,
    required this.onTap,
    this.subtitle,
    this.trailingIcon = LucideIcons.plus,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: SkotiqTokens.borderRadiusSm,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceMd,
            vertical: SkotiqTokens.spaceMd,
          ),
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: SkotiqTokens.borderRadiusSm,
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              Icon(
                LucideIcons.target,
                size: SkotiqTokens.iconSm,
                color: colors.textSecondary,
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: SkotiqTypography.body.copyWith(
                        color: colors.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (busy)
                SizedBox(
                  width: SkotiqTokens.iconSm,
                  height: SkotiqTokens.iconSm,
                  child: SkotiqSpinner(
                      size: SkotiqTokens.iconSm, color: colors.primary),
                )
              else
                Icon(
                  trailingIcon,
                  size: SkotiqTokens.iconSm,
                  color: colors.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

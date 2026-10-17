// ignore_for_file: invalid_use_of_protected_member
// Content, download, package and annotation section builders of _CatalogSettingsScreenState.
part of '../catalog_settings_screen.dart';

extension _CatalogSettingsViewBuilders on _CatalogSettingsScreenState {
  Widget _buildContent(BuildContext context) {
    final colors = context.skotiqColors;
    final isRemote = ref.watch(backendProvider) is NetworkBackend;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header - hide on mobile since parent shows it
        if (!widget.isMobile) ...[
          Text(
            'Catalogs',
            style: SkotiqTypography.pageTitle.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Download star and deep sky object catalogs to enable full planetarium functionality.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 32),
        ],

        // Download progress
        if (_isDownloading && !_isDeleting) ...[
          _buildDownloadProgress(context),
          const SizedBox(height: 32),
        ],

        // Whose catalogs these are. Reading the local filesystem while driving
        // a rig told the operator a capability was installed on the machine
        // that did not have it.
        if (isRemote) ...[
          _buildRigScopeNotice(context),
          const SizedBox(height: 24),
        ],

        // Star catalog card
        _buildCatalogCard(
          context: context,
          title: 'HYG Star Database',
          description:
              'Combined Hipparcos, Yale, and Gliese star catalogs with ~120000 stars',
          sourceUrl: 'github.com/astronexus/HYG-Database',
          status: _starStatus,
          type: 'stars',
          icon: SkotiqIcons.star,
          usedFor: 'Draws the star field in the planetarium and finder.',
          // The version the resolver would actually download, not a literal
          // that has to be remembered when the asset rolls. A hardcoded '4.2'
          // here outlived the move to hyg_v44 and made the newest fetchable
          // catalog advertise an update to a version the app cannot get.
          latestVersion: hygStarCatalog.version,
          rigStatus: isRemote ? _rigStatusFor('stars') : null,
        ),
        const SizedBox(height: 16),

        // DSO catalog card
        _buildCatalogCard(
          context: context,
          title: 'OpenNGC',
          description:
              'Open source NGC/IC deep sky catalog with ~13000 objects',
          sourceUrl: 'github.com/mattiaverga/OpenNGC',
          status: _dsoStatus,
          type: 'dso',
          // KEEP MATERIAL: no clean Lucide "out-of-focus disc" glyph
          // (icon-migration-map.md flagged exception).
          icon: SkotiqIcons.target,
          usedFor:
              'Powers deep-sky target search, framing, and on-image NGC/IC labels.',
          latestVersion: openNgcCatalog.version,
          rigStatus: isRemote ? _rigStatusFor('dso') : null,
        ),
        const SizedBox(height: 32),

        // Annotation catalog section
        _buildAnnotationCatalogSection(context, isRemote),
        const SizedBox(height: 32),

        // Deep-star tier (downloadable Tycho-2 / Gaia subset).
        const DeepStarCatalogCard(),
        const SizedBox(height: 16),

        // Live MPC / TLE element refresh.
        const ElementRefreshCard(),
        const SizedBox(height: 32),

        // Download section
        _buildDownloadSection(context),
        const SizedBox(height: 32),

        // Actions
        _buildActionsSection(context),
      ],
    );
  }

  Widget _buildDownloadProgress(BuildContext context) {
    final colors = context.skotiqColors;
    final isNetworkDownload =
        CatalogManager.instance.activeDownloads.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(colors.primary),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${isNetworkDownload ? 'Downloading' : 'Importing'}: '
                  '$_currentDownload',
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              // Cancellation only applies to a real network download in flight
              // (imports are atomic and finish immediately).
              if (CatalogManager.instance.activeDownloads.isNotEmpty)
                SkotiqButton(
                  onPressed: _cancelRequested ? null : _requestCancelDownload,
                  icon: SkotiqIcons.close,
                  label: _cancelRequested ? 'Cancelling…' : 'Cancel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            child: LinearProgressIndicator(
              value: _downloadProgress,
              backgroundColor: colors.border,
              valueColor: AlwaysStoppedAnimation(colors.primary),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _downloadStatus,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadSection(BuildContext context) {
    final colors = context.skotiqColors;
    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Download catalogs',
            style: SkotiqTypography.sectionTitle
                .copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 16),
          // There is ONE dataset. The three-tier selector that stood here —
          // Essential / Standard / Complete, each with its own size, star count
          // and "Stars: mag <= x.x" — downloaded the same two files whichever
          // was chosen, so two installs into an empty catalog directory
          // produced byte-identical files the card then described with
          // different depths. Say what arrives, once.
          Text(
            'One download installs both catalogs:',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'HYG Star Database - '
            '~${formatCatalogCount(kInstalledStarApproxCount)} stars, '
            'complete to mag ${kHygFaintFloorMag.toStringAsFixed(1)}',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'OpenNGC - '
            '~${formatCatalogCount(kInstalledDsoApproxCount)} deep-sky objects '
            '(NGC / IC)',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'About $kInstalledCatalogApproxSizeMB MB on disk.',
            style: SkotiqTypography.captionSm.copyWith(
              color: colors.textSecondary.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: _isDeleting
                  ? 'Deleting catalogs…'
                  : _isDownloading
                      ? 'Downloading...'
                      : 'Download catalogs',
              icon: SkotiqIcons.download,
              variant: ButtonVariant.primary,
              onPressed: _isDownloading ? null : _downloadCatalogs,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsSection(BuildContext context) {
    final colors = context.skotiqColors;
    final hasInstalledCatalogs = (_starStatus?.isInstalled ?? false) ||
        (_dsoStatus?.isInstalled ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Actions',
          style:
              SkotiqTypography.sectionTitle.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 16),
        widget.isMobile
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SkotiqButton(
                    label: 'Refresh status',
                    icon: SkotiqIcons.refresh,
                    variant: ButtonVariant.secondary,
                    onPressed: _isDownloading ? null : _loadCatalogStatus,
                  ),
                  if (hasInstalledCatalogs) ...[
                    const SizedBox(height: 8),
                    SkotiqButton(
                      label: 'Delete catalogs',
                      icon: SkotiqIcons.delete,
                      variant: ButtonVariant.destructive,
                      onPressed: _isDownloading ? null : _deleteCatalogs,
                      isLoading:
                          _deleteTarget == _CatalogDeleteTarget.starAndDso,
                    ),
                  ],
                ],
              )
            : Row(
                children: [
                  SkotiqButton(
                    label: 'Refresh status',
                    icon: SkotiqIcons.refresh,
                    variant: ButtonVariant.secondary,
                    onPressed: _isDownloading ? null : _loadCatalogStatus,
                  ),
                  const SizedBox(width: 12),
                  if (hasInstalledCatalogs)
                    SkotiqButton(
                      label: 'Delete catalogs',
                      icon: SkotiqIcons.delete,
                      variant: ButtonVariant.destructive,
                      onPressed: _isDownloading ? null : _deleteCatalogs,
                      isLoading:
                          _deleteTarget == _CatalogDeleteTarget.starAndDso,
                    ),
                ],
              ),
      ],
    );
  }

  Widget _buildAnnotationCatalogSection(BuildContext context, bool isRemote) {
    final colors = context.skotiqColors;
    final isInstalled = _annotationStatus?.isInstalled ?? false;
    final rigStatus = isRemote ? _rigStatusFor('annotation') : null;

    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.tag,
                  color: colors.textMuted, size: SkotiqTokens.iconMd),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'GLADE+ galaxy catalog',
                          style: SkotiqTypography.sectionTitle
                              .copyWith(color: colors.textPrimary),
                        ),
                        if (isInstalled)
                          _buildBadge(
                            context: context,
                            label: rigStatus == null
                                ? 'Installed'
                                : 'On this device',
                            color: colors.success,
                          ),
                        if (rigStatus != null)
                          _buildBadge(
                            context: context,
                            label:
                                _CatalogCardBuilders._rigHasCatalog(rigStatus)
                                    ? 'On the rig'
                                    : 'Not on the rig',
                            color:
                                _CatalogCardBuilders._rigHasCatalog(rigStatus)
                                    ? colors.success
                                    : colors.warning,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Galaxy List for the Advanced Detector Era - up to 22.5M galaxies for deep image annotation',
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(SkotiqIcons.info,
                  size: 14, color: colors.textSecondary.withValues(alpha: 0.8)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Labels faint galaxies on solved images. Optional — only needed '
                  'for deep-field annotation, not for capture or plate solving.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary.withValues(alpha: 0.9),
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Source: glade.elte.hu via vizier.cds.unistra.fr',
            style: SkotiqTypography.monoCaption.copyWith(
              color: colors.textSecondary.withValues(alpha: 0.7),
            ),
          ),
          if (isInstalled && _annotationStatus != null) ...[
            const SizedBox(height: 12),
            Divider(color: colors.border),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _buildStatusChip(
                  context: context,
                  label: 'Objects',
                  value: _formatCount(_annotationStatus!.objectCount),
                ),
                _buildStatusChip(
                  context: context,
                  label: 'Size',
                  value: _formatBytes(_annotationStatus!.fileSizeBytes),
                ),
                // No "Package" chip here either — see the note on the shared
                // installed-catalog card in card_builders.dart. The download
                // tier was a placebo and has been retired; printing the grade
                // off the legacy sidecar labels the user's install with
                // something they can no longer choose and that never described
                // the bytes on disk.
                if (_annotationStatus!.installedDate != null)
                  _buildStatusChip(
                    context: context,
                    label: 'Installed',
                    value: _formatDate(_annotationStatus!.installedDate!),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          if (!isInstalled) ...[
            FormRow(
              label: 'Catalog tier',
              child: SkotiqDropdown(
                value: _selectedAnnotationPackage.name,
                items: AnnotationPackage.values.map((p) => p.name).toList(),
                itemLabels:
                    AnnotationPackage.values.map((p) => p.displayName).toList(),
                onChanged: _isDownloading
                    ? null
                    : (value) {
                        if (value != null)
                          setState(() {
                            _selectedAnnotationPackage =
                                AnnotationPackage.values.byName(value);
                          });
                      },
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              _selectedAnnotationPackage.description,
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label:
                    'Download ${_selectedAnnotationPackage.displayName} (~${_selectedAnnotationPackage.approximateSizeMB} MB)',
                icon: SkotiqIcons.download,
                variant: ButtonVariant.secondary,
                onPressed: _isDownloading ? null : _downloadAnnotationCatalog,
              ),
            ),
            const SizedBox(height: 12),
            // Optional manual import
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label: 'Import CSV',
                icon: SkotiqIcons.folderOpen,
                variant: ButtonVariant.secondary,
                onPressed: _isDownloading ? null : _importAnnotationCatalog,
              ),
            ),
          ] else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label: 'Delete annotation catalog',
                icon: SkotiqIcons.delete,
                variant: ButtonVariant.destructive,
                onPressed: _isDownloading ? null : _deleteAnnotationCatalog,
                isLoading: _deleteTarget == _CatalogDeleteTarget.annotation,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

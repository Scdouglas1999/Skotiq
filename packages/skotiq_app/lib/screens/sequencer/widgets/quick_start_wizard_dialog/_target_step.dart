// ignore_for_file: unused_element

part of '../quick_start_wizard_dialog.dart';

extension _TargetStep on _QuickStartWizardDialogState {
  // STEP 1: TARGET

  Widget _buildTargetStep(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Search for a target or enter coordinates manually.',
          style: TextStyle(
              color: colors.textSecondary,
              fontSize: SkotiqTypography.fontSize13),
        ),
        const SizedBox(height: 16),

        // Target name / search
        TextField(
          controller: _targetNameController,
          style: TextStyle(color: colors.textPrimary),
          decoration: InputDecoration(
            labelText: 'Target Name',
            hintText: 'e.g., M42, NGC 7000, Orion Nebula',
            prefixIcon: Icon(LucideIcons.search, color: colors.textMuted),
            suffixIcon: _isSearching
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: SkotiqSpinner(size: 16, color: colors.primary),
                    ),
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              borderSide: BorderSide(color: colors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              borderSide: BorderSide(color: colors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              borderSide: BorderSide(color: colors.primary),
            ),
            filled: true,
            fillColor: colors.surfaceAlt,
            labelStyle: TextStyle(color: colors.textSecondary),
            hintStyle: TextStyle(color: colors.textMuted),
          ),
          textInputAction: TextInputAction.search,
          onChanged: _onTargetSearch,
          onSubmitted: _submitTargetSearch,
        ),

        // Search results
        if (_searchResults.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            constraints: const BoxConstraints(maxHeight: 150),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              border: Border.all(color: colors.border),
            ),
            // The rows are ListTiles inside a decorated box, so without an
            // intervening Material they paint no ink splash at all (and
            // Flutter asserts about it in debug).
            child: Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _searchResults.length,
                itemBuilder: (context, index) {
                  final target = _searchResults[index];
                  return ListTile(
                    dense: true,
                    title: Text(
                      target.name,
                      style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: SkotiqTypography.fontSize13),
                    ),
                    subtitle: Text(
                      [
                        target.sourceLabel,
                        if (target.catalogId case final id?
                            when id.isNotEmpty && id != target.name)
                          id,
                        'RA ${_formatRa(target.ra)}',
                        'Dec ${_formatDec(target.dec)}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: colors.textMuted,
                          fontSize: SkotiqTypography.fontSize11),
                    ),
                    trailing: target.magnitude != null
                        ? Text(
                            'mag ${target.magnitude!.toStringAsFixed(1)}',
                            style: TextStyle(
                                color: colors.textMuted,
                                fontSize: SkotiqTypography.fontSize11),
                          )
                        : null,
                    onTap: () => _selectTarget(target),
                  );
                },
              ),
            ),
          ),

        // A finished search with nothing to show has to say so and offer the
        // online lookup; a SIMBAD miss is reported even over a partial list.
        if (_onlineLookupMessage != null && !_isSearching)
          _buildTargetSearchNote(
            colors,
            LucideIcons.searchX,
            colors.warning,
            _onlineLookupMessage!,
          )
        else if (_searchResults.isEmpty && _searchCompleted && !_isSearching)
          _buildTargetSearchEmptyState(colors),

        const SizedBox(height: 20),

        // Coordinates
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _raController,
                style: TextStyle(color: colors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Right Ascension',
                  hintText: '12h 30m 0s or 12.5',
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.primary),
                  ),
                  filled: true,
                  fillColor: colors.surfaceAlt,
                  labelStyle: TextStyle(color: colors.textSecondary),
                  hintStyle: TextStyle(color: colors.textMuted),
                ),
                onChanged: (_) => _update(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _decController,
                style: TextStyle(color: colors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Declination',
                  hintText: "+45d 30' 0\" or 45.5",
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.primary),
                  ),
                  filled: true,
                  fillColor: colors.surfaceAlt,
                  labelStyle: TextStyle(color: colors.textSecondary),
                  hintStyle: TextStyle(color: colors.textMuted),
                ),
                onChanged: (_) => _update(() {}),
              ),
            ),
          ],
        ),

        if (_selectedTarget != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: SkotiqDecorations.emphasisSurface(
              colors.primary,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.checkCircle2, color: colors.success, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Selected: ${_selectedTarget!.name}'
                    '${_selectedTarget!.objectType != null ? " (${_selectedTarget!.objectType})" : ""}',
                    style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: SkotiqTypography.fontSize13),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Says why the results list is empty: the lookup failed, or nothing in
  /// the installed catalog or the saved library matches. The second case
  /// offers SIMBAD's exact name lookup; the manual RA/Dec fields below always
  /// work.
  Widget _buildTargetSearchEmptyState(SkotiqColors colors) {
    final error = _searchError;
    if (error != null) {
      return _buildTargetSearchNote(
        colors,
        LucideIcons.alertTriangle,
        colors.error,
        'Target lookup failed: $error. Enter RA/Dec below instead.',
      );
    }
    final query = _lastSearchQuery;
    return _buildTargetSearchNote(
      colors,
      LucideIcons.searchX,
      colors.textMuted,
      'Nothing in the installed catalog or your saved targets matches '
      '"$query". Look it up on SIMBAD, or enter RA/Dec below.',
      action: SkotiqButton(
        label: 'Look up on SIMBAD',
        icon: LucideIcons.globe,
        size: ButtonSize.small,
        variant: ButtonVariant.secondary,
        onPressed: () => _lookUpTargetOnline(query),
      ),
    );
  }

  Widget _buildTargetSearchNote(
    SkotiqColors colors,
    IconData icon,
    Color tint,
    String message, {
    Widget? action,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: SkotiqTokens.iconSm, color: tint),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: SkotiqTypography.fontSize12,
                  ),
                ),
              ),
            ],
          ),
          if (action != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Align(alignment: Alignment.centerRight, child: action),
          ],
        ],
      ),
    );
  }
}

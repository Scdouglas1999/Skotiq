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
          onChanged: _onTargetSearch,
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
                      '${target.catalogId ?? ""} | RA: ${_formatRa(target.ra)} Dec: ${_formatDec(target.dec)}',
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

        // A finished search with nothing to show has to say so, or "is this
        // broken or is my library empty?" is unanswerable.
        if (_searchResults.isEmpty && _searchCompleted && !_isSearching)
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

  /// Says which of the three things actually happened when the results list
  /// is empty: the lookup errored, the target library is empty, or the
  /// library simply holds no match. Every branch points at the manual RA/Dec
  /// fields directly below, which always work.
  Widget _buildTargetSearchEmptyState(SkotiqColors colors) {
    final (IconData icon, Color tint, String message) = switch (_searchError) {
      final Object err => (
          LucideIcons.alertTriangle,
          colors.error,
          'Target lookup failed: $err. Enter RA/Dec below instead.',
        ),
      _ when _libraryIsEmpty => (
          LucideIcons.bookMarked,
          colors.warning,
          // Name a destination that exists. "Sky" and "Planner" are not
          // labels in this build; the rail reads "Plan tonight", and adding
          // a target to one of its projects is what writes the library row
          // this search reads.
          'Your target library is empty, so there is nothing to search. '
              'Add one from Plan tonight ▸ Projects, or enter RA/Dec below.',
        ),
      _ => (
          LucideIcons.searchX,
          colors.textMuted,
          'No saved target matches "$_lastSearchQuery". '
              'Enter RA/Dec below to use it anyway.',
        ),
    };

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: tint),
          const SizedBox(width: 8),
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
    );
  }
}

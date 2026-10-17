part of '../diagnostics_screen.dart';

class _SessionSelector extends StatelessWidget {
  final List<ImagingSession> sessions;
  final int? selectedSessionId;

  /// Whether to offer the quick-capture bucket ([_kQuickCaptureSessionId]) —
  /// true when sessionless PSF tiles / residuals exist. Quick captures are
  /// the one night that has diagnostics but no `imaging_sessions` row.
  final bool offerQuickCaptures;
  final ValueChanged<int?> onChanged;
  final SkotiqColors colors;

  static const String quickCaptureLabel = kQuickCaptureSessionLabel;

  const _SessionSelector({
    required this.sessions,
    required this.selectedSessionId,
    required this.offerQuickCaptures,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty && !offerQuickCaptures) {
      return Text(
        context.l10n.text('diagnosticsNoSessions'),
        style: TextStyle(
            color: colors.textMuted, fontSize: SkotiqTypography.fontSize12),
      );
    }

    final dateFormat = DateFormat('MMM d, HH:mm');
    final sessionsByRecency = sessions.reversed.toList();
    final recentSessions = sessionsByRecency.take(50).toList();
    final selectedSession = selectedSessionId == null
        ? null
        : sessions.cast<ImagingSession?>().firstWhere(
              (session) => session?.id == selectedSessionId,
              orElse: () => null,
            );
    final visibleSessions = [...recentSessions];

    if (selectedSession != null &&
        !visibleSessions.any((session) => session.id == selectedSession.id)) {
      visibleSessions.insert(0, selectedSession);
    }

    final dropdownValue = selectedSessionId == _kQuickCaptureSessionId
        ? (offerQuickCaptures ? _kQuickCaptureSessionId : null)
        : (selectedSessionId != null &&
                visibleSessions.any(
                  (session) => session.id == selectedSessionId,
                )
            ? selectedSessionId
            : null);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: AccessibleDropdown<int>(
          value: dropdownValue,
          // isExpanded lets the button shrink to its bounded parent and
          // ellipsize the selected label instead of sizing to the widest
          // item (which overflows a narrow phone header).
          isExpanded: true,
          hint: Text(
            context.l10n.text('diagnosticsSelectSession'),
            style: TextStyle(
                color: colors.textMuted, fontSize: SkotiqTypography.fontSize13),
          ),
          dropdownColor: colors.surfaceElevated,
          style: TextStyle(
              color: colors.textPrimary, fontSize: SkotiqTypography.fontSize13),
          icon:
              Icon(LucideIcons.chevronDown, size: 14, color: colors.textMuted),
          items: [
            // Listed first: it is the most recent work by definition (the
            // sessionless queries return recent rows) and the operator who
            // needs it has no session row to look for.
            if (offerQuickCaptures)
              const DropdownMenuItem(
                value: _kQuickCaptureSessionId,
                child: Text(
                  quickCaptureLabel,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ...visibleSessions.map((session) {
              final label = session.name != null && session.name!.isNotEmpty
                  ? '${session.name} (${dateFormat.format(session.startTime)})'
                  : dateFormat.format(session.startTime);
              return DropdownMenuItem(
                value: session.id,
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

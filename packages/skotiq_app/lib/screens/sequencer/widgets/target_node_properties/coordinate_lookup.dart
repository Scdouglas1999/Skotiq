part of '../target_node_properties.dart';

/// One candidate returned by [targetCoordinateLookupProvider].
@immutable
class TargetCoordinateMatch {
  final String name;
  final String? catalogId;
  final double raHours;
  final double decDegrees;
  final String? objectType;

  /// `targets.id` when the match came from the local target library, so the
  /// editor can populate [TargetHeaderNode.catalogTargetId] and captured
  /// frames get attributed to the right row. `null` for installed-catalog
  /// matches, which have no library row behind them.
  final int? libraryTargetId;

  const TargetCoordinateMatch({
    required this.name,
    required this.raHours,
    required this.decDegrees,
    this.catalogId,
    this.objectType,
    this.libraryTargetId,
  });
}

/// Name → coordinates lookup for the Target editor.
///
/// Two sources, in priority order:
///
///  1. the target library — via the host over the wire when this is a remote
///     client, whose local `targets` table is never populated. That authority
///     split is the same one the Quick-Start wizard uses;
///  2. the installed planetarium catalogs. No target data is seeded on a
///     fresh install, so the library starts EMPTY and the catalogs are the
///     only thing that can turn "M31" into 00h 42m 44s.
///
/// Neither source is guaranteed to be present, which is why the editor
/// reports "no match" rather than silently leaving the placeholder in place.
final targetCoordinateLookupProvider = FutureProvider.autoDispose
    .family<List<TargetCoordinateMatch>, String>((ref, query) async {
  final trimmed = query.trim();
  if (trimmed.length < 2) return const <TargetCoordinateMatch>[];

  final matches = <TargetCoordinateMatch>[];
  final seen = <String>{};
  Object? sourceFailure;
  StackTrace? sourceStackTrace;

  void add(TargetCoordinateMatch match) {
    final key = _lookupKey(match.catalogId ?? match.name);
    if (!seen.add(key)) return;
    matches.add(match);
  }

  final backend = ref.read(backendProvider);
  try {
    final List<DbTarget> rows;
    if (backend is NetworkBackend) {
      final json = await backend.searchTargets(trimmed);
      rows = json.map(DbTarget.fromJson).toList();
    } else {
      rows = await ref.read(targetsDaoProvider).searchTargets(trimmed);
    }
    for (final row in rows) {
      add(TargetCoordinateMatch(
        name: row.name,
        catalogId: row.catalogId,
        raHours: row.ra,
        decDegrees: row.dec,
        objectType: row.objectType,
        libraryTargetId: row.id,
      ));
    }
  } catch (error, stackTrace) {
    // A library search failure must not swallow the catalog fallback below —
    // an offline remote client should still resolve from local catalogs.
    sourceFailure = error;
    sourceStackTrace = stackTrace;
    debugPrint('Target-library coordinate lookup failed: $error');
  }

  final manager = CatalogManager.instance;
  if (manager.isInitialized) {
    try {
      final results = await manager.search(trimmed);
      for (final result in results.take(12)) {
        add(TargetCoordinateMatch(
          name: result.name,
          catalogId: result.catalogId,
          // CatalogSearchResult carries RA in DEGREES; the sequence model
          // stores hours.
          raHours: result.ra / 15.0,
          decDegrees: result.dec,
          objectType: result.type,
        ));
      }
    } catch (error, stackTrace) {
      // Catalog files can be mid-download or corrupt; an empty result set is
      // reported honestly unless another source produced usable matches.
      sourceFailure ??= error;
      sourceStackTrace ??= stackTrace;
      debugPrint('Installed-catalog coordinate lookup failed: $error');
    }
  }

  if (matches.isEmpty && sourceFailure != null) {
    Error.throwWithStackTrace(sourceFailure, sourceStackTrace!);
  }

  return matches;
});

String _lookupKey(String value) =>
    value.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');

/// Name-resolution affordance for the Target editor.
///
/// Before this existed the editor had no way at all to turn a typed name into
/// coordinates, so "M31" plus the 0h/+0° placeholder was a reachable — and
/// silently runnable — state. The section shows an explicit warning while the
/// coordinates are unset and offers a lookup against the target library and
/// the installed catalogs.
class _CoordinateLookupSection extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final TargetHeaderNode node;

  const _CoordinateLookupSection({required this.colors, required this.node});

  @override
  ConsumerState<_CoordinateLookupSection> createState() =>
      _CoordinateLookupSectionState();
}

class _CoordinateLookupSectionState
    extends ConsumerState<_CoordinateLookupSection> {
  /// The name that was searched, or null when no lookup has been run since the
  /// last apply. Kept separate from `node.targetName` so results don't churn
  /// while the user is still typing.
  String? _query;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final node = widget.node;
    final name = node.targetName.trim();
    final unset = targetCoordinatesUnset(node);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (unset)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: SkotiqDecorations.tintedBadge(
                colors.warning,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(LucideIcons.alertCircle,
                      size: 14, color: colors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Coordinates not set — this target still points at the '
                      '0h/+0° default. Look them up or enter RA/Dec above.',
                      style: TextStyle(
                        fontSize: Responsive.fontSize(context, 12),
                        color: colors.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: SkotiqButton(
            onPressed:
                name.length < 2 ? null : () => setState(() => _query = name),
            icon: LucideIcons.search,
            label: 'Look up coordinates',
            variant: unset ? ButtonVariant.primary : ButtonVariant.outline,
            size: ButtonSize.small,
          ),
        ),
        if (_query != null) _buildResults(context, _query!),
      ],
    );
  }

  Widget _buildResults(BuildContext context, String query) {
    final colors = widget.colors;
    final lookup = ref.watch(targetCoordinateLookupProvider(query));

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: lookup.when(
        loading: () => _message(context, 'Searching for "$query"…'),
        error: (_, __) => _message(
          context,
          'Lookup failed. Enter RA/Dec manually.',
          isProblem: true,
        ),
        data: (matches) {
          if (matches.isEmpty) {
            return _message(
              context,
              'No match for "$query" in your target library or installed '
              'catalogs. Install a catalog from Settings → Catalogs, or '
              'enter RA/Dec above.',
              isProblem: true,
            );
          }
          return Container(
            constraints: const BoxConstraints(maxHeight: 190),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius:
                  BorderRadius.circular(SkotiqTokens.radiusInline8),
              border: Border.all(color: colors.border),
            ),
            // The rows are ListTiles, which paint their ink on the nearest
            // Material ancestor; without this transparency layer the
            // surrounding decoration would swallow the splash (and Flutter
            // asserts about it in debug).
            child: Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: matches.length,
                itemBuilder: (context, index) {
                  final match = matches[index];
                  return ListTile(
                    dense: true,
                    title: Text(
                      match.name,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: SkotiqTypography.fontSize13,
                      ),
                    ),
                    subtitle: Text(
                      '${_lookupRa(match.raHours)}  '
                      '${_lookupDec(match.decDegrees)}',
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: SkotiqTypography.fontSize11,
                      ),
                    ),
                    onTap: () => _apply(match),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _message(BuildContext context, String text, {bool isProblem = false}) {
    final colors = widget.colors;
    return Text(
      text,
      style: TextStyle(
        fontSize: Responsive.fontSize(context, 11),
        color: isProblem ? colors.warning : colors.textMuted,
      ),
    );
  }

  void _apply(TargetCoordinateMatch match) {
    ref.read(currentSequenceProvider.notifier).updateNode(
          widget.node.copyWith(
            targetName: match.name,
            raHours: match.raHours,
            decDegrees: match.decDegrees,
            catalogTargetId: match.libraryTargetId,
          ),
        );
    setState(() => _query = null);
  }
}

/// Format decimal RA hours as `HHh MMm SS.Ss` for the lookup result rows.
String _lookupRa(double hours) {
  var h = hours % 24;
  if (h < 0) h += 24;
  final hh = h.floor();
  final remMin = (h - hh) * 60;
  final mm = remMin.floor();
  final ss = (remMin - mm) * 60;
  return '${hh.toString().padLeft(2, '0')}h '
      '${mm.toString().padLeft(2, '0')}m '
      '${ss.toStringAsFixed(1).padLeft(4, '0')}s';
}

/// Format decimal declination degrees as `±DD° MM' SS"`.
String _lookupDec(double degrees) {
  final sign = degrees < 0 ? '-' : '+';
  final abs = degrees.abs();
  final dd = abs.floor();
  final remMin = (abs - dd) * 60;
  final mm = remMin.floor();
  final ss = (remMin - mm) * 60;
  return '$sign${dd.toString().padLeft(2, '0')}° '
      "${mm.toString().padLeft(2, '0')}' "
      '${ss.toStringAsFixed(0).padLeft(2, '0')}"';
}

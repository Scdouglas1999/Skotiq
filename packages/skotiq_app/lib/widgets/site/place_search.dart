import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

typedef PlaceSearcher = Future<List<PlaceSearchHit>> Function(String query);

final placeSearchProvider = Provider<PlaceSearcher>(
  (ref) => GeolocationService.searchPlaces,
);

/// A search for an observing site by place name, shared by Settings >
/// Location and the first-run site step so both find places the same way and
/// say the same thing when nothing matches.
class PlaceSearch extends ChangeNotifier {
  final TextEditingController query = TextEditingController();

  bool searching = false;
  List<PlaceSearchHit> hits = const [];

  /// Why there are no [hits] to pick from, once a search has run.
  String? message;

  /// True when the last search left something to show: places or a reason.
  bool get hasOutcome => hits.isNotEmpty || message != null;

  Future<void> run(PlaceSearcher searcher) async {
    final text = query.text.trim();
    if (text.isEmpty || searching) return;
    searching = true;
    message = null;
    notifyListeners();
    try {
      hits = await searcher(text);
      message = hits.isEmpty ? 'No places matched "$text".' : null;
    } on PlaceSearchUnavailable catch (error) {
      hits = const [];
      message = error.message;
    } catch (error) {
      hits = const [];
      message = 'Could not search for a place: ${userFacingError(error)}';
    }
    searching = false;
    notifyListeners();
  }

  /// Forget the results once one was used.
  void clear() {
    hits = const [];
    message = null;
    notifyListeners();
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }
}

/// The place-name box. Enter or the search glyph runs [search].
class PlaceSearchInput extends ConsumerWidget {
  const PlaceSearchInput({super.key, required this.search});

  final PlaceSearch search;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void run() => search.run(ref.read(placeSearchProvider));
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) => SkotiqTextField(
        controller: search.query,
        // A real town as the hint read as the saved site's name.
        hint: 'Town, city or observatory',
        onSubmitted: (_) => run(),
        suffixWidget: search.searching
            ? const SkotiqSpinner(size: SkotiqTokens.iconXs)
            : SkotiqIconButton(
                icon: LucideIcons.search,
                tooltip: 'Search for this place',
                size: IconButtonSize.sm,
                onPressed: run,
              ),
      ),
    );
  }
}

/// What the last search found, each place one tap from being the site.
class PlaceSearchResults extends StatelessWidget {
  const PlaceSearchResults({
    super.key,
    required this.search,
    required this.onPicked,
  });

  final PlaceSearch search;
  final ValueChanged<PlaceSearchHit> onPicked;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) {
        final colors = SkotiqColors.of(context);
        final message = search.message;
        if (message != null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
            child: Text(
              message,
              style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
            ),
          );
        }
        if (search.hits.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final hit in search.hits)
              Semantics(
                button: true,
                child: InkWell(
                  onTap: () => onPicked(hit),
                  borderRadius: SkotiqTokens.borderRadiusSm,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: SkotiqTokens.spaceSm,
                      horizontal: SkotiqTokens.spaceXs,
                    ),
                    child: Text(
                      hit.elevation == null
                          ? hit.label
                          : '${hit.label} · ${hit.elevation!.round()} m',
                      style: SkotiqTypography.body.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Declarative route table for the tonight-suggestion surface.
///
/// Counterpart to `handlers/suggestion_handlers.dart`. Reads the
/// scheduler's scoring output for "what should I shoot tonight?" plus
/// the per-target score endpoint used for tooltips in the planner UI.
library;

import '../handlers/suggestion_handlers.dart';
import 'headless_route.dart';

/// Build the declarative route table for [SuggestionHandlers].
List<HeadlessRoute> buildSuggestionRoutes(
  SuggestionHandlers h,
) => <HeadlessRoute>[
  HeadlessRoute(
    HttpMethod.get,
    '/api/suggestions/tonight',
    h.handleGetSuggestionsForTonight,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/suggestions/ranked',
    h.handleGetRankedSuggestions,
  ),
  HeadlessRoute(HttpMethod.get, '/api/suggestions/config', h.handleGetConfig),
  HeadlessRoute(
    HttpMethod.get,
    '/api/suggestions/score/<targetId>',
    h.handleGetTargetScore,
  ),
];

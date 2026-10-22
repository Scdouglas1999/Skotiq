/// Declarative route table for the runtime state a host shares with linked
/// clients.
///
/// Counterpart to `handlers/runtime_state_handlers.dart`.
library;

import '../handlers/runtime_state_handlers.dart';
import 'headless_route.dart';

/// Build the declarative route table for [RuntimeStateHandlers].
List<HeadlessRoute> buildRuntimeStateRoutes(RuntimeStateHandlers h) =>
    <HeadlessRoute>[
      HeadlessRoute(HttpMethod.get, '/api/runtime/state', h.handleGetState),
      HeadlessRoute(HttpMethod.post, '/api/runtime/state', h.handleReport),
      HeadlessRoute(
        HttpMethod.get,
        '/api/runtime/recent-events',
        h.handleRecentEvents,
      ),
    ];

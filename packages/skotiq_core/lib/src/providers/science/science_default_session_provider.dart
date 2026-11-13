import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/science/science_default_session.dart';
import '../database_provider.dart';
import '../host_role.dart';

/// The session the Science tab opens on when nothing is live and none is
/// picked ([scienceDefaultSessionId]); a linked client asks its host, so both
/// machines open on the same night.
final scienceDefaultSessionProvider = FutureProvider<int?>(
  (ref) => ref.watch(_scienceDefaultSession),
);

final _scienceDefaultSession = hostRoleProvider<Future<int?>>(
  // Watching the session list reruns the question whenever a session row is
  // written, including the status and end time a finished run sets, which is
  // when the answer changes.
  here: (ref) async {
    await ref.watch(allSessionsProvider.future);
    return scienceDefaultSessionId(
      sessions: ref.read(sessionsDaoProvider),
      science: ref.read(scienceDaoProvider),
      images: ref.read(imagesDaoProvider),
    );
  },
  linked: (ref, host) async {
    await ref.watch(allSessionsProvider.future);
    return host.science.scienceDefaultSession();
  },
);

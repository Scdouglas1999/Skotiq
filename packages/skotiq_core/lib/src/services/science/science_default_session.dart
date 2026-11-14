import '../../database/daos/images_dao.dart';
import '../../database/daos/science_dao.dart';
import '../../database/daos/sessions_dao.dart';

/// The session the Science tab opens on when nothing is live and none is
/// picked: the newest session that carries a science product (a photometry
/// measurement or a plate-solved frame), else the session of the newest light
/// frame. Two test frames shot after a photometry night are lights but carry
/// no product, so they do not bury the night that does.
Future<int?> scienceDefaultSessionId({
  required SessionsDao sessions,
  required ScienceDao science,
  required ImagesDao images,
}) async {
  final withProducts = <int>{
    ...await science.getSessionIdsWithPhotometry(),
    ...await images.getSessionIdsWithSolvedFrames(),
  };
  if (withProducts.isNotEmpty) {
    // Newest first, as the session picker beside the tab lists them.
    for (final session in await sessions.getAllSessions()) {
      if (withProducts.contains(session.id)) return session.id;
    }
  }
  return images.getLatestSessionIdWithLightFrames();
}

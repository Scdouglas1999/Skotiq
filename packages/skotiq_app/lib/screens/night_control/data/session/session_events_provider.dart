// The session's event marks as the charts draw them.

import '../../../../services/night_session/night_session_events.dart';
import '../../night_control_contracts.dart';

extension NightSessionEventMarkers on NightSessionEvents {
  /// Autofocus, dither and flip marks, time ordered.
  List<SeriesMarker> get markers => <SeriesMarker>[
        for (final run in autofocusRuns)
          SeriesMarker(run.at, SeriesMarkerKind.autofocus),
        for (final dither in dithers)
          SeriesMarker(dither.at, SeriesMarkerKind.dither),
        for (final flip in flips) SeriesMarker(flip, SeriesMarkerKind.flip),
      ]..sort((a, b) => a.t.compareTo(b.t));
}

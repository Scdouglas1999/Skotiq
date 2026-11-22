import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../router/app_router.dart';
import '../services/goto_altitude_check.dart';

/// The GoTo altitude question shown on the app's own navigator. False when
/// the operator declines or the process has no window.
Override goToAltitudeAskOverride() => goToAltitudeAskProvider.overrideWith((
      ref,
    ) {
      return (question) async {
        final navigator = ref
            .read(appRouterProvider)
            .routerDelegate
            .navigatorKey
            .currentState;
        final context = navigator?.overlay?.context;
        if (context == null) return false;
        return askGoToAltitudeOn(context, question);
      };
    });

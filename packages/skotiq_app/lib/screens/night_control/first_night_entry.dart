import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../router/app_routes.dart';
import 'night_control_screen.dart';
import '../../tours/tour.dart';
import '../../tours/tour_runner.dart';

/// The page behind `/tutorial/first-night`: Tonight, with the first-night
/// walkthrough resumed over it.
///
/// The location then becomes Tonight's own, so a reload or the back stack
/// does not open the walkthrough a second time.
class FirstNightEntry extends ConsumerStatefulWidget {
  const FirstNightEntry({super.key});

  @override
  ConsumerState<FirstNightEntry> createState() => _FirstNightEntryState();
}

class _FirstNightEntryState extends ConsumerState<FirstNightEntry> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(tourRunnerProvider.notifier).resume(Tour.firstNight);
      if (mounted) context.go(AppRoute.tonight.path);
    });
  }

  @override
  Widget build(BuildContext context) => const NightControlScreen();
}

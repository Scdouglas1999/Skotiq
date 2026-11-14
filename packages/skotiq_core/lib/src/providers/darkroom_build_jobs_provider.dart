import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/darkroom_build_jobs.dart';

final darkroomBuildJobsProvider =
    NotifierProvider<DarkroomBuildJobs, DarkroomBuildJob?>(
      DarkroomBuildJobs.new,
    );

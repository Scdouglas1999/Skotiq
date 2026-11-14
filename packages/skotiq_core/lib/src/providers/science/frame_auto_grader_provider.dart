import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/science/frame_auto_grader.dart';

final frameAutoGraderProvider = Provider<FrameAutoGrader>((ref) {
  return FrameAutoGrader(ref);
});

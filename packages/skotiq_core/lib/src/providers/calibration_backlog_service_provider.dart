import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import '../backend/remote_host.dart';
import '../services/calibration_backlog_service.dart';

final calibrationBacklogProvider =
    StateNotifierProvider<CalibrationBacklogNotifier, CalibrationBacklogState>((
      ref,
    ) {
      final remote = ref.watch(backendProvider).remoteHost != null;
      return CalibrationBacklogNotifier(ref, remote: remote);
    });

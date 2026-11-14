import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/device_commands.dart';

/// The shared device command path; see [DeviceCommands].
final deviceCommandsProvider = Provider<DeviceCommands>(DeviceCommands.new);

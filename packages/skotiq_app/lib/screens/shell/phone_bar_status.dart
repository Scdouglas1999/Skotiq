import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A status the embedding app shows in the phone-width top bar, just before
/// Settings: the phone app's battery warning. Null shows nothing.
final phoneBarStatusProvider = Provider<Widget?>((ref) => null);

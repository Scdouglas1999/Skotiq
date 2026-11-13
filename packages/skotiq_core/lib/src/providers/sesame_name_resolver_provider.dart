import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/sesame_name_resolver.dart';

/// The exact online name resolver. Overridden in tests with a fake client.
final sesameNameResolverProvider = Provider<SesameNameResolver>(
  (ref) => SesameNameResolver(),
);

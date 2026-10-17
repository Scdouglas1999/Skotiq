@Deprecated(
  'Use annotation_settings_provider.dart for annotation presets. '
  'This file remains as a compatibility facade.',
)
library;

export '../models/annotation_settings.dart' show AnnotationPreset;
export 'annotation_settings_provider.dart'
    show
        AnnotationPresetsNotifier,
        annotationPresetsProvider,
        builtInAnnotationPresets;

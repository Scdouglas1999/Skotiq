import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test(
    'every frame type a capture sends is a name the native capture knows',
    () {
      // The FFI capture takes `FrameType.name`. The same file
      // `every_name_the_app_sends_is_known` in frame_type.rs reads, so a frame
      // type added here without a native name fails one side or the other
      // instead of being taken as a light at night.
      final fixture =
          jsonDecode(
                File(
                  '../../test_fixtures/wire_words/camera_frame_type_names.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(
        FrameType.values.map((type) => type.name).toSet(),
        fixture.keys.toSet(),
      );
      for (final type in FrameType.values) {
        final taken = type == FrameType.snapshot ? 'Light' : type.imageType;
        expect(fixture[type.name], taken, reason: type.name);
      }
    },
  );
}

// The live stacker says by kind why it left a frame out; the host answers by
// that kind, and the GUI and published bodies keep the text the refusal had
// before it had one.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

void main() {
  const sentence = 'Alignment residual too high: 24.34px (max 10.00px)';

  test('each native live-stack refusal reads as its kind', () {
    final kinds = {
      bridge.Refusal.liveStackMisaligned: LiveStackRefusalKind.misaligned,
      bridge.Refusal.liveStackOtherFilter: LiveStackRefusalKind.otherFilter,
      bridge.Refusal.liveStackUnreadable: LiveStackRefusalKind.unreadable,
    };
    for (final MapEntry(key: native, value: kind) in kinds.entries) {
      final refusal = liveStackRefusalOf(
        bridge.SkotiqError.refused(kind: native, message: sentence),
      );
      expect(refusal?.kind, kind);
      expect(refusal?.message, sentence);
    }
  });

  test('the text kept is the image error the refusal was before', () {
    expect(
      const LiveStackRefusal(
        LiveStackRefusalKind.misaligned,
        sentence,
      ).legacyText,
      '${const bridge.SkotiqError.imageError(sentence)}',
    );
  });

  test('other failures carry no kind', () {
    expect(
      liveStackRefusalOf(const bridge.SkotiqError.imageError(sentence)),
      isNull,
    );
    expect(
      liveStackRefusalOf(
        const bridge.SkotiqError.refused(
          kind: bridge.Refusal.lightLeak,
          message: sentence,
        ),
      ),
      isNull,
    );
    expect(liveStackRefusalOf(Exception(sentence)), isNull);
    const counted = LiveStackRefusal(LiveStackRefusalKind.otherFilter, 'x');
    expect(
      liveStackRefusalOf(
        LiveStackingFrameRejected(
          reason: counted.legacyText,
          stats: LiveStackingStats(),
          refusal: counted,
        ),
      ),
      same(counted),
    );
  });
}

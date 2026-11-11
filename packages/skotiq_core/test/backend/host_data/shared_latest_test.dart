import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend/host_data/host_poll.dart';

void main() {
  test('one poll serves every listener and stops with the last of them', () {
    fakeAsync((async) {
      final poll = HostPoll('test');
      var value = 1;
      var fetches = 0;
      final shared = SharedLatest<int>(
        () => poll.watch(() async {
          fetches++;
          return value;
        }, (a, b) => a == b),
        (a, b) => a == b,
      );

      final first = <int>[];
      final second = <int>[];
      final firstSub = shared.stream.listen(first.add);
      final secondSub = shared.stream.listen(second.add);
      async.flushMicrotasks();
      expect(fetches, 1, reason: 'two listeners share one fetch');
      expect(first, [1]);
      expect(second, [1]);

      value = 2;
      async.elapse(HostPoll.defaultInterval);
      expect(fetches, 2);
      expect(first, [1, 2]);
      expect(second, [1, 2]);

      firstSub.cancel();
      secondSub.cancel();
      async.flushMicrotasks();
      async.elapse(HostPoll.defaultInterval * 5);
      expect(fetches, 2, reason: 'nobody is listening, so nothing is fetched');
    });
  });

  test('a returning listener sees the last value, then only a change', () {
    fakeAsync((async) {
      final poll = HostPoll('test');
      var value = 1;
      final shared = SharedLatest<int>(
        () => poll.watch(() async => value, (a, b) => a == b),
        (a, b) => a == b,
      );

      final sub = shared.stream.listen((_) {});
      async.flushMicrotasks();
      sub.cancel();
      async.flushMicrotasks();

      final seen = <int>[];
      final again = shared.stream.listen(seen.add);
      async.flushMicrotasks();
      expect(seen, [1], reason: 'replayed once; the refetch found no change');

      value = 3;
      async.elapse(HostPoll.defaultInterval);
      expect(seen, [1, 3]);
      again.cancel();
    });
  });

  test('a failed first fetch reaches a listener that arrives later', () {
    fakeAsync((async) {
      final poll = HostPoll('test');
      final shared = SharedLatest<int>(
        () => poll.watch(
          () async => throw StateError('host unreachable'),
          (a, b) => a == b,
        ),
        (a, b) => a == b,
      );

      final firstErrors = <Object>[];
      final sub = shared.stream.listen((_) {}, onError: firstErrors.add);
      async.flushMicrotasks();
      expect(firstErrors, hasLength(1));

      final lateErrors = <Object>[];
      final later = shared.stream.listen((_) {}, onError: lateErrors.add);
      async.flushMicrotasks();
      expect(lateErrors, hasLength(1));
      sub.cancel();
      later.cancel();
    });
  });
}

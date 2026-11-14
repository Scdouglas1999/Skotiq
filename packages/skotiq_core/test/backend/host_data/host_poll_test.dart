import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend/host_data/host_poll.dart';

void main() {
  test('refresh fetches now and emits only a changed value', () {
    fakeAsync((async) {
      final poll = HostPoll('test');
      var value = 1;
      var fetches = 0;
      final seen = <int>[];
      final sub = poll
          .watch(() async {
            fetches++;
            return value;
          }, (a, b) => a == b)
          .listen(seen.add);

      async.flushMicrotasks();
      expect(seen, [1]);
      expect(fetches, 1);

      poll.refresh();
      async.flushMicrotasks();
      expect(fetches, 2);
      expect(seen, [1], reason: 'unchanged value is not re-emitted');

      value = 2;
      poll.refresh();
      async.flushMicrotasks();
      expect(seen, [1, 2]);

      // The interval restarts from the refresh, not from the first fetch.
      async.elapse(HostPoll.defaultInterval - const Duration(seconds: 1));
      expect(fetches, 3);
      async.elapse(const Duration(seconds: 1));
      expect(fetches, 4);

      sub.cancel();
    });
  });

  test('a refresh during a fetch runs one more fetch after it', () {
    fakeAsync((async) {
      final poll = HostPoll('test');
      final gates = <Completer<int>>[];
      final seen = <int>[];
      final sub = poll
          .watch(() {
            final gate = Completer<int>();
            gates.add(gate);
            return gate.future;
          }, (a, b) => a == b)
          .listen(seen.add);
      async.flushMicrotasks();
      expect(gates, hasLength(1));

      // The write lands while the first read is still in flight, so that
      // read's answer may be from before the write.
      poll.refresh();
      poll.refresh();
      async.flushMicrotasks();
      expect(gates, hasLength(1));

      gates[0].complete(1);
      async.flushMicrotasks();
      expect(gates, hasLength(2), reason: 'exactly one follow-up fetch');
      gates[1].complete(2);
      async.flushMicrotasks();
      expect(seen, [1, 2]);

      sub.cancel();
    });
  });

  test('every live watch refreshes; a canceled one does not', () {
    fakeAsync((async) {
      final poll = HostPoll('test');
      var a = 0;
      var b = 0;
      final subA = poll.watch(() async => ++a, (x, y) => x == y).listen((_) {});
      final subB = poll.watch(() async => ++b, (x, y) => x == y).listen((_) {});
      async.flushMicrotasks();
      expect([a, b], [1, 1]);

      subB.cancel();
      poll.refresh();
      async.flushMicrotasks();
      expect([a, b], [2, 1]);

      subA.cancel();
    });
  });

  test('a failed fetch after data keeps the value and keeps polling', () {
    fakeAsync((async) {
      final poll = HostPoll('test');
      var fail = false;
      var fetches = 0;
      final seen = <int>[];
      final errors = <Object>[];
      final sub = poll
          .watch(() async {
            fetches++;
            if (fail) throw StateError('host unreachable');
            return fetches;
          }, (x, y) => x == y)
          .listen(seen.add, onError: errors.add);
      async.flushMicrotasks();

      fail = true;
      poll.refresh();
      async.flushMicrotasks();
      expect(errors, isEmpty);
      expect(seen, [1]);

      fail = false;
      async.elapse(HostPoll.defaultInterval);
      expect(seen, [1, 3]);

      sub.cancel();
    });
  });
}

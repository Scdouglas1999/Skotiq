// Bridges one TCP [Socket] to one [MuxStream], preserving half-close
// semantics in both directions:
//
//   socket EOF            -> mux finish   (peer may still answer)
//   mux finish from peer  -> socket.close() (TCP FIN; reads continue)
//   socket error          -> mux reset
//   mux reset from peer   -> socket.destroy()
//
// Used by the appliance uplink (socket = localhost dial to the headless
// server) and the phone tunnel client (socket = accepted loopback conn).

import 'dart:async';
import 'dart:io';

import 'mux/mux_session.dart';

/// Pump bytes both ways until both directions are closed. The returned
/// future completes when the bridge is fully torn down; it never throws.
Future<void> bridgeSocketToMuxStream(Socket socket, MuxStream stream) async {
  // Disable Nagle so small HTTP/WS frames don't pick up 40 ms of latency
  // on top of the relay round-trip. Best-effort (some platforms throw).
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}

  var socketWriteOpen = true;

  // mux -> socket
  final muxToSocket = stream.incoming.listen(
    (chunk) {
      if (!socketWriteOpen) return;
      try {
        socket.add(chunk);
      } catch (_) {
        socketWriteOpen = false;
        stream.reset('local socket write failed');
      }
    },
    onError: (Object _) {
      // Peer reset — hard-stop the local socket.
      socketWriteOpen = false;
      socket.destroy();
    },
    onDone: () {
      // Peer half-closed. Flush + FIN our write side; keep reading.
      if (!socketWriteOpen) return;
      socketWriteOpen = false;
      socket.flush().then((_) => socket.close()).catchError((Object _) {
        socket.destroy();
      });
    },
  );

  // socket -> mux
  final socketDone = Completer<void>();
  socket.listen(
    (chunk) {
      try {
        stream.add(chunk);
      } on StateError {
        // Stream already finished/reset locally — drop the tail.
      }
    },
    onError: (Object _) {
      stream.reset('local socket error');
      if (!socketDone.isCompleted) socketDone.complete();
    },
    onDone: () {
      stream.finish();
      if (!socketDone.isCompleted) socketDone.complete();
    },
    cancelOnError: true,
  );

  await Future.wait<void>([stream.done, socketDone.future]);
  await muxToSocket.cancel();
  // Belt-and-braces: make sure the fd is released even if only one
  // direction ever closed cleanly.
  socket.destroy();
}

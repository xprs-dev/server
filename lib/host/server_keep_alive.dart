/*
 * The server's answer to CoreHost.keepAlive: nothing to hold (a server is
 * never suspended), and a heartbeat, the same 2 s one Android's foreground
 * service gives the core. The core's heartbeat-driven work (the catch-up
 * poll, XPRS.md 12.10.1) gates itself on top of it, so this only says "it is
 * later now". It runs only while somebody listens.
 */
import 'dart:async';

import 'package:xprs_core/src/platform/core_host.dart';

class ServerKeepAlive implements KeepAlive {
  ServerKeepAlive({this.every = const Duration(seconds: 2)});

  final Duration every;
  final List<void Function()> _listeners = [];
  Timer? _timer;

  @override
  bool get ticks => true;

  @override
  Future<void> hold(String reason) async {}
  @override
  Future<void> release(String reason) async {}

  @override
  void addTickListener(void Function() listener) {
    _listeners.add(listener);
    _timer ??= Timer.periodic(every, (_) {
      for (final l in List.of(_listeners)) {
        try {
          l();
        } catch (_) {
          // One listener's fault must not stop the others' heartbeat.
        }
      }
    });
  }

  @override
  void removeTickListener(void Function() listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

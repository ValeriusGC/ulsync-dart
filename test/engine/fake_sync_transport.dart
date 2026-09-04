/// Test double for [SyncTransport]. No HTTP and no `dart:io`.
library;

import 'dart:async';

import 'package:ulsync/ulsync.dart';

/// In-memory [SyncTransport] that records calls and lets tests script replies.
final class FakeSyncTransport implements SyncTransport {
  /// Push invocations; round 1 sends one envelope per call.
  final List<List<Envelope>> pushCalls = [];

  /// Optional push script. When omitted, every envelope is `applied: true`.
  Future<List<PushResult>> Function(List<Envelope> envelopes)? onPush;

  /// Pull invocations in call order.
  final List<({int since, int? limit})> pullCalls = [];

  /// Optional pull script. When omitted, the page is empty at [since].
  Future<PullPage> Function({required int since, int? limit})? onPull;

  /// Invoked at the start of every [pull], before [onPull].
  ///
  /// Used to detect overlap with a parked [EntityAdapter.apply] without
  /// replacing [onPull].
  void Function()? onBeforePull;

  /// Live messages consumed by the engine.
  ///
  /// Broadcast so [close] does not hang when nobody listened (tests that
  /// never call [UlsyncClient.live]).
  final StreamController<LiveMessage> liveController =
      StreamController<LiveMessage>.broadcast();

  /// Engine cursor callback captured by the last [live] call.
  int Function()? appliedSince;

  /// Connection-state callback captured by the last [live] call.
  void Function(LiveConnectionState state)? onConnectionState;

  /// Cursor values read at [live] open and each [simulateReconnect].
  final List<int> appliedSinceReads = [];

  /// Whether [close] has run.
  bool closed = false;

  @override
  Future<List<PushResult>> push(List<Envelope> envelopes) async {
    _ensureOpen();
    pushCalls.add(List<Envelope>.from(envelopes));
    final handler = onPush;
    if (handler != null) {
      return handler(envelopes);
    }
    return [
      for (final envelope in envelopes)
        PushResult(id: envelope.id, part: envelope.part, applied: true),
    ];
  }

  @override
  Future<PullPage> pull({required int since, int? limit}) async {
    _ensureOpen();
    onBeforePull?.call();
    pullCalls.add((since: since, limit: limit));
    final handler = onPull;
    if (handler != null) {
      return handler(since: since, limit: limit);
    }
    return PullPage(envelopes: const [], nextCursor: since);
  }

  @override
  Stream<LiveMessage> live({
    required int Function() appliedSince,
    void Function(LiveConnectionState state)? onConnectionState,
  }) {
    _ensureOpen();
    this.appliedSince = appliedSince;
    this.onConnectionState = onConnectionState;
    appliedSinceReads.add(appliedSince());
    return liveController.stream;
  }

  /// Records another [appliedSince] read, as a transport reopen would.
  void simulateReconnect() {
    final read = appliedSince;
    if (read == null) {
      throw StateError('live() has not been called');
    }
    appliedSinceReads.add(read());
  }

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    if (!liveController.isClosed) {
      await liveController.close();
    }
  }

  /// Throws when [close] has already run.
  void _ensureOpen() {
    if (closed) {
      throw StateError('FakeSyncTransport is closed');
    }
  }
}

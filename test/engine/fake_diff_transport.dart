/// [SyncDiffTransport] test double. Does not add a method to [FakeSyncTransport].
library;

import 'dart:async';

import 'package:ulsync/ulsync.dart';

/// In-memory transport that can run SPEC section 3.4.
///
/// Implements both interfaces itself because [FakeSyncTransport] is `final`
/// (existing engine tests must keep compiling without a new [SyncTransport]
/// member).
final class FakeDiffTransport implements SyncTransport, SyncDiffTransport {
  /// Push invocations; round 1 sends one envelope per call.
  final List<List<Envelope>> pushCalls = [];

  /// Optional push script. When omitted, every envelope is `applied: true`.
  Future<List<PushResult>> Function(List<Envelope> envelopes)? onPush;

  /// Pull invocations in call order.
  final List<({int since, int? limit})> pullCalls = [];

  /// Optional pull script. When omitted, the page is empty at [since].
  Future<PullPage> Function({required int since, int? limit})? onPull;

  /// Probe batches in call order.
  final List<List<DiffProbe>> diffCalls = [];

  /// Optional script. When omitted, every call returns an empty list (nothing
  /// to report, check available). Return `null` to mean unavailable.
  Future<List<DiffVerdict>?> Function(List<DiffProbe> probes)? onDiff;

  /// Live messages. Broadcast so [close] does not hang when nobody listened.
  final StreamController<LiveMessage> liveController =
      StreamController<LiveMessage>.broadcast();

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
    pullCalls.add((since: since, limit: limit));
    final handler = onPull;
    if (handler != null) {
      return handler(since: since, limit: limit);
    }
    return PullPage(envelopes: const [], nextCursor: since);
  }

  @override
  Future<List<DiffVerdict>?> diff(List<DiffProbe> probes) async {
    _ensureOpen();
    diffCalls.add(List<DiffProbe>.from(probes));
    final handler = onDiff;
    if (handler != null) {
      return handler(probes);
    }
    return const [];
  }

  @override
  Stream<LiveMessage> live({
    required int Function() appliedSince,
    void Function(LiveConnectionState state)? onConnectionState,
  }) {
    _ensureOpen();
    return liveController.stream;
  }

  @override
  Future<void> pokeLive() async {
    _ensureOpen();
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

  void _ensureOpen() {
    if (closed) {
      throw StateError('FakeDiffTransport is closed');
    }
  }
}

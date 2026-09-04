/// Transport to the sync server: push, pull, and the live feed.
///
/// Exists so engine tests (step 14) can substitute a fake without starting
/// a process. Round 1 has one implementation: HttpSyncTransport.
library;

import '../protocol/envelope.dart';

/// Transport to the sync server.
///
/// Exists so engine tests (step 14) can substitute a fake without starting
/// a process. Round 1 has one implementation: HttpSyncTransport.
abstract interface class SyncTransport {
  /// POSTs envelopes to `/v1/sync/push`.
  ///
  /// `applied: false` is success, not an exception: the server already holds
  /// a row that is not inferior (SPEC section 7).
  Future<List<PushResult>> push(List<Envelope> envelopes);

  /// GETs `/v1/sync/pull`.
  ///
  /// When [limit] is `null` the query parameter is omitted and the server
  /// default (100) applies.
  Future<PullPage> pull({required int since, int? limit});

  /// GETs `/v1/sync/pull?live=sse`.
  ///
  /// [appliedSince] is invoked on every (re)open and must return the cursor
  /// the engine has **applied**, not the last `cursor` event observed.
  /// The transport never stores a cursor of its own.
  ///
  /// The returned stream does not complete on a dropped TCP connection.
  /// It completes on [close], on subscription cancel, or on a non-retryable
  /// failure.
  Stream<LiveMessage> live({required int Function() appliedSince});

  /// Cancels the live stream, closes the HTTP client, rejects later calls.
  Future<void> close();
}

/// One row from a push response (`id`, `part`, `applied`).
///
/// There is no `server_seq` on this type: the wire omits it (SPEC sections 1.3
/// and 3.1). The client's cursor moves only from pull and live, never from
/// push.
final class PushResult {
  /// Creates a result for one pushed envelope.
  const PushResult({
    required this.id,
    required this.part,
    required this.applied,
  });

  /// Envelope id echoed from the request.
  final String id;

  /// Envelope part echoed from the request (round 1: `full`).
  final String part;

  /// Whether the server stored the envelope.
  ///
  /// `false` is success: the server already holds a row that is not inferior.
  final bool applied;

  @override
  bool operator ==(Object other) =>
      other is PushResult &&
      id == other.id &&
      part == other.part &&
      applied == other.applied;

  @override
  int get hashCode => Object.hash(id, part, applied);

  @override
  String toString() => 'PushResult(id: $id, part: $part, applied: $applied)';
}

/// One immediate pull page: envelopes plus the server's `next_cursor`.
///
/// The cursor of an empty page is the value the **server** sent, not a
/// client-computed `since`. A missing `next_cursor` is a protocol error.
final class PullPage {
  /// Creates a page with a defensive copy of [envelopes].
  PullPage({required List<Envelope> envelopes, required this.nextCursor})
    : envelopes = List<Envelope>.unmodifiable(envelopes);

  /// Envelopes in `server_seq` order. Empty when nothing is new.
  final List<Envelope> envelopes;

  /// Exclusive cursor to pass as the next `since`.
  final int nextCursor;
}

/// One item from the live Server-Sent Events feed.
///
/// Three kinds, matching the wire: envelope, cursor, heartbeat. A fourth
/// kind for "disconnected" is intentionally absent — reconnect is internal.
sealed class LiveMessage {
  /// Creates a live-feed message.
  const LiveMessage();
}

/// An `event: envelope` payload parsed as an [Envelope].
final class LiveEnvelope extends LiveMessage {
  /// Wraps [envelope] from one live event.
  const LiveEnvelope(this.envelope);

  /// The envelope, including `server_seq`.
  final Envelope envelope;
}

/// An `event: cursor` payload with the server's `next_cursor`.
final class LiveCursor extends LiveMessage {
  /// Creates a cursor message for [nextCursor].
  const LiveCursor(this.nextCursor);

  /// Exclusive cursor to pass as the next `since` after this burst.
  final int nextCursor;
}

/// A comment line (`: ping`) used as a heartbeat.
///
/// Distinct from an event so the engine can tell traffic from silence
/// without parsing comment text.
final class LiveHeartbeat extends LiveMessage {
  /// Creates a heartbeat marker.
  const LiveHeartbeat();
}

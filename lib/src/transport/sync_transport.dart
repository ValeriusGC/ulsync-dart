/// Transport to the sync server: push, pull, and the live feed.
///
/// Exists so engine tests (step 14) can substitute a fake without starting
/// a process. Round 1 has one implementation: HttpSyncTransport.
library;

import '../protocol/envelope.dart';
import '../protocol/errors.dart';

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
  /// [onConnectionState] reports drop and restore. It is not a [LiveMessage]:
  /// existing stream tests keep their three-kind expectations. A scheduled
  /// reopen at JWT `exp` is **not** [LiveConnectionState.lost]; nor is
  /// [close] or subscription cancel.
  ///
  /// The returned stream does not complete on a dropped TCP connection.
  /// It completes on [close], on subscription cancel, or on a non-retryable
  /// failure.
  Stream<LiveMessage> live({
    required int Function() appliedSince,
    void Function(LiveConnectionState state)? onConnectionState,
  });

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
/// Three kinds, matching the wire: envelope, cursor, heartbeat. Disconnect
/// and restore are [LiveConnectionState] on [SyncTransport.live], not another
/// [LiveMessage] subtype — stream tests from step 13 keep their expectations.
sealed class LiveMessage {
  /// Creates a live-feed message.
  const LiveMessage();
}

/// Live TCP/HTTP session state for the engine, not a wire event.
///
/// A JWT `exp` reopen is scheduled and is not [lost]. Closing the transport
/// or cancelling the subscription is also not [lost]: the application asked
/// to stop.
enum LiveConnectionState {
  /// The live HTTP stream dropped, timed out, or the headers failed.
  lost,

  /// A live HTTP response with a 2xx status was received, including the
  /// first open.
  restored,
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

/// Optional capability: the divergence check of SPEC section 3.4.
///
/// Separate from [SyncTransport] on purpose. Existing implementations —
/// including test doubles in applications — keep compiling, and a transport
/// that cannot run the check is a supported configuration, not an error.
abstract interface class SyncDiffTransport {
  /// POSTs `/v1/sync/diff`.
  ///
  /// Returns null when the server does not implement the endpoint (HTTP 404
  /// or 405). Null means «unavailable», not «nothing to report»: an empty
  /// list means the latter.
  Future<List<DiffVerdict>?> diff(List<DiffProbe> probes);
}

/// Optional capability: SPEC section 3.5 origin handshake.
///
/// Separate from [SyncTransport] on purpose. Existing implementations —
/// including test doubles — keep compiling. A transport that cannot run
/// hello is treated as handshake unavailable, not as a mismatch.
abstract interface class SyncHelloTransport {
  /// GETs `/v1/sync/hello` with [origin] as `Ulsync-Origin`.
  ///
  /// Returns null when the server does not implement the endpoint
  /// (HTTP 404 or 405). Null means «unavailable», not «mismatch».
  /// Hello runs before self-check so a foreign store is refused before
  /// reconciliation can seed it.
  Future<HelloResult?> hello(String origin);
}

/// Body of a successful SPEC section 3.5 hello (`200`).
final class HelloResult {
  /// Creates a result from the store origin and the token subject.
  const HelloResult({required this.origin, required this.userId});

  /// Origin the store holds after this request (after imprint it equals
  /// the request header).
  final String origin;

  /// Token `sub`, so the client can confirm it is not another account
  /// on the same store.
  final String userId;

  /// Parses a `200` hello body. Both [origin] and `user_id` are required.
  factory HelloResult.fromJson(Map<String, Object?> json) {
    return HelloResult(
      origin: _diffRequireString(json, 'origin'),
      userId: _diffRequireString(json, 'user_id'),
    );
  }
}

/// One record as the client holds it: identity plus the three ranks of SPEC
/// section 2. All three are sent because section 2 ranks by all three, in
/// order; a request carrying fewer cannot be answered without guessing.
final class DiffProbe {
  /// Creates a probe for one `(id, part)` with the client's three ranks.
  const DiffProbe({
    required this.id,
    required this.part,
    required this.lastEditedAtMs,
    required this.revision,
    required this.sourceId,
  });

  /// Record identity, as in SPEC section 1.1.
  final String id;

  /// Slice; identity is `(id, part)`. Round 1 always `full`.
  final String part;

  /// First rank of SPEC section 2, as the **client** holds it.
  final int lastEditedAtMs;

  /// Second rank of SPEC section 2, as the **client** holds it.
  final int revision;

  /// Third rank of SPEC section 2, as the **client** holds it.
  final String sourceId;

  /// Parses one item from a SPEC section 3.4 request body.
  factory DiffProbe.fromJson(Map<String, Object?> json) {
    return DiffProbe(
      id: _diffRequireString(json, 'id'),
      part: _diffRequireString(json, 'part'),
      lastEditedAtMs: _diffRequireInt(json, 'last_edited_at_ms'),
      revision: _diffRequireInt(json, 'revision'),
      sourceId: _diffRequireString(json, 'source_id'),
    );
  }

  /// Serializes this probe to the wire `items[]` object.
  Map<String, Object?> toJson() => {
    'id': id,
    'part': part,
    'last_edited_at_ms': lastEditedAtMs,
    'revision': revision,
    'source_id': sourceId,
  };

  @override
  bool operator ==(Object other) =>
      other is DiffProbe &&
      id == other.id &&
      part == other.part &&
      lastEditedAtMs == other.lastEditedAtMs &&
      revision == other.revision &&
      sourceId == other.sourceId;

  @override
  int get hashCode => Object.hash(id, part, lastEditedAtMs, revision, sourceId);

  @override
  String toString() =>
      'DiffProbe($id/$part t=$lastEditedAtMs rev=$revision src=$sourceId)';
}

/// Why the server named this key. Both kinds lead to the same client action —
/// mark and push; the kind exists so the report can tell them apart.
enum DiffGap {
  /// The server holds no row for this `(id, part)` and this user.
  missing,

  /// The server holds a row that loses to the client's by SPEC section 2.
  stale,
}

/// One key the server named, with its own ranks when it holds a losing row.
///
/// Server ranks are optional and filled only for [DiffGap.stale]. The client
/// does not use them to decide what to do — both kinds mean mark and push —
/// they exist so a human reading the report can see how far behind the
/// server is.
final class DiffVerdict {
  /// Creates one named key.
  const DiffVerdict({
    required this.id,
    required this.part,
    required this.gap,
    this.serverLastEditedAtMs,
    this.serverRevision,
    this.serverSourceId,
  });

  /// Record identity echoed from the request.
  final String id;

  /// Slice echoed from the request.
  final String part;

  /// Whether the server lacks the row or holds a losing copy.
  final DiffGap gap;

  /// Server's first rank when [gap] is [DiffGap.stale].
  final int? serverLastEditedAtMs;

  /// Server's second rank when [gap] is [DiffGap.stale].
  final int? serverRevision;

  /// Server's third rank when [gap] is [DiffGap.stale].
  final String? serverSourceId;

  /// Parses one object from `missing` or `stale`.
  factory DiffVerdict.fromJson(Map<String, Object?> json, DiffGap gap) {
    if (gap == DiffGap.stale) {
      return DiffVerdict(
        id: _diffRequireString(json, 'id'),
        part: _diffRequireString(json, 'part'),
        gap: gap,
        serverLastEditedAtMs: _diffRequireInt(json, 'last_edited_at_ms'),
        serverRevision: _diffRequireInt(json, 'revision'),
        serverSourceId: _diffRequireString(json, 'source_id'),
      );
    }
    return DiffVerdict(
      id: _diffRequireString(json, 'id'),
      part: _diffRequireString(json, 'part'),
      gap: gap,
    );
  }

  /// Serializes this verdict to the matching `missing` or `stale` object.
  Map<String, Object?> toJson() {
    final map = <String, Object?>{'id': id, 'part': part};
    if (gap == DiffGap.stale) {
      map['last_edited_at_ms'] = serverLastEditedAtMs;
      map['revision'] = serverRevision;
      map['source_id'] = serverSourceId;
    }
    return map;
  }

  @override
  bool operator ==(Object other) =>
      other is DiffVerdict &&
      id == other.id &&
      part == other.part &&
      gap == other.gap &&
      serverLastEditedAtMs == other.serverLastEditedAtMs &&
      serverRevision == other.serverRevision &&
      serverSourceId == other.serverSourceId;

  @override
  int get hashCode => Object.hash(
    id,
    part,
    gap,
    serverLastEditedAtMs,
    serverRevision,
    serverSourceId,
  );

  @override
  String toString() => 'DiffVerdict($id/$part $gap)';
}

String _diffRequireString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty) {
    throw UlsyncProtocolException(
      'Expected non-empty string for field: $field',
      field: field,
    );
  }
  return value;
}

int _diffRequireInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int) {
    throw UlsyncProtocolException(
      'Expected integer for field: $field',
      field: field,
    );
  }
  return value;
}

/// Counters from one [UlsyncClient.syncOnce] pass.
///
/// Live-feed applies are not included: they have no report, only [SyncEvent].
///
/// @docImport '../transport/sync_transport.dart';
/// @docImport 'entity_adapter.dart';
/// @docImport 'sync_engine.dart';
/// @docImport 'sync_event.dart';
library;

/// Snapshot of work done by one [UlsyncClient.syncOnce] call.
///
/// Equality is by every field so tests can assert the whole tuple.
final class SyncReport {
  /// Creates an immutable report.
  const SyncReport({
    required this.pushed,
    required this.accepted,
    required this.pulled,
    required this.applied,
    required this.cursor,
  });

  /// Envelopes handed to [SyncTransport.push] during this pass.
  ///
  /// A `load` that returned `null` does not increment this: nothing was sent.
  /// `applied: false` from the server **does** increment it — the HTTP call
  /// happened.
  final int pushed;

  /// Push results with `applied: true`.
  ///
  /// `applied: false` is still success (SPEC section 7) but does not increment
  /// this counter: the server already held a non-inferior row.
  final int accepted;

  /// Envelopes received on pull pages, including those skipped by last-write-
  /// wins or an unknown type. Live-feed envelopes are not counted.
  final int pulled;

  /// Times a domain apply ran during this pass ([EntityAdapter.apply] for
  /// `full`, [EntityAdapter.applyPart] for other parts), not including live.
  /// An unknown part with no `applyPart` does not increment this.
  final int applied;

  /// Applied cursor after this pass (`server_seq` of the last persisted
  /// pull page or skip). Unchanged by push: [PushResult] has no `serverSeq`.
  final int cursor;

  @override
  bool operator ==(Object other) =>
      other is SyncReport &&
      pushed == other.pushed &&
      accepted == other.accepted &&
      pulled == other.pulled &&
      applied == other.applied &&
      cursor == other.cursor;

  @override
  int get hashCode => Object.hash(pushed, accepted, pulled, applied, cursor);

  @override
  String toString() =>
      'SyncReport(pushed: $pushed, accepted: $accepted, pulled: $pulled, '
      'applied: $applied, cursor: $cursor)';
}

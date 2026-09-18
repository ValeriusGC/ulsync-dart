/// Report from one [UlsyncClient.selfCheck] run.
///
/// Diff probes for one `id` are packed as an **indivisible** kit so a
/// batch of 500 never splits `full` from `done`. Each phase says whether
/// it was available. Unavailable is a supported configuration for the
/// **server** phase (old server, transport without the check,
/// `includeServer: false`). It is not how a forgotten
/// [EntityAdapter.listIds] looks: that callback is required.
///
/// @docImport 'entity_adapter.dart';
/// @docImport 'sync_engine.dart';
library;

/// Snapshot of one three-phase self-check.
final class SelfCheckReport {
  /// Creates an immutable report.
  const SelfCheckReport({
    required this.localAvailable,
    required this.localMarked,
    required this.serverAvailable,
    required this.serverProbed,
    required this.serverMissing,
    required this.serverStale,
    required this.serverMarked,
    required this.remainingDirty,
  });

  /// Whether the local phase ran.
  ///
  /// `true` when the client has at least one adapter: [EntityAdapter.listIds]
  /// is required and is always invoked. `false` only when `adapters` is
  /// empty. An empty `listIds()` on a live adapter still reports `true`
  /// (reconciliation ran and found nothing).
  final bool localAvailable;

  /// Application ids that had no metadata and were created with time `0`.
  final int localMarked;

  /// Whether the server divergence check ran.
  ///
  /// `false` when [UlsyncClient.selfCheck] was called with `includeServer:
  /// false`, when the transport does not implement the check, or when the
  /// server answered 404/405.
  final bool serverAvailable;

  /// Records sent to the server across all batches.
  final int serverProbed;

  /// Keys the server named as missing.
  final int serverMissing;

  /// Keys the server named as stale (its row loses by SPEC section 2).
  final int serverStale;

  /// Named keys on which the clock-preserving dirty mark succeeded.
  final int serverMarked;

  /// Dirty rows still queued after the drain loop, if any.
  final int remainingDirty;

  @override
  bool operator ==(Object other) =>
      other is SelfCheckReport &&
      localAvailable == other.localAvailable &&
      localMarked == other.localMarked &&
      serverAvailable == other.serverAvailable &&
      serverProbed == other.serverProbed &&
      serverMissing == other.serverMissing &&
      serverStale == other.serverStale &&
      serverMarked == other.serverMarked &&
      remainingDirty == other.remainingDirty;

  @override
  int get hashCode => Object.hash(
    localAvailable,
    localMarked,
    serverAvailable,
    serverProbed,
    serverMissing,
    serverStale,
    serverMarked,
    remainingDirty,
  );

  @override
  String toString() =>
      'SelfCheckReport(localAvailable: $localAvailable, '
      'localMarked: $localMarked, serverAvailable: $serverAvailable, '
      'serverProbed: $serverProbed, serverMissing: $serverMissing, '
      'serverStale: $serverStale, serverMarked: $serverMarked, '
      'remainingDirty: $remainingDirty)';
}

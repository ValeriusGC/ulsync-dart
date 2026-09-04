/// Events the application may listen to without parsing the wire protocol.
///
/// Envelopes stay inside the engine. Round 2 can change the wire without
/// changing this sealed set in a breaking way for screen updates.
///
/// @docImport 'entity_adapter.dart';
/// @docImport 'sync_engine.dart';
library;

/// One observation from [UlsyncClient.live] (and, while a listener exists,
/// from pull ingest on the same stream).
sealed class SyncEvent {
  /// Creates a sync event.
  const SyncEvent();
}

/// Records that actually reached [EntityAdapter.apply] this time.
final class SyncApplied extends SyncEvent {
  /// Wraps the [entities] just written to the application store.
  const SyncApplied(this.entities);

  /// Applied records as type plus id, not payload.
  final List<SyncedEntity> entities;
}

/// One applied record: wire type and id.
final class SyncedEntity {
  /// Names one record that passed last-write-wins and [EntityAdapter.apply].
  const SyncedEntity({required this.entityType, required this.id});

  /// Wire `entity_type` of the applied record.
  final String entityType;

  /// Wire `id` of the applied record.
  final String id;
}

/// The applied `server_seq` cursor moved forward.
final class SyncCursorAdvanced extends SyncEvent {
  /// Reports the new exclusive cursor.
  const SyncCursorAdvanced(this.cursor);

  /// Applied cursor after a successful persist (`server_seq`).
  final int cursor;
}

/// The live HTTP stream dropped, timed out, or failed to open.
///
/// Show a disconnected state. The library reopens the feed on its own. A
/// scheduled JWT `exp` reopen is **not** this event.
final class SyncConnectionLost extends SyncEvent {
  /// Creates a lost-connection event.
  const SyncConnectionLost();
}

/// A live HTTP response with a 2xx status was received, including first open.
final class SyncConnectionRestored extends SyncEvent {
  /// Creates a restored-connection event.
  const SyncConnectionRestored();
}

/// An envelope arrived for an `entity_type` with no registered adapter.
///
/// The cursor still advances so the page cannot stall. Sync of known types
/// continues. This is a warning, not a thrown exception.
final class SyncUnknownType extends SyncEvent {
  /// Names the skipped record.
  const SyncUnknownType({required this.entityType, required this.id});

  /// Wire `entity_type` that had no adapter.
  final String entityType;

  /// Wire `id` of the skipped envelope.
  final String id;
}

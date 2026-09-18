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

/// Records that reached [EntityAdapter.apply] or [EntityAdapter.applyPart].
///
/// One event may name an id after any cell of its kit landed. Completeness
/// still requires the rest of the kit; this event is not "the row is
/// finished".
final class SyncApplied extends SyncEvent {
  /// Wraps the [entities] just written to the application store.
  const SyncApplied(this.entities);

  /// Applied records as type plus id, not payload.
  final List<SyncedEntity> entities;
}

/// One applied record: wire type and id.
final class SyncedEntity {
  /// Names one record that passed last-write-wins and a domain apply.
  ///
  /// Identity is the id, not a finished kit: `done` of the same id may
  /// still be in flight.
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

/// The live HTTP stream dropped, timed out, failed to open, or catch-up
/// [UlsyncClient.syncOnce] hit a transport error.
///
/// Show a disconnected / reconnecting state. Do **not** call
/// [UlsyncClient.syncOnce] from this event: the engine already retries
/// until the server answers. A scheduled JWT `exp` reopen is **not**
/// this event. After laptop sleep the application still must call
/// [UlsyncClient.notifyResumed] — this event cannot fire while the
/// isolate is frozen.
final class SyncConnectionLost extends SyncEvent {
  /// Creates a lost-connection event.
  const SyncConnectionLost();
}

/// A live HTTP response with a 2xx status was received, including first open.
///
/// Clear disconnected UI state. The engine then retries
/// [UlsyncClient.syncOnce] until push/pull succeed; the application must
/// not duplicate that catch-up here.
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

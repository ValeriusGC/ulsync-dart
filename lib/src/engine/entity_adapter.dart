/// Contract between the sync engine and one application entity type.
///
/// The metadata store holds revision, dirty, and cursor — not payload bytes.
/// [load] and [apply] are the only path into the application's own database.
///
/// @docImport 'sync_engine.dart';
library;

import 'dart:typed_data';

/// How the engine reads and writes one application entity type [T].
///
/// Register each adapter once on [UlsyncClient.new]. The engine looks them
/// up by [entityType], which must match the wire `entity_type`.
final class EntityAdapter<T> {
  /// Creates an adapter for one [entityType].
  ///
  /// [entityType] after trim must be non-empty. Duplicate types are rejected
  /// by the client, not here, because only the client sees the full list.
  EntityAdapter({
    required this.entityType,
    required this.schemaVersion,
    required this.encode,
    required this.decode,
    required this.load,
    required this.apply,
  }) {
    if (entityType.trim().isEmpty) {
      throw ArgumentError.value(entityType, 'entityType', 'must be non-empty');
    }
  }

  /// Codec key; must equal wire `entity_type` on every envelope of this kind.
  final String entityType;

  /// Payload format version written into the envelope and passed to [decode].
  final int schemaVersion;

  /// Serializes an application value to opaque payload bytes.
  ///
  /// These are entity bytes, not the envelope JSON. Round 1 still sets
  /// `payload_encoding` to `json` on the wire even when the bytes are not
  /// UTF-8; the server copies the hint and does not interpret it.
  final Uint8List Function(T value) encode;

  /// Rebuilds an application value from payload bytes.
  ///
  /// [schemaVersion] is the producer's version from the envelope, which may
  /// differ from this adapter's [schemaVersion] after an app upgrade. Round 1
  /// does not migrate; unknown versions are the adapter's problem.
  final T Function(Uint8List bytes, int schemaVersion) decode;

  /// Reads the current application record, or `null` if it no longer exists.
  ///
  /// Called at **push** time, not when [UlsyncClient.markChanged] runs. The
  /// metadata store does not copy payload. If the record disappeared before
  /// the send, this returns `null` and the engine clears `dirty` without
  /// contacting the server. That is not an error.
  final Future<T?> Function(String id) load;

  /// Writes [value] into the application store.
  ///
  /// **Must be idempotent.** The application database and the library
  /// metadata database are different files; no transaction covers both. The
  /// engine therefore:
  ///
  /// 1. decodes the envelope and calls this function;
  /// 2. only then persists metadata and advances the cursor.
  ///
  /// If the process dies between (1) and (2), the next pull or live event
  /// delivers the same envelope and this function runs again. An upsert by
  /// `id` is safe. An append without a dedup key duplicates the row.
  ///
  /// The opposite order (cursor first, then this function) would skip the
  /// record forever after the same crash: the cursor has moved, the payload
  /// is gone, and no later sync can see it. The engine does not use that
  /// order.
  final Future<void> Function(T value) apply;

  /// Encodes [value] after a cast to [T].
  ///
  /// [UlsyncClient] holds a `Map<String, EntityAdapter<dynamic>>`. Reading
  /// [encode] through that type throws: `Uint8List Function(T)` is not a
  /// `Uint8List Function(dynamic)`. The cast belongs here, next to [T].
  Uint8List encodeValue(Object? value) => encode(value as T);

  /// Applies [value] after a cast to [T]. See [encodeValue] for why.
  Future<void> applyValue(Object? value) => apply(value as T);
}

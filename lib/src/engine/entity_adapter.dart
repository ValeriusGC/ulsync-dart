/// Contract between the sync engine and one application entity type.
///
/// The metadata store holds revision, dirty, and cursor — not payload bytes.
/// [load] and [apply] are the path for part `full`. [encodePart] and
/// [applyPart] are the path for every other name. Those paths are equal
/// cells of one **indivisible, complete** kit: the application row is the
/// union of `full` and every named part. Missing a cell is an incomplete
/// record, not an optimization. The engine never copies payload into its
/// own database.
///
/// @docImport 'sync_engine.dart';
library;

import 'dart:typed_data';

import 'incoming_envelope_meta.dart';

/// How the engine reads and writes one application entity type [T].
///
/// Register each adapter once on [UlsyncClient.open]. The engine looks them
/// up by [entityType], which must match the wire `entity_type`.
final class EntityAdapter<T> {
  /// Creates an adapter for one [entityType].
  ///
  /// [entityType] after trim must be non-empty. Duplicate types are rejected
  /// by the client, not here, because only the client sees the full list.
  /// [listIds] is required: without a full id list the local self-check
  /// cannot see records the application already stores, including hidden
  /// rows. An empty list is legal (no records). Omitting the argument does
  /// not compile. [encodePart] and [applyPart] stay optional because an
  /// application without named slices may ship only `full`.
  EntityAdapter({
    required this.entityType,
    required this.schemaVersion,
    required this.encode,
    required this.decode,
    required this.load,
    required this.apply,
    required this.listIds,
    this.encodePart,
    this.applyPart,
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
  /// Called at **push** time for part [kEnvelopePart], not when
  /// [UlsyncClient.markChanged] runs. Named parts use [encodePart] instead.
  /// The metadata store does not copy payload. If the record disappeared
  /// before the send, this returns `null` and the engine clears `dirty`
  /// without contacting the server. That is not an error.
  final Future<T?> Function(String id) load;

  /// Writes snapshot columns of [value] into the application store.
  ///
  /// Runs only for incoming [kEnvelopePart]. Named slices use [applyPart].
  /// This is one cell of an **indivisible, complete** kit, not the whole
  /// row: a successful [apply] does not mean `done` / `deleted` may be
  /// skipped. This callback **must not** write fields that travel as their
  /// own parts (checkbox, hide flag, and so on). Last-write-wins already
  /// keeps those cells independent on the wire; writing them from `full`
  /// makes a newer snapshot restore a hidden row or clear a checkbox the
  /// library cannot see. The library does not inspect which columns you
  /// touch — the adapter is the contract.
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
  ///
  /// [meta] carries SPEC edit ranks from the envelope. Use
  /// [IncomingEnvelopeMeta.lastEditedAtMs] for list order and subtitles
  /// so two devices show the same row after sync. Do not substitute local
  /// wall clock at apply time.
  final Future<void> Function(T value, IncomingEnvelopeMeta meta) apply;

  /// Returns the ids of every record of this type the application stores.
  ///
  /// Required. Include hidden rows: an id missing from this list looks like
  /// a deletion to the library, not a hide. Completeness of a kit is not
  /// "listed iff `full` exists" — a row that only has `done` still has this
  /// id. Ids only: the library never asks for payload here. An empty list
  /// is legal and means reconciliation ran and found nothing. Without this
  /// callback the engine cannot see the application's past, so the argument
  /// is not optional.
  final Future<List<String>> Function() listIds;

  /// Optional encoder for a named envelope part other than [kEnvelopePart].
  ///
  /// Each named part is an equal cell of an **indivisible, complete** kit.
  /// The engine never invents part names. Hide is an application slice, not
  /// a letter type the library understands. There is no tombstone type.
  /// When [UlsyncClient.write] is called with `part` not equal to `full`,
  /// this callback **must** be set; otherwise the engine throws [StateError]
  /// **before** marking dirty so a missing encoder cannot leave an
  /// unsendable row.
  ///
  /// Returning `null` means there is nothing to send: dirty is cleared without
  /// POST — the same contract as [load] returning `null`.
  final Future<Uint8List?> Function(String id, String part)? encodePart;

  /// Optional applier for a named envelope part other than [kEnvelopePart].
  ///
  /// Incoming `full` still uses [decode] and [apply]. This callback is the
  /// only path into the application store for any other part name, and that
  /// name is an equal cell of an **indivisible, complete** kit: the engine
  /// does not drop it because `full` already ran. The engine never invents
  /// part names. A foreign name when this callback is omitted does **not**
  /// fail the exchange: the cursor still advances, the part's metadata is
  /// stored so the envelope is not replayed forever, and the domain is left
  /// untouched. There is no tombstone type.
  final Future<void> Function(
    String id,
    String part,
    Uint8List payload,
    IncomingEnvelopeMeta meta,
  )?
  applyPart;

  /// Encodes [value] after a cast to [T].
  ///
  /// [UlsyncClient] holds a `Map<String, EntityAdapter<dynamic>>`. Reading
  /// [encode] through that type throws: `Uint8List Function(T)` is not a
  /// `Uint8List Function(dynamic)`. The cast belongs here, next to [T].
  Uint8List encodeValue(Object? value) => encode(value as T);

  /// Applies [value] after a cast to [T]. See [encodeValue] for why.
  Future<void> applyIncomingValue(Object? value, IncomingEnvelopeMeta meta) =>
      apply(value as T, meta);
}

/// Immutable local metadata for one entity part.
///
/// One metadata row is one cell of a record kit. The kit (`full` plus
/// every named part of that id) is **indivisible** and must be
/// **complete**. This is not entity content — the application adapter
/// owns payloads. The library only tracks what it needs to sync:
/// timestamps, revision, dirty flag, and schema version.
library;

/// What the library knows about one entity locally.
///
/// Metadata only: entity bytes live in the application store and are read
/// through the adapter at push time.
final class EntityState {
  /// Creates metadata for one entity [part] inside [entityType].
  const EntityState({
    required this.userScope,
    required this.entityType,
    required this.id,
    required this.part,
    required this.createdAtMs,
    required this.lastEditedAtMs,
    required this.revision,
    required this.sourceId,
    required this.schemaVersion,
    required this.dirty,
  });

  /// Signed-in user scope; part of every storage key so accounts never mix.
  final String userScope;

  /// Logical entity type (wire field `entity_type`).
  final String entityType;

  /// Stable entity identifier (wire field `id`).
  final String id;

  /// Envelope part name. Opaque key, not a letter type. `full` and every
  /// other name are equal cells of one **indivisible, complete** kit;
  /// last-write-wins compares inside `(id, part)` only and never treats
  /// `full` as the whole row.
  final String part;

  /// Creation time as Unix epoch milliseconds (wire `created_at_ms`).
  final int createdAtMs;

  /// Last edit time as Unix epoch milliseconds (wire `last_edited_at_ms`).
  final int lastEditedAtMs;

  /// Monotonic revision within the entity (wire `revision`).
  final int revision;

  /// Originating device or client identifier (wire `source_id`).
  final String sourceId;

  /// Payload schema version for the adapter (wire `schema_version`).
  final int schemaVersion;

  /// Whether this entity still waits to be pushed to the server.
  final bool dirty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EntityState &&
          userScope == other.userScope &&
          entityType == other.entityType &&
          id == other.id &&
          part == other.part &&
          createdAtMs == other.createdAtMs &&
          lastEditedAtMs == other.lastEditedAtMs &&
          revision == other.revision &&
          sourceId == other.sourceId &&
          schemaVersion == other.schemaVersion &&
          dirty == other.dirty;

  @override
  int get hashCode => Object.hash(
    userScope,
    entityType,
    id,
    part,
    createdAtMs,
    lastEditedAtMs,
    revision,
    sourceId,
    schemaVersion,
    dirty,
  );

  @override
  String toString() =>
      'EntityState($entityType/$id rev=$revision dirty=$dirty)';
}

/// Wire metadata passed to [EntityAdapter.apply] and [applyPart].
///
/// Both callbacks receive the same shape: `full` and named parts are equal
/// cells of one **indivisible, complete** kit. Applications use these ranks
/// for display and sort order so every installation agrees after sync.
/// Local `DateTime.now()` at apply time would make the same row look
/// different on two devices.
library;

/// Envelope ranks for one incoming apply callback.
final class IncomingEnvelopeMeta {
  /// Creates metadata copied from the wire envelope.
  const IncomingEnvelopeMeta({
    required this.part,
    required this.createdAtMs,
    required this.lastEditedAtMs,
    required this.revision,
    required this.sourceId,
  });

  /// Part name (`full`, `done`, `deleted`, …). One cell of an
  /// **indivisible, complete** kit; `full` is not the whole row.
  final String part;

  /// Creation time from the envelope (SPEC `created_at_ms`).
  final int createdAtMs;

  /// Last edit time from the envelope (SPEC `last_edited_at_ms`).
  final int lastEditedAtMs;

  /// Monotonic revision from the envelope.
  final int revision;

  /// Originating installation (`source_id` on the wire).
  final String sourceId;
}

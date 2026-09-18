/// Packing rules so a record kit stays **indivisible** and **complete**.
///
/// A kit is `full` plus every named part of one id. A push, pull page, or
/// diff request that kept 500 envelopes and dropped the 501st would cut
/// that set in half. These helpers stop at the last complete kit that
/// still fits, or hold a trailing kit on a full pull page until the next
/// page proves the id does not continue. Completeness forbids treating
/// `full` as the whole record.
library;

import '../protocol/envelope.dart';
import '../store/entity_state.dart';
import '../transport/sync_transport.dart';

/// Packs dirty rows into one push that never splits a record kit.
///
/// A kit is every dirty cell of one `(entityType, id)` — **indivisible**
/// and **complete**. Kits appear in the order their first row appears in
/// [dirtyOldestFirst]. Cells inside a kit are ordered by
/// [EntityState.createdAtMs], then [EntityState.lastEditedAtMs], then
/// [EntityState.part], so the POST follows creation order.
///
/// When the next kit would exceed [limit], packing stops. The result may
/// be shorter than [limit]. A single kit longer than [limit] throws
/// [StateError]: the SPEC ceiling cannot carry an unsplittable set.
List<EntityState> packCompleteRecordKits(
  Iterable<EntityState> dirtyOldestFirst, {
  required int limit,
}) {
  final batches = _packKits<EntityState>(
    dirtyOldestFirst,
    keyOf: (row) => '${row.entityType}\u0000${row.id}',
    limit: limit,
    compareInsideKit: (a, b) {
      final created = a.createdAtMs.compareTo(b.createdAtMs);
      if (created != 0) {
        return created;
      }
      final edited = a.lastEditedAtMs.compareTo(b.lastEditedAtMs);
      if (edited != 0) {
        return edited;
      }
      return a.part.compareTo(b.part);
    },
    describeKit: (row, length) =>
        'Record ${row.entityType}/${row.id} has $length dirty parts; '
        'one POST cannot exceed $limit envelopes and must not split a '
        'record kit.',
  );
  if (batches.isEmpty) {
    return const [];
  }
  return batches.first;
}

/// Packs diff probes into requests that never split one `id`.
///
/// Same rule as [packCompleteRecordKits]: a kit that does not fit the
/// current request waits for the next. A kit longer than [limit] throws
/// [StateError].
List<List<DiffProbe>> packCompleteDiffKits(
  Iterable<DiffProbe> probes, {
  required int limit,
}) {
  return _packKits<DiffProbe>(
    probes,
    keyOf: (probe) => probe.id,
    limit: limit,
    describeKit: (probe, length) =>
        'Record ${probe.id} has $length diff probes; one request cannot '
        'exceed $limit items and must not split a record kit.',
  );
}

/// How many envelopes of a pull page may be ingested without cutting a kit.
///
/// A short page (fewer than [pageLimit] envelopes) is the end of the feed:
/// the whole page is ingested so the kit is **complete**. A full page may
/// continue on the next request. The trailing run of the last
/// `(entityType, id)` is held so the kit stays **indivisible**: `full` and
/// `done` that straddle the SPEC limit arrive together. When the whole
/// page is one id, the page is ingested — holding it would livelock.
int pullIngestLength(List<Envelope> envelopes, int pageLimit) {
  if (envelopes.isEmpty || envelopes.length < pageLimit) {
    return envelopes.length;
  }
  final holdFrom = trailingRecordKitStart(envelopes);
  if (holdFrom == 0) {
    return envelopes.length;
  }
  return holdFrom;
}

/// Index where the trailing record kit of [envelopes] begins.
///
/// Walks backward from the last envelope while `(entityType, id)` matches.
/// Used by [pullIngestLength].
int trailingRecordKitStart(List<Envelope> envelopes) {
  if (envelopes.isEmpty) {
    return 0;
  }
  final last = envelopes.last;
  var i = envelopes.length - 1;
  while (i > 0) {
    final previous = envelopes[i - 1];
    if (previous.entityType != last.entityType || previous.id != last.id) {
      break;
    }
    i--;
  }
  return i;
}

/// Groups [items] into complete kits, then into batches of at most [limit].
List<List<T>> _packKits<T>(
  Iterable<T> items, {
  required String Function(T item) keyOf,
  required int limit,
  int Function(T a, T b)? compareInsideKit,
  required String Function(T item, int length) describeKit,
}) {
  if (limit < 1) {
    throw ArgumentError.value(limit, 'limit', 'must be at least 1');
  }
  final kits = <String, List<T>>{};
  final order = <String>[];
  for (final item in items) {
    final key = keyOf(item);
    final existing = kits[key];
    if (existing == null) {
      order.add(key);
      kits[key] = [item];
    } else {
      existing.add(item);
    }
  }
  final orderedKits = <List<T>>[];
  for (final key in order) {
    final kit = kits[key]!;
    if (compareInsideKit != null) {
      kit.sort(compareInsideKit);
    }
    if (kit.length > limit) {
      throw StateError(describeKit(kit.first, kit.length));
    }
    orderedKits.add(kit);
  }
  final batches = <List<T>>[];
  var current = <T>[];
  for (final kit in orderedKits) {
    if (current.isNotEmpty && current.length + kit.length > limit) {
      batches.add(current);
      current = <T>[];
    }
    current.addAll(kit);
  }
  if (current.isNotEmpty) {
    batches.add(current);
  }
  return batches;
}

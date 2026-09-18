/// Last-write-wins comparison identical to the server upsert.
///
/// Ranks compare inside one `(id, part)` cell only. They never declare a
/// record kit complete because `full` won: `done` and `deleted` remain
/// required cells of that **indivisible** set.
///
/// Not exported from `package:ulsync/ulsync.dart`. The application never
/// chooses a winner; the engine does, with the same three ranks as SPEC
/// section 2 and triad plan §13.5.
library;

import 'dart:convert';

/// Whether [incoming] must replace [local] under last-write-wins.
///
/// Three ranks, in order: edit time, then revision, then `source_id` as
/// UTF-8 bytes (SQLite `TEXT` with `BINARY` collation). Equal on all three
/// is not a win — the stored row is not inferior, matching `applied: false`
/// on the server.
///
/// [String.compareTo] must not be used: it compares UTF-16 code units, and
/// that order diverges from UTF-8 bytes for some strings (for example a
/// non-BMP character versus U+FFFF). ASCII `device-a` / `device-b` would
/// not catch the bug.
bool incomingWins({
  required int incomingLastEditedAtMs,
  required int incomingRevision,
  required String incomingSourceId,
  required int localLastEditedAtMs,
  required int localRevision,
  required String localSourceId,
}) {
  if (incomingLastEditedAtMs != localLastEditedAtMs) {
    return incomingLastEditedAtMs > localLastEditedAtMs;
  }
  if (incomingRevision != localRevision) {
    return incomingRevision > localRevision;
  }
  return _utf8Greater(incomingSourceId, localSourceId);
}

/// Whether [incoming] is strictly older than [local] and must not be applied.
///
/// Callers pass ranks of the **same** `(id, part)` cell. This function
/// never decides that `full` makes `done` unnecessary: those are different
/// cells of one **indivisible, complete** kit. A three-rank **tie** is not
/// stale. Metadata already storing those ranks does not mean the journal
/// still holds the flags. Only a strictly older version of this cell is
/// ignored, so a newer local edit of this slice is not overwritten.
bool incomingIsStale({
  required int incomingLastEditedAtMs,
  required int incomingRevision,
  required String incomingSourceId,
  required int localLastEditedAtMs,
  required int localRevision,
  required String localSourceId,
}) {
  if (incomingWins(
    incomingLastEditedAtMs: incomingLastEditedAtMs,
    incomingRevision: incomingRevision,
    incomingSourceId: incomingSourceId,
    localLastEditedAtMs: localLastEditedAtMs,
    localRevision: localRevision,
    localSourceId: localSourceId,
  )) {
    return false;
  }
  return incomingLastEditedAtMs != localLastEditedAtMs ||
      incomingRevision != localRevision ||
      incomingSourceId != localSourceId;
}

/// Whether [a] is strictly greater than [b] as UTF-8 byte strings.
///
/// Equal strings return `false` so a full three-rank tie is not a win.
bool _utf8Greater(String a, String b) {
  final aBytes = utf8.encode(a);
  final bBytes = utf8.encode(b);
  final n = aBytes.length < bBytes.length ? aBytes.length : bBytes.length;
  for (var i = 0; i < n; i++) {
    if (aBytes[i] != bBytes[i]) {
      return aBytes[i] > bBytes[i];
    }
  }
  return aBytes.length > bBytes.length;
}

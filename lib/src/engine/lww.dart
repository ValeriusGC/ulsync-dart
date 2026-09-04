/// Last-write-wins comparison identical to the server upsert.
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

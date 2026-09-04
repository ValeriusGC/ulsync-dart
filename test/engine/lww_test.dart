/// Last-write-wins UTF-8 ranking, including cases [String.compareTo] misses.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/src/engine/lww.dart';

void main() {
  test('equal tuples are not a win', () {
    expect(
      incomingWins(
        incomingLastEditedAtMs: 1,
        incomingRevision: 1,
        incomingSourceId: 'a',
        localLastEditedAtMs: 1,
        localRevision: 1,
        localSourceId: 'a',
      ),
      isFalse,
    );
  });

  test('source_id ranks as UTF-8 bytes, not UTF-16 code units', () {
    // U+10000 encodes as F0 90 80 80; U+FFFF encodes as EF BF BF.
    // UTF-8: U+10000 > U+FFFF. UTF-16 code units: D800 DC00 < FFFF.
    const incoming = '\u{10000}';
    const local = '\u{FFFF}';
    expect(incoming.compareTo(local), lessThan(0));
    expect(
      incomingWins(
        incomingLastEditedAtMs: 1,
        incomingRevision: 1,
        incomingSourceId: incoming,
        localLastEditedAtMs: 1,
        localRevision: 1,
        localSourceId: local,
      ),
      isTrue,
    );
  });
}

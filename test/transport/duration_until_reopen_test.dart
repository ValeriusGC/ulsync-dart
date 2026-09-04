/// Unit tests for [durationUntilReopen] with frozen clocks.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/src/transport/jwt_expiry.dart';

void main() {
  test('durationUntilReopen for now+90s and reopenBefore 60s is 30s', () {
    final now = DateTime.utc(2026, 1, 1, 0, 0, 0);
    final exp = now.add(const Duration(seconds: 90));
    expect(
      durationUntilReopen(
        exp: exp,
        now: now,
        reopenBefore: const Duration(seconds: 60),
        unreadableInterval: const Duration(minutes: 30),
      ),
      const Duration(seconds: 30),
    );
  });

  test(
    'durationUntilReopen for null exp returns unreadableInterval, not zero',
    () {
      const fallback = Duration(minutes: 30);
      final delay = durationUntilReopen(
        exp: null,
        now: DateTime.utc(2026, 1, 1),
        reopenBefore: const Duration(seconds: 60),
        unreadableInterval: fallback,
      );
      expect(delay, fallback);
      expect(delay, isNot(Duration.zero));
    },
  );

  test('durationUntilReopen is zero when exp is already past reopenBefore', () {
    final now = DateTime.utc(2026, 1, 1, 0, 1, 0);
    final exp = DateTime.utc(2026, 1, 1, 0, 1, 30);
    expect(
      durationUntilReopen(
        exp: exp,
        now: now,
        reopenBefore: const Duration(seconds: 60),
        unreadableInterval: const Duration(minutes: 30),
      ),
      Duration.zero,
    );
  });
}
